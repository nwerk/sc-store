#include "model.h"

#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <stdexcept>

namespace pt {

namespace {

// Register-blocked GEMM: out[o][l] = b[o] + sum_j w[o][j] * col[j][l].
// An 8 x 8 tile of outputs stays in registers while j runs over the whole reduction (AVX2: 8 registers,
// NEON: 16), so every col value is loaded once per eight output rows and nothing is written until the end.
// wp: weights packed per block of 8 rows as [block][j][8]; col rows have stride lp (a multiple of 8,
// zero-padded); out has row stride L.
constexpr int RB = 8, LB = 8;

// 8 floats; GCC/Clang lower this to one AVX register or two NEON registers
typedef float v8 __attribute__((vector_size(32)));

inline v8 load8(const float* p) { v8 v; std::memcpy(&v, p, sizeof v); return v; }

void gemm_tile8(const float* wp, const float* b, const float* col, float* out, int kc, int L, int lp) {
    for (int l0 = 0; l0 < lp; l0 += LB) {
        v8 a0 = b[0] + v8{}, a1 = b[1] + v8{}, a2 = b[2] + v8{}, a3 = b[3] + v8{};
        v8 a4 = b[4] + v8{}, a5 = b[5] + v8{}, a6 = b[6] + v8{}, a7 = b[7] + v8{};
        const float* c = col + l0;
        const float* w = wp;
        for (int j = 0; j < kc; ++j, c += lp, w += RB) {
            const v8 x = load8(c);
            a0 += w[0] * x; a1 += w[1] * x; a2 += w[2] * x; a3 += w[3] * x;
            a4 += w[4] * x; a5 += w[5] * x; a6 += w[6] * x; a7 += w[7] * x;
        }
        const v8 acc[RB] = {a0, a1, a2, a3, a4, a5, a6, a7};
        const int n = L - l0 < LB ? L - l0 : LB;
        for (int r = 0; r < RB; ++r) {
            if (n == LB) std::memcpy(out + r * L + l0, &acc[r], sizeof(v8));
            else for (int i = 0; i < n; ++i) out[r * L + l0 + i] = acc[r][i];
        }
    }
}

// rows that do not fill a block of 8 (the two output heads)
void gemm_rows(const float* w, const float* b, const float* col, float* out, int rows, int kc, int L, int lp) {
    for (int r = 0; r < rows; ++r) {
        float* y = out + r * L;
        for (int l = 0; l < L; ++l) y[l] = b[r];
        for (int j = 0; j < kc; ++j) {
            const float a = w[r * kc + j];
            const float* c = col + j * lp;
            for (int l = 0; l < L; ++l) y[l] += a * c[l];
        }
    }
}

}  // namespace

PitchNet PitchNet::load(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) throw std::runtime_error("cannot open model " + path);
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
        b.xpad.assign(size_t(l.c_in) * (l_in + 2 * l.pad), 0.0f);
        b.lp = (b.l_out + LB - 1) / LB * LB;
        b.col.assign(size_t(l.k) * l.c_in * b.lp, 0.0f);  // padding columns stay zero
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
        const int lp = b.l_in + 2 * l.pad;
        for (int c = 0; c < l.c_in; ++c)
            std::memcpy(&b.xpad[size_t(c) * lp + l.pad], h + size_t(c) * b.l_in, sizeof(float) * b.l_in);
        if (l.residual_in) { skip = h; skip_n = size_t(l.c_in) * b.l_in; }
        // im2col, tap-major: col[t * c_in + c][j] = xpad[c][j * stride + t * dilation]
        for (int t = 0; t < l.k; ++t)
            for (int c = 0; c < l.c_in; ++c) {
                float* dst = &b.col[(size_t(t) * l.c_in + c) * b.lp];
                const float* src = &b.xpad[size_t(c) * lp + t * l.dilation];
                if (l.stride == 1) std::memcpy(dst, src, sizeof(float) * b.l_out);
                else for (int j = 0; j < b.l_out; ++j) dst[j] = src[j * l.stride];
            }
        float* y = b.out.data();
        const int kc = l.k * l.c_in, blocks = l.c_out / RB;
        for (int ob = 0; ob < blocks; ++ob)
            gemm_tile8(&b.wp[size_t(ob) * kc * RB], &l.b[ob * RB], b.col.data(), y + size_t(ob) * RB * b.l_out, kc,
                       b.l_out, b.lp);
        if (const int rest = l.c_out - blocks * RB)
            gemm_rows(&l.w[size_t(blocks) * RB * kc], &l.b[blocks * RB], b.col.data(), y + size_t(blocks) * RB * b.l_out,
                      rest, kc, b.l_out, b.lp);
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
