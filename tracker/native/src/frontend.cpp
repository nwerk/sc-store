#include "frontend.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <stdexcept>

namespace pt {

namespace {

// Smooth window whose maximum sits near the end, so new events show up quickly.
std::vector<float> asymmetric_window(int n, double peak) {
    long k = std::max(2L, pyround(peak * n));
    std::vector<float> w(n);
    for (int i = 0; i < n; ++i) {
        double v = i < k ? std::pow(std::sin(0.5 * M_PI * i / k), 2)
                         : std::pow(std::cos(0.5 * M_PI * (i - k) / std::max(1L, n - k)), 2);
        w[i] = float(v);
    }
    return w;
}

float window_norm(const std::vector<float>& w) {
    double s = 0.0;
    for (float v : w) s += v;
    return float(2.0 / float(s));
}

// The loops below are plain element-wise arithmetic on separate arrays, which the compiler vectorises.
void window(const float* x, const float* w, float* out, int n) {
    for (int i = 0; i < n; ++i) out[i] = x[i] * w[i];
}

void magnitude(const float* re, const float* im, float norm, float* out, int n) {
    for (int i = 0; i < n; ++i) out[i] = std::sqrt(re[i] * re[i] + im[i] * im[i]) * norm;
}

void power(const float* re, const float* im, float* out, int n) {
    for (int i = 0; i < n; ++i) out[i] = re[i] * re[i] + im[i] * im[i];
}

// Dot product with eight partial sums (one running sum is a chain of dependent additions; the wide filters of the
// high grid bins have up to a few hundred taps).
float dot(const float* a, const float* b, int n) {
    // two accumulators of the widest native vector: 8 partial sums with SSE / NEON, 16 with AVX
    using V = simd::vn;
    constexpr int W = int(sizeof(V) / sizeof(float));
    V acc0 = V{}, acc1 = V{};
    int i = 0;
    for (; i + 2 * W <= n; i += 2 * W) {
        acc0 += simd::load<V>(a + i) * simd::load<V>(b + i);
        acc1 += simd::load<V>(a + i + W) * simd::load<V>(b + i + W);
    }
    const V acc = acc0 + acc1;
    float s = 0.0f;
    for (int k = 0; k < W; ++k) s += acc[k];
    for (; i < n; ++i) s += a[i] * b[i];
    return s;
}

// Sum of squares in double precision. Eight partial sums: one running sum would be a chain of n dependent
// additions, which no CPU can overlap.
double sum_squares(const float* x, int n) {
    double acc[8] = {0, 0, 0, 0, 0, 0, 0, 0};
    int i = 0;
    for (; i + 8 <= n; i += 8)
        for (int k = 0; k < 8; ++k) acc[k] += double(x[i + k]) * x[i + k];
    double s = ((acc[0] + acc[4]) + (acc[1] + acc[5])) + ((acc[2] + acc[6]) + (acc[3] + acc[7]));
    for (; i < n; ++i) s += double(x[i]) * x[i];
    return s;
}

}  // namespace

Frontend::Sparse Frontend::filterbank(int n_fft, int sr, const std::vector<double>& centers_hz, double step_ratio) {
    const double bin_hz = double(sr) / n_fft;
    const int n_bins = n_fft / 2 + 1;
    Sparse fb;
    for (double c : centers_hz) {
        fb.start.push_back(int(fb.weights.size()));
        const double half_up = std::max(c * (step_ratio - 1.0), bin_hz);
        const double half_dn = std::max(c * (1.0 - 1.0 / step_ratio), bin_hz);
        int first = -1, last = -1;
        for (int r = 0; r < n_bins; ++r) {
            const double d = r * bin_hz - c;
            const float w = float(std::max(0.0, d >= 0 ? 1.0 - d / half_up : 1.0 + d / half_dn));
            if (w == 0.0f) continue;
            if (first < 0) first = r;
            else if (r != last + 1) throw std::runtime_error("filter with a gap");
            last = r;
            fb.weights.push_back(w);
        }
        if (first < 0) throw std::runtime_error("empty filter");
        fb.first.push_back(first);
    }
    fb.start.push_back(int(fb.weights.size()));
    return fb;
}

Frontend::Frontend(const FrontendConfig& c)
    : cfg(c), n_long(c.scaled(c.long_win)), n_short(c.scaled(c.short_win)), n_acf(c.scaled(c.acf_win)),
      delta(c.delta_samples()), history(c.history()),
      fft_long_(n_long), fft_short_(n_short), fft_acf_(2 * n_acf) {
    const int sr = cfg.sample_rate, bps = cfg.bins_per_semitone, nf = cfg.n_fine();
    w_long_ = asymmetric_window(n_long, cfg.window_peak);
    w_short_ = asymmetric_window(n_short, cfg.window_peak);
    w_acf_ = asymmetric_window(n_acf, cfg.window_peak);
    norm_long_ = window_norm(w_long_);
    norm_short_ = window_norm(w_short_);

    std::vector<double> grid_hz(cfg.n_grid());
    for (int g = 0; g < cfg.n_grid(); ++g) grid_hz[g] = midi_to_hz(cfg.grid_lo + double(g) / bps);
    const double step = std::pow(2.0, 1.0 / (12 * bps));
    fb_long_ = filterbank(n_long, sr, grid_hz, step);
    fb_short_ = filterbank(n_short, sr, grid_hz, step);

    // fine bin j is centred on MIDI pitch_lo + (j - 1) / bps, i.e. bin 3*i+1 is pitch i
    const int base = (cfg.pitch_lo - cfg.grid_lo) * bps - 1;
    stack_first_.resize(cfg.n_harmonics);
    for (int h = 0; h < cfg.n_harmonics; ++h) {
        const int off = int(pyround(12.0 * bps * std::log2(h + 1.0)));
        if (base + off < 0 || base + off + nf > cfg.n_grid()) throw std::runtime_error("grid too small for stack");
        stack_first_[h] = base + off;
    }
    const int K = cfg.acf_multiples;
    acf_i0_.resize(size_t(K) * nf);
    acf_w0_.resize(size_t(K) * nf);
    acf_w1_.resize(size_t(K) * nf);
    for (int m = 0; m < K; ++m)
        for (int j = 0; j < nf; ++j) {
            const double lag = (m + 1) * (sr / midi_to_hz(cfg.pitch_lo + double(j - 1) / bps));
            const long i0 = long(std::floor(lag));
            const float frac = float(lag - i0);
            const bool valid = (i0 + 1) < n_acf;
            acf_i0_[size_t(m) * nf + j] = valid ? int(i0) : 0;
            acf_w1_[size_t(m) * nf + j] = valid ? frac : 0.0f;
            acf_w0_[size_t(m) * nf + j] = valid ? 1.0f - frac : 0.0f;
        }
    coord_.resize(nf);
    for (int j = 0; j < nf; ++j) coord_[j] = float(double(j) / (nf - 1));

    const int n_max = std::max({n_long, n_short, 2 * n_acf});
    tmp_.resize(n_max);
    spec_re_.resize(n_max / 2 + 1);
    spec_im_.resize(n_max / 2 + 1);
    norm_l_.resize(cfg.n_grid());
    norm_s_.resize(cfg.n_grid());
    norm_d_.resize(cfg.n_grid());
    db_long_.resize(cfg.n_grid());
    db_prev_.resize(cfg.n_grid());
    mag_short_.resize(n_short / 2 + 1);
    r_.resize(2 * n_acf);
}

void Frontend::apply(const Sparse& fb, const float* mag, float* db) const {
    const int n = int(fb.start.size()) - 1;
    for (int g = 0; g < n; ++g)
        db[g] = 20.0f * std::log10(dot(mag + fb.first[g], &fb.weights[fb.start[g]], fb.start[g + 1] - fb.start[g]) + 1e-7f);
}

void Frontend::short_db(const float* seg, float* db) {
    window(seg, w_short_.data(), tmp_.data(), n_short);
    fft_short_.forward(tmp_.data(), spec_re_.data(), spec_im_.data());
    magnitude(spec_re_.data(), spec_im_.data(), norm_short_, mag_short_.data(), n_short / 2 + 1);
    apply(fb_short_, mag_short_.data(), db);
}

void Frontend::compute(const float* hist, const float* db_prev, Features& out) {
    const int nf = cfg.n_fine(), ng = cfg.n_grid(), H = cfg.n_harmonics, K = cfg.acf_multiples;
    const float R = float(cfg.db_range);
    out.x.resize(size_t(cfg.n_channels()) * nf);
    out.mag_long.resize(n_long / 2 + 1);
    out.db_short.resize(ng);

    // long window spectrum
    const float* long_seg = hist + history - n_long;
    window(long_seg, w_long_.data(), tmp_.data(), n_long);
    fft_long_.forward(tmp_.data(), spec_re_.data(), spec_im_.data());
    magnitude(spec_re_.data(), spec_im_.data(), norm_long_, out.mag_long.data(), n_long / 2 + 1);
    apply(fb_long_, out.mag_long.data(), db_long_.data());

    // short window now, and delta samples earlier (unless the caller kept it from that frame)
    const float* short_now = hist + history - n_short;
    short_db(short_now, out.db_short.data());
    if (!db_prev) {
        short_db(hist + history - n_short - delta, db_prev_.data());
        db_prev = db_prev_.data();
    }

    float ref_l = float(cfg.db_floor), ref_s = float(cfg.db_floor);
    for (int g = 0; g < ng; ++g) {
        ref_l = std::max(ref_l, db_long_[g]);
        ref_s = std::max(ref_s, out.db_short[g]);
    }

    // stacks: s_long, s_short and d_spec gathered at the harmonics of every candidate pitch. Each grid bin is
    // gathered by several harmonics, so the three values are computed once per grid bin first.
    for (int g = 0; g < ng; ++g) {
        norm_l_[g] = std::clamp((db_long_[g] - ref_l + R) / R, 0.0f, 1.0f);
        norm_s_[g] = std::clamp((out.db_short[g] - ref_s + R) / R, 0.0f, 1.0f);
        norm_d_[g] = std::clamp((std::max(out.db_short[g], -90.0f) - std::max(db_prev[g], -90.0f)) / 20.0f, -1.0f, 1.0f);
    }
    float* x = out.x.data();
    for (int h = 0; h < H; ++h) {
        const int g = stack_first_[h];
        std::memcpy(x + size_t(h) * nf, &norm_l_[g], sizeof(float) * nf);
        std::memcpy(x + size_t(H + h) * nf, &norm_s_[g], sizeof(float) * nf);
        std::memcpy(x + size_t(2 * H + h) * nf, &norm_d_[g], sizeof(float) * nf);
    }

    // normalised autocorrelation (zero-padded FFT), sampled at the pitch period and its multiples
    const float* acf_seg = hist + history - n_acf;
    window(acf_seg, w_acf_.data(), tmp_.data(), n_acf);
    std::fill(tmp_.begin() + n_acf, tmp_.begin() + 2 * n_acf, 0.0f);
    fft_acf_.forward(tmp_.data(), spec_re_.data(), spec_im_.data());
    power(spec_re_.data(), spec_im_.data(), spec_re_.data(), n_acf + 1);
    fft_acf_.inverse(spec_re_.data(), nullptr, r_.data());
    const float r0 = r_[0] + 1e-9f;
    float* xa = x + size_t(3 * H) * nf;
    for (int m = 0; m < K; ++m)
        for (int j = 0; j < nf; ++j) {
            const size_t q = size_t(m) * nf + j;
            const int i0 = acf_i0_[q];
            xa[q] = (r_[i0] / r0) * acf_w0_[q] + (r_[i0 + 1] / r0) * acf_w1_[q];
        }

    // levels
    // the short window is the end of the long one, so its samples are summed once
    const double ss = sum_squares(short_now, n_short);
    const double sl = n_long >= n_short ? sum_squares(long_seg, n_long - n_short) + ss : sum_squares(long_seg, n_long);
    const double rms_db = 20.0 * std::log10(std::sqrt(sl / n_long + 1e-12));
    const double rms_s_db = 20.0 * std::log10(std::sqrt(ss / n_short + 1e-12));
    out.rms_db = float(rms_db);
    const float lvl_l = float(std::clamp((rms_db + 80.0) / 80.0, 0.0, 1.0));
    const float lvl_s = float(std::clamp((rms_s_db + 80.0) / 80.0, 0.0, 1.0));
    float* xc = x + size_t(3 * H + K) * nf;
    for (int j = 0; j < nf; ++j) {
        xc[j] = lvl_l;
        xc[nf + j] = lvl_s;
        xc[2 * nf + j] = coord_[j];
    }
}

}  // namespace pt
