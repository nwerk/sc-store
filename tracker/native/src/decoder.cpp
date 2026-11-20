#include "decoder.h"

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <limits>
#include <numeric>

namespace pt {

namespace {
constexpr double INHARMONICITY = 8e-5;  // typical guitar string stiffness coefficient
constexpr double NaN = std::numeric_limits<double>::quiet_NaN();

struct Vote { double f, w; };
}  // namespace

// ------------------------------------------------------------------ refiner

PitchRefiner::PitchRefiner(const FrontendConfig& cfg, int n_fft)
    : sr_(cfg.sample_rate), bin_hz_(double(cfg.sample_rate) / n_fft), nyq_limit_(0.45 * cfg.sample_rate) {
    for (int h = 0; h <= 16; ++h) stretch_[h] = std::sqrt(1.0 + INHARMONICITY * h * h);
}

Harm PitchRefiner::collision_harmonics(double f0) const {
    Harm out;
    for (int h = 1; h <= COLLISION_H; ++h) out[h - 1] = f0 * h * stretch_[h];
    return out;
}

double PitchRefiner::refine(const float* mag, int n_bins, double f_guess,
                            const std::vector<const Harm*>& other_h) const {
    const double bin_hz = bin_hz_;
    const double spacing_bins = f_guess / bin_hz;
    const double dev_ratio = std::pow(2.0, max_dev_ / 1200.0) - 1.0;
    Vote votes[16];
    int nv = 0;
    for (int h = 1; h <= max_h_; ++h) {
        const double exp_f = f_guess * h * stretch_[h];
        if (exp_f > nyq_limit_ || exp_f > 7000.0) break;
        bool collides = false;  // sits on a partial of another sounding note
        for (const Harm* o : other_h) {
            for (double of : *o)
                if (std::fabs(of - exp_f) < collision_bins_ * bin_hz) { collides = true; break; }
            if (collides) break;
        }
        if (collides) continue;
        const double dev_bins = exp_f * dev_ratio / bin_hz;
        const double hw = std::max(1.5, std::min(dev_bins, 0.42 * spacing_bins));
        const double c = exp_f / bin_hz;
        int lo = int(std::floor(c - hw)), hi = int(std::ceil(c + hw));
        lo = std::max(1, lo);
        hi = std::min(n_bins - 2, hi);
        if (hi <= lo) continue;
        int k = lo;
        for (int i = lo + 1; i <= hi; ++i)
            if (mag[i] > mag[k]) k = i;  // first maximum, like argmax
        const double m = mag[k];
        if (m < 1e-5 || k <= 1 || k >= n_bins - 2) continue;
        const double a = std::log(double(mag[k - 1] + 1e-12f)), b = std::log(m + 1e-12),
                     g = std::log(double(mag[k + 1] + 1e-12f));
        if (!(b >= a && b >= g)) continue;  // not a local maximum: the window edge, not a partial
        const double denom = a - 2.0 * b + g;
        const double delta = denom < -1e-9 ? 0.5 * (a - g) / denom : 0.0;
        const double peak_f = (k + delta) * bin_hz;
        // undo the stiffness stretch so every harmonic votes for the same f0
        votes[nv++] = {peak_f / (h * std::sqrt(1.0 + INHARMONICITY * h * h)), m * h};
    }
    if (nv < 2) return -1.0;  // a single partial cannot be told apart from a neighbour's leakage
    // weighted median
    int order[16];
    std::iota(order, order + nv, 0);
    std::stable_sort(order, order + nv, [&](int i, int j) { return votes[i].f < votes[j].f; });
    double wsum = 0.0;
    for (int i = 0; i < nv; ++i) wsum += votes[i].w;
    const double half = 0.5 * wsum;
    double cum = 0.0, med = votes[order[nv - 1]].f;
    for (int i = 0; i < nv; ++i) {
        cum += votes[order[i]].w;
        if (cum >= half) { med = votes[order[i]].f; break; }
    }
    double fw = 0.0, ww = 0.0;
    int kept = 0;
    for (int i = 0; i < nv; ++i)
        if (std::fabs(1200.0 * std::log2(votes[i].f / med)) < agree_cents_) {
            fw += votes[i].f * votes[i].w;
            ww += votes[i].w;
            ++kept;
        }
    if (kept < 2) return -1.0;
    const double f0 = fw / ww;
    if (std::fabs(1200.0 * std::log2(f0 / f_guess)) > max_dev_ + 10) return -1.0;
    return f0;
}

double PitchRefiner::band_level(const float* mag, int n_bins, double f0, int harmonics) const {
    double acc = 0.0;
    int n = 0;
    for (int h = 1; h <= harmonics; ++h) {
        const long k = long(std::nearbyint(f0 * h * stretch_[h] / bin_hz_));
        if (k + 2 >= n_bins) break;
        double peak = 0.0;
        for (long i = std::max(0L, k - 1); i <= k + 1; ++i) peak = std::max(peak, double(mag[i]));
        acc += peak * peak;
        ++n;
    }
    return n ? std::sqrt(acc / n) : 0.0;
}

// ------------------------------------------------------------------ decoder

Decoder::Decoder(const FrontendConfig& cfg, const DecoderParams& params, int n_fft)
    : p(params), cfg_(cfg), n_pitch_(cfg.n_pitch()), refiner_(cfg, n_fft) {
    nominal_hz_.resize(n_pitch_);
    for (int i = 0; i < n_pitch_; ++i) nominal_hz_[i] = midi_to_hz(cfg.pitch_lo + i);
    zeros_.assign(n_pitch_, 0.0f);
    reset();
}

void Decoder::reset() {
    const int n = n_pitch_, v = p.max_voices;
    active_.assign(n, 0);
    armed_.assign(n, 1);
    trig_.assign(n, 0);
    wanted_.assign(n, 0);
    voice_of_.assign(n, -1);
    t_on_.assign(n, -1e9);
    above_since_.assign(n, NaN);
    below_since_.assign(n, NaN);
    est_freq_ = nominal_hz_;
    est_harm_.resize(n);
    for (int i = 0; i < n; ++i) est_harm_[i] = refiner_.collision_harmonics(est_freq_[i]);
    t_refined_.assign(n, -1e9);
    v_pitch.assign(v, -1);
    v_midi.assign(v, -1);
    v_freq.assign(v, 0.0);
    v_amp.assign(v, 0.0);
    v_t_on.assign(v, -1e9);
}

int Decoder::free_voice(const float* pf, int cand) const {
    const int V = int(v_pitch.size());
    for (int v = 0; v < V; ++v)
        if (v_pitch[v] < 0) return v;
    int weakest = 0;
    for (int v = 1; v < V; ++v)
        if (pf[v_pitch[v]] < pf[v_pitch[weakest]]) weakest = v;
    if (pf[cand] > pf[v_pitch[weakest]] + 0.1f) return -2 - weakest;  // steal this voice (float32, like numpy)
    return -1;
}

void Decoder::set_freq(int pi, double f) {
    est_freq_[pi] = f;
    est_harm_[pi] = refiner_.collision_harmonics(f);
}

double Decoder::amp_of(const float* mag, int n_bins, double f) const {
    if (!mag) return 0.0;
    const double level = refiner_.band_level(mag, n_bins, f);
    if (!(level > 0.0)) return 0.0;
    return std::clamp(1.0 + 20.0 * std::log10(level) / p.amp_range_db, 0.0, 1.0);
}

const std::vector<const Harm*>& Decoder::others_h(int pi) {
    others_.clear();
    for (int q = 0; q < n_pitch_; ++q)
        if (active_[q] && q != pi) others_.push_back(&est_harm_[q]);
    return others_;
}

void Decoder::start(int pi, double t, const float* pf, const float* mag, int n_bins, std::vector<NoteEvent>& ev,
                    int voice) {
    int v = voice >= 0 ? voice : free_voice(pf, pi);
    if (v == -1) return;
    if (v <= -2) {
        v = -2 - v;
        stop(v_pitch[v], t, ev);
    }
    active_[pi] = 1;
    voice_of_[pi] = v;
    t_on_[pi] = t;
    above_since_[pi] = NaN;
    below_since_[pi] = NaN;
    armed_[pi] = 0;
    set_freq(pi, nominal_hz_[pi]);
    t_refined_[pi] = t;
    v_pitch[v] = pi;
    v_midi[v] = cfg_.pitch_lo + pi;
    v_t_on[v] = t;
    double f = nominal_hz_[pi];
    if (p.refine && mag) {
        const double fr = refiner_.refine(mag, n_bins, f, others_h(pi));
        if (fr > 0.0) {
            f = fr;
            set_freq(pi, fr);
        }
    }
    v_freq[v] = f;
    v_amp[v] = amp_of(mag, n_bins, f);
    ev.push_back({EvKind::On, t, v, v_midi[v], f, v_amp[v]});
}

void Decoder::stop(int pi, double t, std::vector<NoteEvent>& ev) {
    const int v = voice_of_[pi];
    if (v < 0) return;
    ev.push_back({EvKind::Off, t, v, cfg_.pitch_lo + pi, v_freq[v], 0.0});
    active_[pi] = 0;
    voice_of_[pi] = -1;
    below_since_[pi] = NaN;
    v_pitch[v] = -1;
    v_amp[v] = 0.0;  // frequency stays as the last value for release tails
}

int Decoder::provisional(int q, double t, const float* pf) const {
    int best = -1;
    double best_pf = 2.0;
    const float drop = float(p.correct_drop);
    for (int pi = 0; pi < n_pitch_; ++pi) {
        if (!active_[pi] || t - t_on_[pi] >= p.correct_ms / 1e3 || pf[pi] >= drop) continue;
        const int d = std::abs(pi - q);
        if ((d <= int(p.correct_span) || d == 12 || d == 19 || d == 24) && pf[pi] < best_pf) {
            best = pi;
            best_pf = pf[pi];
        }
    }
    return best;
}

void Decoder::move(int pi, int q, double t, const float* mag, int n_bins, std::vector<NoteEvent>& ev) {
    const int v = voice_of_[pi];
    const double t_on = t_on_[pi];
    active_[pi] = 0;
    voice_of_[pi] = -1;
    below_since_[pi] = NaN;
    active_[q] = 1;
    voice_of_[q] = v;
    t_on_[q] = t_on;
    above_since_[q] = NaN;
    below_since_[q] = NaN;
    armed_[q] = 0;
    double f = nominal_hz_[q];
    set_freq(q, f);
    t_refined_[q] = t;
    if (p.refine && mag) {
        const double fr = refiner_.refine(mag, n_bins, f, others_h(q));
        if (fr > 0.0) {
            f = fr;
            set_freq(q, fr);
        }
    }
    const int prev = v_midi[v];
    v_pitch[v] = q;
    v_midi[v] = cfg_.pitch_lo + q;
    v_freq[v] = f;
    v_amp[v] = amp_of(mag, n_bins, f);
    ev.push_back({EvKind::Move, t, v, v_midi[v], f, v_amp[v], prev});
}

void Decoder::step(double t, const float* pf, const float* po, const float* mag, int n_bins, double rms_db,
                   std::vector<NoteEvent>& ev) {
    const int n = n_pitch_;
    if (rms_db < p.gate_db) {
        pf = zeros_.data();
        po = zeros_.data();
    }
    // Thresholds are compared in float32: numpy 2 converts a Python float to the array's dtype (NEP 50).
    const float on_t = float(p.on_thresh), half_on = float(0.5 * p.on_thresh), off_t = float(p.off_thresh);
    const float onset_t = float(p.onset_thresh), half_onset = float(0.5 * p.onset_thresh);
    for (int i = 0; i < n; ++i) {
        trig_[i] = (po[i] >= onset_t) && armed_[i];
        if (trig_[i]) armed_[i] = 0;
        if (po[i] < half_onset) armed_[i] = 1;
    }
    const double retrig_s = p.retrigger_ms / 1e3, on_s = p.on_confirm_ms / 1e3, off_s = p.off_confirm_ms / 1e3;

    list_.clear();
    for (int i = 0; i < n; ++i)
        if (active_[i]) list_.push_back(i);
    for (int pi : list_) {
        if (pf[pi] < off_t) {
            if (std::isnan(below_since_[pi])) below_since_[pi] = t;
            if (t - below_since_[pi] >= off_s) stop(pi, t, ev);
        } else {
            below_since_[pi] = NaN;
            if (trig_[pi] && t - t_on_[pi] >= retrig_s) {
                const int v = voice_of_[pi];
                stop(pi, t, ev);
                start(pi, t, pf, mag, n_bins, ev, v);
            }
        }
    }

    cands_.clear();
    for (int i = 0; i < n; ++i) {
        wanted_[i] = (pf[i] >= on_t) || (trig_[i] && pf[i] >= half_on);
        if (!active_[i] && wanted_[i]) cands_.push_back(i);
    }
    std::stable_sort(cands_.begin(), cands_.end(), [&](int a, int b) { return pf[a] > pf[b]; });
    for (int pi : cands_) {
        const bool fast = trig_[pi] && pf[pi] >= half_on;
        if (std::isnan(above_since_[pi])) above_since_[pi] = t;
        if (fast || t - above_since_[pi] >= on_s) {
            const int old = p.correct_ms > 0 ? provisional(pi, t, pf) : -1;
            if (old >= 0)
                move(old, pi, t, mag, n_bins, ev);
            else
                start(pi, t, pf, mag, n_bins, ev, -1);
        }
    }
    for (int i = 0; i < n; ++i)
        if (!active_[i] && !wanted_[i]) above_since_[i] = NaN;

    track(t, mag, n_bins);
}

void Decoder::track(double t, const float* mag, int n_bins) {
    const double refine_s = p.refine_every_ms / 1e3;
    list_.clear();
    for (int i = 0; i < n_pitch_; ++i)
        if (active_[i]) list_.push_back(i);
    if (list_.empty()) return;
    if (p.refine && mag) {
        due_.clear();
        for (int pi : list_)
            if (t - t_refined_[pi] >= refine_s) due_.push_back(pi);
        for (int pi : due_) {
            t_refined_[pi] = t;
            const double f = est_freq_[pi];
            const double fr = refiner_.refine(mag, n_bins, f, others_h(pi));
            if (fr > 0.0 && std::fabs(1200.0 * std::log2(fr / f)) < 40.0) {  // real pitch moves are smooth
                const double a = p.glide_alpha;
                set_freq(pi, (1.0 - a) * f + a * fr);
            }
        }
    }
    for (int pi : list_) {
        const int v = voice_of_[pi];
        v_freq[v] = est_freq_[pi];
        v_amp[v] = amp_of(mag, n_bins, est_freq_[pi]);
    }
}

}  // namespace pt
