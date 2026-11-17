// Real FFT of any length, matching numpy.fft.rfft / irfft (the inverse is scaled by 1/n like numpy's).
//
// Power-of-two lengths (all windows at 48 kHz) use one complex FFT of length n/2. Other lengths (the windows are
// rescaled for other sample rates, e.g. 3760 samples at 44.1 kHz) use Bluestein's algorithm: three power-of-two
// FFTs of length >= 2n - 1, slower but exact to float precision.
//
// The complex FFT works on separate real and imaginary arrays and does two radix-2 stages per pass (radix 4), with
// the twiddle factors of every pass stored in the order the pass reads them. So the inner loops are plain
// element-wise arithmetic on contiguous floats, written with GCC/Clang vector types (AVX on x86, NEON on ARM).
#pragma once

#include <cmath>
#include <cstring>
#include <memory>
#include <utility>
#include <vector>

namespace pt {

namespace simd {
typedef float v4 __attribute__((vector_size(16)));
typedef float v8 __attribute__((vector_size(32)));  // one AVX register, or two NEON / SSE registers
// widest type whose arithmetic is one instruction per operation here. The FFT passes hold 12 values plus
// temporaries at once, so they must not be made of register pairs.
#if defined(__AVX__)
typedef v8 vn;
#else
typedef v4 vn;
#endif
template <class V> inline V load(const float* p) { V v; std::memcpy(&v, p, sizeof v); return v; }
template <class V> inline void store(float* p, V v) { std::memcpy(p, &v, sizeof v); }
}  // namespace simd

// In-place complex FFT of a power-of-two length m, no scaling. The input must already be in bit-reversed order
// (see rev()). The inverse transform is the same call with the two arrays swapped: run(im, re).
class ComplexFFT {
public:
    explicit ComplexFFT(int m) : m_(m), rev_(m) {
        int bits = 0;
        while ((1 << bits) < m_) ++bits;
        for (int i = 0; i < m_; ++i) {
            int r = 0;
            for (int b = 0; b < bits; ++b) r |= ((i >> b) & 1) << (bits - 1 - b);
            rev_[i] = r;
        }
        // the first pass (blocks of 4, or of 2 if m == 2) needs no twiddles
        for (int h = m_ >= 4 ? 4 : m_; h < m_;) {
            Pass p;
            p.h = h;
            p.radix = 4 * h <= m_ ? 4 : 2;
            p.offset = int(tw_.size());
            tw_.resize(tw_.size() + size_t(p.radix == 4 ? 4 : 2) * h);
            float* t = &tw_[p.offset];
            for (int j = 0; j < h; ++j) {  // w = exp(-2 pi i j / 2h), v = exp(-2 pi i j / 4h)
                const double a = -M_PI * j / h;
                t[j] = float(std::cos(a));
                t[h + j] = float(std::sin(a));
                if (p.radix == 4) {
                    t[2 * h + j] = float(std::cos(0.5 * a));
                    t[3 * h + j] = float(std::sin(0.5 * a));
                }
            }
            passes_.push_back(p);
            h *= p.radix;
        }
    }

    void run(float* re, float* im) const {
        if (m_ >= 4) {
            for (int i = 0; i < m_; i += 4) {
                const float ar = re[i] + re[i + 1], ai = im[i] + im[i + 1];
                const float br = re[i] - re[i + 1], bi = im[i] - im[i + 1];
                const float cr = re[i + 2] + re[i + 3], ci = im[i + 2] + im[i + 3];
                const float dr = re[i + 2] - re[i + 3], di = im[i + 2] - im[i + 3];
                re[i] = ar + cr;     im[i] = ai + ci;
                re[i + 2] = ar - cr; im[i + 2] = ai - ci;
                re[i + 1] = br + di; im[i + 1] = bi - dr;  // b + (-i) d
                re[i + 3] = br - di; im[i + 3] = bi + dr;
            }
        } else if (m_ == 2) {
            const float ar = re[0], ai = im[0];
            re[0] = ar + re[1]; im[0] = ai + im[1];
            re[1] = ar - re[1]; im[1] = ai - im[1];
        }
        later_passes(re, im);
    }

    // Forward FFT of z[i] = in[2i] + i in[2i + 1] given in natural order (m >= 4). The bit-reversal is folded into
    // the first pass: block q of the permuted input is z[r], z[r + m/2], z[r + m/4], z[r + 3m/4] with
    // r = rev(4q), so the pass reads those four and writes its block in order - no separate reordering pass.
    void run_interleaved(const float* in, float* re, float* im) const {
        const int q4 = m_ / 4, h2 = m_ / 2;
        for (int q = 0; q < q4; ++q) {
            const float* z0 = in + 2 * rev_[4 * q];
            const float *z1 = z0 + 2 * h2, *z2 = z0 + 2 * q4, *z3 = z2 + 2 * h2;
            const float ar = z0[0] + z1[0], ai = z0[1] + z1[1];
            const float br = z0[0] - z1[0], bi = z0[1] - z1[1];
            const float cr = z2[0] + z3[0], ci = z2[1] + z3[1];
            const float dr = z2[0] - z3[0], di = z2[1] - z3[1];
            const int i = 4 * q;
            re[i] = ar + cr;     im[i] = ai + ci;
            re[i + 2] = ar - cr; im[i + 2] = ai - ci;
            re[i + 1] = br + di; im[i + 1] = bi - dr;
            re[i + 3] = br - di; im[i + 3] = bi + dr;
        }
        later_passes(re, im);
    }

    // general entry: natural order in, natural order out
    void transform(float* re, float* im, bool inverse) const {
        for (int i = 0; i < m_; ++i)
            if (i < rev_[i]) {
                std::swap(re[i], re[rev_[i]]);
                std::swap(im[i], im[rev_[i]]);
            }
        if (inverse) run(im, re);
        else run(re, im);
    }

    int size() const { return m_; }
    int rev(int i) const { return rev_[i]; }
    const int* rev_table() const { return rev_.data(); }

private:
    struct Pass { int h, radix, offset; };

    void later_passes(float* re, float* im) const {
        for (const Pass& p : passes_) {
            const float* t = &tw_[p.offset];
            const bool wide = p.h >= int(sizeof(simd::vn) / sizeof(float));
            if (p.radix == 4) {
                if (wide) pass4<simd::vn>(re, im, p.h, t);
                else pass4<simd::v4>(re, im, p.h, t);
            } else {
                if (wide) pass2<simd::vn>(re, im, p.h, t);
                else pass2<simd::v4>(re, im, p.h, t);
            }
        }
    }

    // two radix-2 stages at once on blocks of 4h: (a, b, c, d) = z[j], z[j + h], z[j + 2h], z[j + 3h]
    template <class V> void pass4(float* re, float* im, int h, const float* t) const {
        using simd::load;
        using simd::store;
        const int W = int(sizeof(V) / sizeof(float));
        const float *wr = t, *wi = t + h, *vr = t + 2 * h, *vi = t + 3 * h;
        for (int i = 0; i < m_; i += 4 * h) {
            float *r0 = re + i, *r1 = r0 + h, *r2 = r1 + h, *r3 = r2 + h;
            float *i0 = im + i, *i1 = i0 + h, *i2 = i1 + h, *i3 = i2 + h;
            for (int j = 0; j < h; j += W) {
                const V w_r = load<V>(wr + j), w_i = load<V>(wi + j), v_r = load<V>(vr + j), v_i = load<V>(vi + j);
                const V ar = load<V>(r0 + j), ai = load<V>(i0 + j), br = load<V>(r1 + j), bi = load<V>(i1 + j);
                const V cr = load<V>(r2 + j), ci = load<V>(i2 + j), dr = load<V>(r3 + j), di = load<V>(i3 + j);
                // stage 1 (blocks of 2h): a +- w b, c +- w d
                const V tbr = br * w_r - bi * w_i, tbi = br * w_i + bi * w_r;
                const V tdr = dr * w_r - di * w_i, tdi = dr * w_i + di * w_r;
                const V a1r = ar + tbr, a1i = ai + tbi, b1r = ar - tbr, b1i = ai - tbi;
                const V c1r = cr + tdr, c1i = ci + tdi, d1r = cr - tdr, d1i = ci - tdi;
                // stage 2 (blocks of 4h): a1 +- v c1, b1 +- (-i v) d1
                const V tcr = c1r * v_r - c1i * v_i, tci = c1r * v_i + c1i * v_r;
                const V qr = d1r * v_r - d1i * v_i, qi = d1r * v_i + d1i * v_r;
                store<V>(r0 + j, a1r + tcr); store<V>(i0 + j, a1i + tci);
                store<V>(r2 + j, a1r - tcr); store<V>(i2 + j, a1i - tci);
                store<V>(r1 + j, b1r + qi);  store<V>(i1 + j, b1i - qr);
                store<V>(r3 + j, b1r - qi);  store<V>(i3 + j, b1i + qr);
            }
        }
    }

    template <class V> void pass2(float* re, float* im, int h, const float* t) const {
        using simd::load;
        using simd::store;
        const int W = int(sizeof(V) / sizeof(float));
        const float *wr = t, *wi = t + h;
        for (int i = 0; i < m_; i += 2 * h) {
            float *r0 = re + i, *r1 = r0 + h, *i0 = im + i, *i1 = i0 + h;
            for (int j = 0; j < h; j += W) {
                const V w_r = load<V>(wr + j), w_i = load<V>(wi + j);
                const V ar = load<V>(r0 + j), ai = load<V>(i0 + j), br = load<V>(r1 + j), bi = load<V>(i1 + j);
                const V tr = br * w_r - bi * w_i, ti = br * w_i + bi * w_r;
                store<V>(r0 + j, ar + tr); store<V>(i0 + j, ai + ti);
                store<V>(r1 + j, ar - tr); store<V>(i1 + j, ai - ti);
            }
        }
    }

    int m_;
    std::vector<int> rev_;
    std::vector<Pass> passes_;
    std::vector<float> tw_;
};

class RealFFT {
public:
    explicit RealFFT(int n) : n_(n), m_(n / 2) {
        if (n >= 4 && !(n & (n - 1))) {
            half_ = std::make_unique<ComplexFFT>(m_);
            split_r_.resize(m_ + 1);
            split_i_.resize(m_ + 1);
            for (int k = 0; k <= m_; ++k) {
                const double a = -2.0 * M_PI * k / n_;
                split_r_[k] = float(std::cos(a));
                split_i_[k] = float(std::sin(a));
            }
            zr_.resize(m_);
            zi_.resize(m_);
        } else {
            init_bluestein();
        }
    }

    int size() const { return n_; }

    // in: n real samples -> re, im: n/2 + 1 bins each
    void forward(const float* in, float* re, float* im) {
        if (!half_) {
            for (int j = 0; j < n_; ++j) { xr_[j] = in[j]; xi_[j] = 0.0f; }
            bluestein(xr_.data(), xi_.data(), Xr_.data(), Xi_.data());
            for (int k = 0; k <= n_ / 2; ++k) { re[k] = Xr_[k]; im[k] = Xi_[k]; }
            return;
        }
        float *zr = zr_.data(), *zi = zi_.data();
        if (m_ >= 4) {
            half_->run_interleaved(in, zr, zi);
        } else {
            for (int i = 0; i < m_; ++i) {
                zr[half_->rev(i)] = in[2 * i];
                zi[half_->rev(i)] = in[2 * i + 1];
            }
            half_->run(zr, zi);
        }
        re[0] = zr[0] + zi[0];  im[0] = 0.0f;
        re[m_] = zr[0] - zi[0]; im[m_] = 0.0f;
        const float *sr = split_r_.data(), *si = split_i_.data();
        // X[k] = E[k] + w^k O[k]. Bins k and m - k share E and O up to signs (w^(m-k) = -conj(w^k)), so both are
        // written from one set of products.
        for (int k = 1; k <= m_ / 2; ++k) {
            const float ar = zr[k], ai = zi[k], br = zr[m_ - k], bi = zi[m_ - k];
            const float er = 0.5f * (ar + br), ei = 0.5f * (ai - bi);     // E = (Z[k] + conj Z[m-k]) / 2
            const float o_r = 0.5f * (ai + bi), oi = -0.5f * (ar - br);   // O = (Z[k] - conj Z[m-k]) / 2i
            const float pr = sr[k] * o_r - si[k] * oi, pi = sr[k] * oi + si[k] * o_r;
            re[k] = er + pr;
            im[k] = ei + pi;
            re[m_ - k] = er - pr;
            im[m_ - k] = pi - ei;
        }
    }

    // re, im: n/2 + 1 bins -> out: n real samples (scaled by 1/n); like numpy, the imaginary parts of bin 0 (and
    // of bin n/2 for even n) are ignored. im == nullptr: a real spectrum (the autocorrelation's power spectrum).
    void inverse(const float* re, const float* im, float* out) {
        if (!half_) {
            // x = conj(DFT(conj X)) / n over the full Hermitian spectrum
            const int nh = n_ / 2;
            for (int k = 0; k <= nh; ++k) { xr_[k] = re[k]; xi_[k] = im ? -im[k] : 0.0f; }
            xi_[0] = 0.0f;
            if (n_ % 2 == 0) xi_[nh] = 0.0f;
            for (int k = nh + 1; k < n_; ++k) { xr_[k] = re[n_ - k]; xi_[k] = im ? im[n_ - k] : 0.0f; }
            bluestein(xr_.data(), xi_.data(), Xr_.data(), Xi_.data());
            const float s = 1.0f / n_;
            for (int j = 0; j < n_; ++j) out[j] = Xr_[j] * s;
            return;
        }
        const int* rev = half_->rev_table();
        float *zr = zr_.data(), *zi = zi_.data();
        const float *sr = split_r_.data(), *si = split_i_.data();
        const float s = 1.0f / m_;  // the scaling, applied here to save a pass
        // Z[k] = E + i O with E = (X[k] + conj X[m-k]) / 2 and O = (X[k] - conj X[m-k]) / 2 * conj(w^k); as in
        // forward(), Z[k] and Z[m-k] come from the same products
        zr[0] = 0.5f * (re[0] + re[m_]) * s;
        zi[0] = 0.5f * (re[0] - re[m_]) * s;
        for (int k = 1; k <= m_ / 2; ++k) {
            const float ar = re[k], br = re[m_ - k];
            const float ai = im ? im[k] : 0.0f, bi = im ? im[m_ - k] : 0.0f;
            const float er = 0.5f * (ar + br) * s, ei = 0.5f * (ai - bi) * s;
            const float dr = 0.5f * (ar - br) * s, di = 0.5f * (ai + bi) * s;
            const float o_r = dr * sr[k] + di * si[k], oi = di * sr[k] - dr * si[k];
            zr[rev[k]] = er - oi;
            zi[rev[k]] = ei + o_r;
            zr[rev[m_ - k]] = er + oi;
            zi[rev[m_ - k]] = o_r - ei;
        }
        half_->run(zi, zr);  // inverse: real and imaginary parts swapped
        for (int i = 0; i < m_; ++i) {
            out[2 * i] = zr[i];
            out[2 * i + 1] = zi[i];
        }
    }

private:
    void init_bluestein() {
        int M = 1;
        while (M < 2 * n_ - 1) M <<= 1;
        big_ = std::make_unique<ComplexFFT>(M);
        chirp_r_.resize(n_);
        chirp_i_.resize(n_);
        for (long j = 0; j < n_; ++j) {  // exp(-i pi j^2 / n), with j^2 reduced mod 2n for precision
            const double a = -M_PI * double((j * j) % (2L * n_)) / n_;
            chirp_r_[j] = float(std::cos(a));
            chirp_i_[j] = float(std::sin(a));
        }
        bhat_r_.assign(M, 0.0f);
        bhat_i_.assign(M, 0.0f);
        bhat_r_[0] = chirp_r_[0];
        bhat_i_[0] = -chirp_i_[0];
        for (int j = 1; j < n_; ++j) {
            bhat_r_[j] = bhat_r_[M - j] = chirp_r_[j];
            bhat_i_[j] = bhat_i_[M - j] = -chirp_i_[j];
        }
        big_->transform(bhat_r_.data(), bhat_i_.data(), false);
        buf_r_.resize(M);
        buf_i_.resize(M);
        xr_.resize(n_);
        xi_.resize(n_);
        Xr_.resize(n_);
        Xi_.resize(n_);
    }

    // forward DFT of n complex values
    void bluestein(const float* xr, const float* xi, float* Xr, float* Xi) {
        const int M = big_->size();
        float *br = buf_r_.data(), *bi = buf_i_.data();
        for (int j = 0; j < n_; ++j) {
            br[j] = xr[j] * chirp_r_[j] - xi[j] * chirp_i_[j];
            bi[j] = xr[j] * chirp_i_[j] + xi[j] * chirp_r_[j];
        }
        for (int j = n_; j < M; ++j) br[j] = bi[j] = 0.0f;
        big_->transform(br, bi, false);
        for (int j = 0; j < M; ++j) {
            const float r = br[j] * bhat_r_[j] - bi[j] * bhat_i_[j];
            bi[j] = br[j] * bhat_i_[j] + bi[j] * bhat_r_[j];
            br[j] = r;
        }
        big_->transform(br, bi, true);
        const float s = 1.0f / M;
        for (int k = 0; k < n_; ++k) {
            Xr[k] = (br[k] * chirp_r_[k] - bi[k] * chirp_i_[k]) * s;
            Xi[k] = (br[k] * chirp_i_[k] + bi[k] * chirp_r_[k]) * s;
        }
    }

    int n_, m_;
    // power of two
    std::unique_ptr<ComplexFFT> half_;
    std::vector<float> split_r_, split_i_, zr_, zi_;
    // Bluestein
    std::unique_ptr<ComplexFFT> big_;
    std::vector<float> chirp_r_, chirp_i_, bhat_r_, bhat_i_, buf_r_, buf_i_, xr_, xi_, Xr_, Xi_;
};

}  // namespace pt
