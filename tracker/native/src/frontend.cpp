#include "frontend.h"

#include <algorithm>
#include <cmath>
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

}  // namespace

Frontend::Sparse Frontend::filterbank(int n_fft, int sr, const std::vector<double>& centers_hz, double step_ratio) {
    const double bin_hz = double(sr) / n_fft;
    const int n_bins = n_fft / 2 + 1;
    Sparse fb;
    for (double c : centers_hz) {
        fb.start.push_back(int(fb.rows.size()));
        const double half_up = std::max(c * (step_ratio - 1.0), bin_hz);
        const double half_dn = std::max(c * (1.0 - 1.0 / step_ratio), bin_hz);
        for (int r = 0; r < n_bins; ++r) {
            const double d = r * bin_hz - c;
            const float w = float(std::max(0.0, d >= 0 ? 1.0 - d / half_up : 1.0 + d / half_dn));
            if (w != 0.0f) { fb.rows.push_back(r); fb.weights.push_back(w); }
        }
        if (int(fb.rows.size()) == fb.start.back()) throw std::runtime_error("empty filter");
    }
    fb.start.push_back(int(fb.rows.size()));
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
    stack_idx_.resize(size_t(cfg.n_harmonics) * nf);
    for (int h = 0; h < cfg.n_harmonics; ++h) {
        const int off = int(pyround(12.0 * bps * std::log2(h + 1.0)));
        for (int j = 0; j < nf; ++j) {
            const int idx = base + j + off;
            if (idx < 0 || idx >= cfg.n_grid()) throw std::runtime_error("grid too small for stack");
            stack_idx_[size_t(h) * nf + j] = idx;
        }
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
    spec_.resize(n_max / 2 + 1);
    db_long_.resize(cfg.n_grid());
    db_prev_.resize(cfg.n_grid());
    mag_short_.resize(n_short / 2 + 1);
    r_.resize(2 * n_acf);
}

void Frontend::apply(const Sparse& fb, const float* mag, float* db) const {
    const int n = int(fb.start.size()) - 1;
    for (int g = 0; g < n; ++g) {
        float acc = 0.0f;
        for (int i = fb.start[g]; i < fb.start[g + 1]; ++i) acc += mag[fb.rows[i]] * fb.weights[i];
        db[g] = 20.0f * std::log10(acc + 1e-7f);
    }
}

void Frontend::short_db(const float* seg, float* db) {
    for (int i = 0; i < n_short; ++i) tmp_[i] = seg[i] * w_short_[i];
    fft_short_.forward(tmp_.data(), spec_.data());
    for (int i = 0; i <= n_short / 2; ++i)
        mag_short_[i] = std::sqrt(spec_[i].re * spec_[i].re + spec_[i].im * spec_[i].im) * norm_short_;
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
    for (int i = 0; i < n_long; ++i) tmp_[i] = long_seg[i] * w_long_[i];
    fft_long_.forward(tmp_.data(), spec_.data());
    for (int i = 0; i <= n_long / 2; ++i)
        out.mag_long[i] = std::sqrt(spec_[i].re * spec_[i].re + spec_[i].im * spec_[i].im) * norm_long_;
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

    // stacks: s_long, s_short and d_spec gathered at the harmonics of every candidate pitch
    float* x = out.x.data();
    for (int h = 0; h < H; ++h) {
        const int* idx = &stack_idx_[size_t(h) * nf];
        float* xl = x + size_t(h) * nf;
        float* xs = x + size_t(H + h) * nf;
        float* xd = x + size_t(2 * H + h) * nf;
        for (int j = 0; j < nf; ++j) {
            const int g = idx[j];
            xl[j] = std::clamp((db_long_[g] - ref_l + R) / R, 0.0f, 1.0f);
            xs[j] = std::clamp((out.db_short[g] - ref_s + R) / R, 0.0f, 1.0f);
            xd[j] = std::clamp((std::max(out.db_short[g], -90.0f) - std::max(db_prev[g], -90.0f)) / 20.0f, -1.0f, 1.0f);
        }
    }

    // normalised autocorrelation (zero-padded FFT), sampled at the pitch period and its multiples
    const float* acf_seg = hist + history - n_acf;
    for (int i = 0; i < n_acf; ++i) tmp_[i] = acf_seg[i] * w_acf_[i];
    std::fill(tmp_.begin() + n_acf, tmp_.begin() + 2 * n_acf, 0.0f);
    fft_acf_.forward(tmp_.data(), spec_.data());
    for (int i = 0; i <= n_acf; ++i) spec_[i] = {spec_[i].re * spec_[i].re + spec_[i].im * spec_[i].im, 0.0f};
    fft_acf_.inverse(spec_.data(), r_.data());
    const float r0 = r_[0] + 1e-9f;
    float* xa = x + size_t(3 * H) * nf;
    for (int m = 0; m < K; ++m)
        for (int j = 0; j < nf; ++j) {
            const size_t q = size_t(m) * nf + j;
            const int i0 = acf_i0_[q];
            xa[q] = (r_[i0] / r0) * acf_w0_[q] + (r_[i0 + 1] / r0) * acf_w1_[q];
        }

    // levels
    double sl = 0.0, ss = 0.0;
    for (int i = 0; i < n_long; ++i) sl += double(long_seg[i]) * long_seg[i];
    for (int i = 0; i < n_short; ++i) ss += double(short_now[i]) * short_now[i];
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
