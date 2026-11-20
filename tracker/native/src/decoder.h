// Note decoder and pitch refiner (port of polytracker/decoder.py and polytracker/refine.py).
#pragma once

#include <array>
#include <vector>

#include "model.h"

namespace pt {

struct DecoderParams {
    double on_thresh = 0.8, off_thresh = 0.4, onset_thresh = 0.4;
    double on_confirm_ms = 2.0, off_confirm_ms = 15.0, retrigger_ms = 90.0;
    // pitch correction of provisional notes (see decoder.py); correct_ms 0 = off
    double correct_ms = 0.0, correct_span = 12.0, correct_drop = 0.7;
    int max_voices = 6;
    double gate_db = -80.0, amp_range_db = 60.0;
    bool refine = true;
    double glide_alpha = 0.6, refine_every_ms = 12.0;
};

enum class EvKind { On, Off, Move };  // Move: same voice, new pitch, no new attack; prev = previous MIDI note

struct NoteEvent {
    EvKind kind;
    double t;
    int voice, pitch;
    double freq, amp;
    int prev = -1;
};

inline const char* kind_name(EvKind k) { return k == EvKind::On ? "on" : k == EvKind::Off ? "off" : "move"; }

constexpr int COLLISION_H = 10;  // harmonics of other notes that refinement avoids
using Harm = std::array<double, COLLISION_H>;

class PitchRefiner {
public:
    PitchRefiner(const FrontendConfig& cfg, int n_fft);
    Harm collision_harmonics(double f0) const;
    // refined f0, or a negative value if the spectrum does not support one. other_h: harmonics of the other notes.
    double refine(const float* mag, int n_bins, double f_guess, const std::vector<const Harm*>& other_h) const;
    // RMS magnitude of the strongest bin around the first `harmonics` harmonics of f0 (full-scale sine == 1)
    double band_level(const float* mag, int n_bins, double f0, int harmonics = 4) const;

private:
    double sr_, bin_hz_, nyq_limit_;
    int max_h_ = 6;
    double max_dev_ = 35.0, collision_bins_ = 3.5, agree_cents_ = 12.0;
    double stretch_[17];  // index h (1-based): sqrt(1 + B h^2)
};

class Decoder {
public:
    Decoder(const FrontendConfig& cfg, const DecoderParams& p, int n_fft);
    void reset();
    // mag: long-window magnitude (n_bins), may be null. Appends to `events`.
    void step(double t, const float* p_frame, const float* p_onset, const float* mag, int n_bins, double rms_db,
              std::vector<NoteEvent>& events);

    DecoderParams p;
    // per voice
    std::vector<int> v_pitch, v_midi;
    std::vector<double> v_freq, v_amp, v_t_on;

private:
    int free_voice(const float* pf, int cand) const;
    void set_freq(int p, double f);
    double amp_of(const float* mag, int n_bins, double f) const;
    void start(int p, double t, const float* pf, const float* mag, int n_bins, std::vector<NoteEvent>& ev, int voice);
    void stop(int p, double t, std::vector<NoteEvent>& ev);
    int provisional(int q, double t, const float* pf) const;
    void move(int p, int q, double t, const float* mag, int n_bins, std::vector<NoteEvent>& ev);
    const std::vector<const Harm*>& others_h(int p);
    void track(double t, const float* mag, int n_bins);

    FrontendConfig cfg_;
    int n_pitch_;
    PitchRefiner refiner_;
    std::vector<double> nominal_hz_;
    // per pitch
    std::vector<char> active_, armed_, trig_, wanted_;
    std::vector<int> voice_of_;
    std::vector<double> t_on_, above_since_, below_since_, est_freq_, t_refined_;
    std::vector<Harm> est_harm_;
    // scratch
    std::vector<float> zeros_;
    std::vector<int> list_, cands_, due_;
    std::vector<const Harm*> others_;
};

}  // namespace pt
