// Real FFT of any length, matching numpy.fft.rfft / irfft (the inverse is scaled by 1/n like numpy's).
//
// Power-of-two lengths (all windows at 48 kHz) use one complex radix-2 FFT of length n/2. Other lengths (the
// windows are rescaled for other sample rates, e.g. 3760 samples at 44.1 kHz) use Bluestein's algorithm:
// three power-of-two FFTs of length >= 2n - 1, slower but exact to float precision.
#pragma once

#include <cmath>
#include <memory>
#include <vector>

namespace pt {

struct Cpx { float re, im; };

inline Cpx cmul(Cpx a, Cpx b) { return {a.re * b.re - a.im * b.im, a.re * b.im + a.im * b.re}; }
inline Cpx conj(Cpx a) { return {a.re, -a.im}; }

// In-place complex FFT of a power-of-two length m (inverse: conjugate twiddles, no scaling).
class ComplexFFT {
public:
    explicit ComplexFFT(int m) : m_(m), rev_(m), tw_(m / 2 > 0 ? m / 2 : 1) {
        int bits = 0;
        while ((1 << bits) < m_) ++bits;
        for (int i = 0; i < m_; ++i) {
            int r = 0;
            for (int b = 0; b < bits; ++b) r |= ((i >> b) & 1) << (bits - 1 - b);
            rev_[i] = r;
        }
        for (int j = 0; j < m_ / 2; ++j) {
            const double a = -2.0 * M_PI * j / m_;
            tw_[j] = {float(std::cos(a)), float(std::sin(a))};
        }
    }

    // `already_permuted`: z was written in bit-reversed order by the caller (saves a pass)
    void run(Cpx* z, bool inverse, bool already_permuted = false) const {
        if (!already_permuted)
            for (int i = 0; i < m_; ++i)
                if (i < rev_[i]) std::swap(z[i], z[rev_[i]]);
        for (int len = 2; len <= m_; len <<= 1) {
            const int half = len >> 1, step = m_ / len;
            for (int i = 0; i < m_; i += len)
                for (int j = 0; j < half; ++j) {
                    Cpx w = tw_[j * step];
                    if (inverse) w.im = -w.im;
                    Cpx& u = z[i + j];
                    Cpx& v = z[i + j + half];
                    const Cpx t = cmul(v, w);
                    v = {u.re - t.re, u.im - t.im};
                    u = {u.re + t.re, u.im + t.im};
                }
        }
    }

    int size() const { return m_; }
    int rev(int i) const { return rev_[i]; }

private:
    int m_;
    std::vector<int> rev_;
    std::vector<Cpx> tw_;
};

class RealFFT {
public:
    explicit RealFFT(int n) : n_(n), m_(n / 2) {
        if (n >= 4 && !(n & (n - 1))) {
            half_ = std::make_unique<ComplexFFT>(m_);
            split_.resize(m_ + 1);
            for (int k = 0; k <= m_; ++k) {
                const double a = -2.0 * M_PI * k / n_;
                split_[k] = {float(std::cos(a)), float(std::sin(a))};
            }
            z_.resize(m_);
        } else {
            init_bluestein();
        }
    }

    int size() const { return n_; }

    // in: n real samples -> out: n/2 + 1 bins
    void forward(const float* in, Cpx* out) {
        if (!half_) {
            for (int j = 0; j < n_; ++j) x_[j] = {in[j], 0.0f};
            bluestein(x_.data(), X_.data());
            for (int k = 0; k <= n_ / 2; ++k) out[k] = X_[k];
            return;
        }
        for (int i = 0; i < m_; ++i) z_[half_->rev(i)] = {in[2 * i], in[2 * i + 1]};
        half_->run(z_.data(), false, true);
        const Cpx z0 = z_[0];
        out[0] = {z0.re + z0.im, 0.0f};
        out[m_] = {z0.re - z0.im, 0.0f};
        for (int k = 1; k < m_; ++k) {
            const Cpx a = z_[k], b = z_[m_ - k];  // X[k] = E[k] + w^k O[k]
            const Cpx e = {0.5f * (a.re + b.re), 0.5f * (a.im - b.im)};    // E = (Z[k] + conj Z[m-k]) / 2
            const Cpx o = {0.5f * (a.im + b.im), -0.5f * (a.re - b.re)};   // O = (Z[k] - conj Z[m-k]) / 2i
            const Cpx wo = cmul(split_[k], o);
            out[k] = {e.re + wo.re, e.im + wo.im};
        }
    }

    // in: n/2 + 1 bins -> out: n real samples (scaled by 1/n); like numpy, the imaginary parts of bin 0 (and of
    // bin n/2 for even n) are ignored
    void inverse(const Cpx* in, float* out) {
        if (!half_) {
            // x = conj(DFT(conj X)) / n over the full Hermitian spectrum
            const int nh = n_ / 2;
            for (int k = 0; k <= nh; ++k) x_[k] = conj(in[k]);
            x_[0].im = 0.0f;
            if (n_ % 2 == 0) x_[nh].im = 0.0f;
            for (int k = nh + 1; k < n_; ++k) x_[k] = in[n_ - k];  // conj(conj(X[n-k]))
            bluestein(x_.data(), X_.data());
            const float s = 1.0f / n_;
            for (int j = 0; j < n_; ++j) out[j] = X_[j].re * s;
            return;
        }
        for (int k = 0; k < m_; ++k) {
            Cpx a = in[k], b = in[m_ - k];
            if (k == 0) { a.im = 0.0f; b.im = 0.0f; }
            // E = (X[k] + conj X[m-k]) / 2,  O = (X[k] - conj X[m-k]) / 2 * conj(w^k)
            const Cpx e = {0.5f * (a.re + b.re), 0.5f * (a.im - b.im)};
            const Cpx d = {0.5f * (a.re - b.re), 0.5f * (a.im + b.im)};
            const Cpx o = cmul(d, conj(split_[k]));
            z_[half_->rev(k)] = {e.re - o.im, e.im + o.re};  // Z = E + i O
        }
        half_->run(z_.data(), true, true);
        const float s = 1.0f / m_;
        for (int i = 0; i < m_; ++i) {
            out[2 * i] = z_[i].re * s;
            out[2 * i + 1] = z_[i].im * s;
        }
    }

private:
    void init_bluestein() {
        int M = 1;
        while (M < 2 * n_ - 1) M <<= 1;
        big_ = std::make_unique<ComplexFFT>(M);
        chirp_.resize(n_);
        for (long j = 0; j < n_; ++j) {  // exp(-i pi j^2 / n), with j^2 reduced mod 2n for precision
            const double a = -M_PI * double((j * j) % (2L * n_)) / n_;
            chirp_[j] = {float(std::cos(a)), float(std::sin(a))};
        }
        bhat_.assign(M, {0.0f, 0.0f});
        bhat_[0] = conj(chirp_[0]);
        for (int j = 1; j < n_; ++j) bhat_[j] = bhat_[M - j] = conj(chirp_[j]);
        big_->run(bhat_.data(), false);
        buf_.resize(M);
        x_.resize(n_);
        X_.resize(n_);
    }

    // forward DFT of n complex values
    void bluestein(const Cpx* x, Cpx* X) {
        const int M = big_->size();
        for (int j = 0; j < n_; ++j) buf_[j] = cmul(x[j], chirp_[j]);
        for (int j = n_; j < M; ++j) buf_[j] = {0.0f, 0.0f};
        big_->run(buf_.data(), false);
        for (int j = 0; j < M; ++j) buf_[j] = cmul(buf_[j], bhat_[j]);
        big_->run(buf_.data(), true);
        const float s = 1.0f / M;
        for (int k = 0; k < n_; ++k) {
            const Cpx c = cmul(buf_[k], chirp_[k]);
            X[k] = {c.re * s, c.im * s};
        }
    }

    int n_, m_;
    // power of two
    std::unique_ptr<ComplexFFT> half_;
    std::vector<Cpx> split_, z_;
    // Bluestein
    std::unique_ptr<ComplexFFT> big_;
    std::vector<Cpx> chirp_, bhat_, buf_, x_, X_;
};

}  // namespace pt
