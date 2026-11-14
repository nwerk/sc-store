// Causal feature frontend for one frame (port of polytracker/frontend.py, realtime path, batch size 1).
#pragma once

#include <vector>

#include "fft.h"
#include "model.h"

namespace pt {

struct Features {
    std::vector<float> x;         // [n_channels][n_fine] network input
    std::vector<float> mag_long;  // [n_long/2 + 1] linear magnitude, full-scale sine == 1
    std::vector<float> db_short;  // [n_grid] short-window log spectrum (reused by the frame delta samples later)
    float rms_db = 0.0f;          // RMS level of the long window, dBFS
};

class Frontend {
public:
    explicit Frontend(const FrontendConfig& cfg);

    // hist: the newest cfg.history() samples, newest last. db_prev: db_short of the frame that ended
    // delta_samples earlier, or nullptr to compute it (same numbers, one FFT more).
    void compute(const float* hist, const float* db_prev, Features& out);

    const FrontendConfig cfg;
    int n_long, n_short, n_acf, delta, history;

private:
    struct Sparse {  // one triangular filter per grid bin: (spectrum bin, weight) pairs
        std::vector<int> start, rows;
        std::vector<float> weights;
    };
    static Sparse filterbank(int n_fft, int sr, const std::vector<double>& centers_hz, double step_ratio);
    void apply(const Sparse& fb, const float* mag, float* db) const;  // 20 log10(fb * mag + 1e-7)
    void short_db(const float* seg, float* db);

    std::vector<float> w_long_, w_short_, w_acf_;
    float norm_long_, norm_short_;
    Sparse fb_long_, fb_short_;
    std::vector<int> stack_idx_;  // [n_harmonics][n_fine]
    std::vector<int> acf_i0_;     // [acf_multiples][n_fine]
    std::vector<float> acf_w0_, acf_w1_;
    std::vector<float> coord_;

    RealFFT fft_long_, fft_short_, fft_acf_;
    std::vector<float> tmp_, db_long_, db_prev_, mag_short_, r_;
    std::vector<Cpx> spec_;
};

}  // namespace pt
