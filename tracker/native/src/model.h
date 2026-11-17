// Frontend configuration and the pitch network (port of polytracker/config.py and polytracker/net.py).
#pragma once

#include <cmath>
#include <istream>
#include <string>
#include <vector>

namespace pt {

constexpr int REF_RATE = 48000;

// The vector instructions this binary was built for, e.g. "AArch64 NEON" (printed by `bench` and `run`), with a
// warning appended if the vector code was compiled to scalar operations.
const char* simd_info();

// Python's round(): halfway cases to even (std::nearbyint in the default rounding mode)
inline long pyround(double x) { return static_cast<long>(std::nearbyint(x)); }

inline double midi_to_hz(double m) { return 440.0 * std::pow(2.0, (m - 69.0) / 12.0); }

struct FrontendConfig {
    int sample_rate = REF_RATE;
    int hop = 256;
    int pitch_lo = 38, pitch_hi = 88, bins_per_semitone = 3;
    int grid_lo = 36, grid_semitones = 90, n_harmonics = 8;
    int long_win = 4096, short_win = 1024, acf_win = 2048, delta_lag = 1024;
    double window_peak = 0.85;
    int acf_multiples = 2;
    double db_range = 60.0, db_floor = -60.0;

    int n_pitch() const { return pitch_hi - pitch_lo + 1; }
    int n_fine() const { return n_pitch() * bins_per_semitone; }
    int n_grid() const { return grid_semitones * bins_per_semitone; }
    int n_channels() const { return 3 * n_harmonics + acf_multiples + 2 + 1; }
    // window length in samples for this sample rate (multiple of 16)
    int scaled(int n) const {
        long v = pyround(double(n) * sample_rate / REF_RATE / 16.0) * 16;
        return v < 16 ? 16 : int(v);
    }
    int delta_samples() const { return scaled(delta_lag); }
    int history() const {
        int h = scaled(long_win);
        if (scaled(acf_win) > h) h = scaled(acf_win);
        if (scaled(short_win) + delta_samples() > h) h = scaled(short_win) + delta_samples();
        return h;
    }
};

struct Layer {
    int k, stride, dilation, pad;
    bool relu, residual_in, residual_out;
    int c_out, c_in;
    std::vector<float> w;  // [c_out][k * c_in], tap-major
    std::vector<float> b;  // [c_out]
};

class PitchNet {
public:
    // Loads a .ptm written by native/export_model.py; throws std::runtime_error.
    static PitchNet load(const std::string& path);
    // The same from an open binary stream (a model compiled into a plugin); `path` only names it in errors.
    static PitchNet load(std::istream& f, const std::string& path);

    // x [n_channels][n_fine] -> probabilities [2][n_pitch] (frame head, onset head).
    // The returned pointer is valid until the next call.
    const float* predict_one(const float* x);

    FrontendConfig cfg;
    std::string name;
    std::vector<Layer> layers;
    int out_len = 0;  // n_pitch

private:
    void plan();
    struct Buf {
        int l_in, l_out, lp;      // lp: l_out rounded up to the tile width
        int row;                  // row stride of xpad: every tile may read a full vector at every tap
        std::vector<float> xpad;  // [c_in][row] zero-padded input (stride 1), read in place by the convolution
        std::vector<float> col;   // [k * c_in][lp] strided layers only: the input positions of every tap
        std::vector<float> wp;    // weights packed for the tiles
        std::vector<float> out;   // [c_out][l_out]
    };
    std::vector<Buf> bufs_;
};

}  // namespace pt
