#include "model.h"

#include "fft.h"  // simd vector types

#include <cstdio>
#include <cstring>

// 32-bit ARM: the convolution kernel is written with NEON intrinsics (see conv_tile8). PT_NEON_SHIM builds the
// same kernel on x86 with tests/neon_shim.h, for checking it there.
#if defined(PT_NEON_SHIM)
#include "../tests/neon_shim.h"
#define PT_ARM32_KERNEL 1
#elif defined(__arm__) && defined(__ARM_NEON) && !defined(__aarch64__)
#include <arm_neon.h>
#define PT_ARM32_KERNEL 1
#endif
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace pt {

namespace {

// Convolution as a register-blocked matrix product: out[o][l] = b[o] + sum_j w[o][j] * x_j[l], where x_j is
// input channel c at tap t (j = t * c_in + c), i.e. the input row shifted by t * dilation.
// A tile of 8 outputs x W positions stays in registers while j runs over the whole reduction, so every input value
// is loaded once per eight output rows and nothing is written until the end.
// The rows x_j are read in place from the zero-padded input (no im2col copy): `inner` rows `stride` floats apart,
// repeated `outer` times `step` floats further on. A stride-1 layer has outer = k taps, inner = c_in channels; a
// strided layer reads its im2col matrix with outer = 1. Per layer, input (20 kB) and one block of weights (6 kB)
// then fit a 32 kB L1 cache (Raspberry Pi 4) together.
// wp: weights packed per block of 8 rows as [block][j][8]; out has row stride L.
constexpr int RB = 8;

// Positions per tile. 8 floats are one AVX register or two NEON registers (AArch64 has 32 of them); elsewhere
// (32-bit ARM, SSE: 16 registers) eight 4-float accumulators are what fits.
#if (defined(__AVX__) || defined(__aarch64__)) && !defined(PT_NEON_SHIM)
typedef simd::v8 vt;
#else
typedef simd::v4 vt;
#endif
constexpr int LB = int(sizeof(vt) / sizeof(float));

struct Rows {
    const float* base;
    int outer, step, inner, stride;
};

#if defined(PT_ARM32_KERNEL)
// 32-bit ARM, 8 outputs x 4 positions. NEON there has no fused multiply-add by a lane, and from the generic
// vector code above GCC builds `w[r] * v` by first copying the weight into all four lanes of a register: one
// extra instruction per multiply-add. vmla.f32 by lane (vmlaq_lane_f32) takes the weight straight from a lane:
// per step one load of 4 inputs, two loads of the 8 weights, 8 multiply-adds; 11 of the 16 registers.
// lp is a multiple of 4 here (LB == 4 on 32-bit ARM).
void conv_tile8(const float* wp, const float* b, Rows x, float* out, int L, int lp) {
    static_assert(LB == 4, "the 32-bit ARM kernel works on 4 positions");
    for (int l0 = 0; l0 < lp; l0 += 4) {
        float32x4_t a0 = vdupq_n_f32(b[0]), a1 = vdupq_n_f32(b[1]), a2 = vdupq_n_f32(b[2]), a3 = vdupq_n_f32(b[3]);
        float32x4_t a4 = vdupq_n_f32(b[4]), a5 = vdupq_n_f32(b[5]), a6 = vdupq_n_f32(b[6]), a7 = vdupq_n_f32(b[7]);
        const float* w = wp;
        for (int t = 0; t < x.outer; ++t) {
            const float* c = x.base + t * x.step + l0;
            for (int j = 0; j < x.inner; ++j, c += x.stride, w += RB) {
                const float32x4_t v = vld1q_f32(c);
                const float32x4_t w03 = vld1q_f32(w), w47 = vld1q_f32(w + 4);
                const float32x2_t w01 = vget_low_f32(w03), w23 = vget_high_f32(w03);
                const float32x2_t w45 = vget_low_f32(w47), w67 = vget_high_f32(w47);
                a0 = vmlaq_lane_f32(a0, v, w01, 0); a1 = vmlaq_lane_f32(a1, v, w01, 1);
                a2 = vmlaq_lane_f32(a2, v, w23, 0); a3 = vmlaq_lane_f32(a3, v, w23, 1);
                a4 = vmlaq_lane_f32(a4, v, w45, 0); a5 = vmlaq_lane_f32(a5, v, w45, 1);
                a6 = vmlaq_lane_f32(a6, v, w67, 0); a7 = vmlaq_lane_f32(a7, v, w67, 1);
            }
        }
        const float32x4_t acc[RB] = {a0, a1, a2, a3, a4, a5, a6, a7};
        const int n = L - l0 < 4 ? L - l0 : 4;
        for (int r = 0; r < RB; ++r) {
            if (n == 4) {
                vst1q_f32(out + r * L + l0, acc[r]);
            } else {
                float tmp[4];
                vst1q_f32(tmp, acc[r]);
                for (int i = 0; i < n; ++i) out[r * L + l0 + i] = tmp[i];
            }
        }
    }
}
#else
void conv_tile8(const float* wp, const float* b, Rows x, float* out, int L, int lp) {
    for (int l0 = 0; l0 < lp; l0 += LB) {
        vt a0 = b[0] + vt{}, a1 = b[1] + vt{}, a2 = b[2] + vt{}, a3 = b[3] + vt{};
        vt a4 = b[4] + vt{}, a5 = b[5] + vt{}, a6 = b[6] + vt{}, a7 = b[7] + vt{};
        const float* w = wp;
        for (int t = 0; t < x.outer; ++t) {
            const float* c = x.base + t * x.step + l0;
            for (int j = 0; j < x.inner; ++j, c += x.stride, w += RB) {
                const vt v = simd::load<vt>(c);
                a0 += w[0] * v; a1 += w[1] * v; a2 += w[2] * v; a3 += w[3] * v;
                a4 += w[4] * v; a5 += w[5] * v; a6 += w[6] * v; a7 += w[7] * v;
            }
        }
        const vt acc[RB] = {a0, a1, a2, a3, a4, a5, a6, a7};
        const int n = L - l0 < LB ? L - l0 : LB;
        for (int r = 0; r < RB; ++r) {
            if (n == LB) simd::store<vt>(out + r * L + l0, acc[r]);
            else for (int i = 0; i < n; ++i) out[r * L + l0 + i] = acc[r][i];
        }
    }
}

#endif

// rows that do not fill a block of 8 (the two output heads)
void conv_rows(const float* w, const float* b, Rows x, float* out, int rows, int L) {
    for (int r = 0; r < rows; ++r) {
        float* y = out + r * L;
        for (int l = 0; l < L; ++l) y[l] = b[r];
        const float* wr = w + size_t(r) * x.outer * x.inner;
        for (int t = 0; t < x.outer; ++t)
            for (int j = 0; j < x.inner; ++j) {
                const float a = *wr++;
                const float* c = x.base + t * x.step + j * x.stride;
                for (int l = 0; l < L; ++l) y[l] += a * c[l];
            }
    }
}

}  // namespace

const char* simd_info() {
#if defined(PT_NEON_SHIM)
    return "x86-64 running the 32-bit ARM kernel through tests/neon_shim.h (correctness check only)";
#elif defined(__AVX2__) && defined(__FMA__)
    return "x86-64 AVX2 + FMA";
#elif defined(__AVX__)
    return "x86-64 AVX";
#elif defined(__x86_64__)
    return "x86-64 SSE";
#elif defined(__aarch64__)
    return "AArch64 NEON";
#elif defined(__arm__) && defined(__ARM_NEON) && defined(PT_ARM32_NEON_FLOAT)
    return "ARMv7 NEON";
#elif defined(__arm__) && defined(__ARM_NEON)
    return "ARMv7, vector code compiled as scalar (built without -funsafe-math-optimizations, see Makefile): SLOW";
#elif defined(__arm__)
    return "ARMv7 without NEON (see CPUFLAGS in the Makefile): SLOW";
#else
    return "no known vector instructions";
#endif
}

PitchNet PitchNet::load(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open model " + path);
    return load(f, path);
}

PitchNet PitchNet::load(std::istream& f, const std::string& path) {
    PitchNet net;
    std::string line;
    if (!std::getline(f, line) || line != "polytracker-model 1")
        throw std::runtime_error(path + " is not a polytracker model (version 1); export it with native/export_model.py");
    int n_layers = -1;
    while (std::getline(f, line)) {
        if (line == "end") break;
        std::istringstream s(line);
        std::string key;
        s >> key;
        FrontendConfig& c = net.cfg;
        if (key == "name") { std::getline(s >> std::ws, net.name); }
        else if (key == "sample_rate") s >> c.sample_rate;
        else if (key == "hop") s >> c.hop;
        else if (key == "pitch_lo") s >> c.pitch_lo;
        else if (key == "pitch_hi") s >> c.pitch_hi;
        else if (key == "bins_per_semitone") s >> c.bins_per_semitone;
        else if (key == "grid_lo") s >> c.grid_lo;
        else if (key == "grid_semitones") s >> c.grid_semitones;
        else if (key == "n_harmonics") s >> c.n_harmonics;
        else if (key == "long_win") s >> c.long_win;
        else if (key == "short_win") s >> c.short_win;
        else if (key == "acf_win") s >> c.acf_win;
        else if (key == "delta_lag") s >> c.delta_lag;
        else if (key == "window_peak") s >> c.window_peak;
        else if (key == "acf_multiples") s >> c.acf_multiples;
        else if (key == "db_range") s >> c.db_range;
        else if (key == "db_floor") s >> c.db_floor;
        else if (key == "layers") s >> n_layers;
        else if (key == "layer") {
            Layer l;
            int relu, rin, rout;
            s >> l.k >> l.stride >> l.dilation >> l.pad >> relu >> rin >> rout >> l.c_out >> l.c_in;
            if (!s) throw std::runtime_error("bad layer line in " + path + ": " + line);
            l.relu = relu; l.residual_in = rin; l.residual_out = rout;
            net.layers.push_back(std::move(l));
        }
        else std::fprintf(stderr, "[polytracker] model: ignoring unknown header field '%s'\n", key.c_str());
    }
    if (line != "end" || n_layers != int(net.layers.size()) || net.layers.empty())
        throw std::runtime_error("truncated model header in " + path);
    for (Layer& l : net.layers) {
        l.w.resize(size_t(l.c_out) * l.k * l.c_in);
        l.b.resize(l.c_out);
        f.read(reinterpret_cast<char*>(l.w.data()), std::streamsize(l.w.size() * sizeof(float)));
        f.read(reinterpret_cast<char*>(l.b.data()), std::streamsize(l.b.size() * sizeof(float)));
        if (!f) throw std::runtime_error("truncated model weights in " + path);
    }
    if (net.layers.front().c_in != net.cfg.n_channels())
        throw std::runtime_error("model input channels do not match its frontend configuration");
    net.plan();
    return net;
}

void PitchNet::plan() {
    bufs_.clear();
    int l_in = cfg.n_fine();
    for (const Layer& l : layers) {
        Buf b;
        b.l_in = l_in;
        b.l_out = (l_in + 2 * l.pad - l.dilation * (l.k - 1) - 1) / l.stride + 1;
        b.lp = (b.l_out + LB - 1) / LB * LB;
        // the last tile reads up to lp - l_out positions past the input; they stay zero
        b.row = l_in + 2 * l.pad + (b.lp - b.l_out);
        b.xpad.assign(size_t(l.c_in) * b.row, 0.0f);
        if (l.stride != 1) b.col.assign(size_t(l.k) * l.c_in * b.lp, 0.0f);  // padding columns stay zero
        const int kc = l.k * l.c_in, blocks = l.c_out / RB;
        b.wp.resize(size_t(blocks) * kc * RB);
        for (int ob = 0; ob < blocks; ++ob)
            for (int j = 0; j < kc; ++j)
                for (int r = 0; r < RB; ++r) b.wp[(size_t(ob) * kc + j) * RB + r] = l.w[size_t(ob * RB + r) * kc + j];
        b.out.assign(size_t(l.c_out) * b.l_out, 0.0f);
        bufs_.push_back(std::move(b));
        l_in = bufs_.back().l_out;
    }
    if (layers.back().c_out != 2) throw std::runtime_error("model must end in two heads (frame, onset)");
    out_len = l_in;
}

const float* PitchNet::predict_one(const float* x) {
    const float* h = x;  // current layer input, [c_in][l_in]
    const float* skip = nullptr;
    size_t skip_n = 0;  // size of the residual source (it may be several layers back)
    for (size_t i = 0; i < layers.size(); ++i) {
        const Layer& l = layers[i];
        Buf& b = bufs_[i];
        for (int c = 0; c < l.c_in; ++c)
            std::memcpy(&b.xpad[size_t(c) * b.row + l.pad], h + size_t(c) * b.l_in, sizeof(float) * b.l_in);
        if (l.residual_in) { skip = h; skip_n = size_t(l.c_in) * b.l_in; }
        Rows x{b.xpad.data(), l.k, l.dilation, l.c_in, b.row};
        if (l.stride != 1) {
            // im2col, tap-major: col[t * c_in + c][j] = xpad[c][j * stride + t * dilation]
            for (int t = 0; t < l.k; ++t)
                for (int c = 0; c < l.c_in; ++c) {
                    float* dst = &b.col[(size_t(t) * l.c_in + c) * b.lp];
                    const float* src = &b.xpad[size_t(c) * b.row + t * l.dilation];
                    for (int j = 0; j < b.l_out; ++j) dst[j] = src[j * l.stride];
                }
            x = Rows{b.col.data(), 1, 0, l.k * l.c_in, b.lp};
        }
        float* y = b.out.data();
        const int kc = l.k * l.c_in, blocks = l.c_out / RB;
        for (int ob = 0; ob < blocks; ++ob)
            conv_tile8(&b.wp[size_t(ob) * kc * RB], &l.b[ob * RB], x, y + size_t(ob) * RB * b.l_out, b.l_out, b.lp);
        if (const int rest = l.c_out - blocks * RB)
            conv_rows(&l.w[size_t(blocks) * RB * kc], &l.b[blocks * RB], x, y + size_t(blocks) * RB * b.l_out, rest,
                      b.l_out);
        const size_t n = size_t(l.c_out) * b.l_out;
        if (l.relu)
            for (size_t j = 0; j < n; ++j) y[j] = y[j] > 0.0f ? y[j] : 0.0f;
        if (l.residual_out) {
            if (!skip || skip_n != n) throw std::runtime_error("bad residual layer");
            for (size_t j = 0; j < n; ++j) y[j] += skip[j];
        }
        h = y;
    }
    float* p = bufs_.back().out.data();
    const size_t n = size_t(2) * out_len;
    for (size_t j = 0; j < n; ++j) {
        float v = p[j] < -30.0f ? -30.0f : (p[j] > 30.0f ? 30.0f : p[j]);
        p[j] = 1.0f / (1.0f + std::exp(-v));
    }
    return p;
}

}  // namespace pt
