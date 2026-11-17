// Frontend + network + decoder wired together (port of polytracker/engine.py, realtime path).
#pragma once

#include <chrono>
#include <stdexcept>
#include <string>
#include <vector>

#include "decoder.h"
#include "frontend.h"
#include "model.h"

namespace pt {

inline FrontendConfig with_rate(FrontendConfig c, int sample_rate, int hop) {
    c.sample_rate = sample_rate;
    c.hop = hop;
    return c;
}

class Tracker {
public:
    Tracker(PitchNet& net, const DecoderParams& params, int sample_rate, int hop)
        : net(net), cfg(with_rate(net.cfg, sample_rate, hop)), fe(cfg), dec(cfg, params, fe.n_long) {
        if (cfg.delta_samples() % cfg.hop)
            throw std::runtime_error("hop " + std::to_string(cfg.hop) + " must divide the delta lag (" +
                                     std::to_string(cfg.delta_samples()) + " samples)");
        // the short spectrum of the frame delta samples back is reused; a few spare slots for skipped frames
        cache_.resize(2 * (cfg.delta_samples() / cfg.hop) + 4);
        for (Slot& s : cache_) s.db.resize(cfg.n_grid());
    }

    int history() const { return cfg.history(); }

    // One frame: hist holds the newest history() samples, ending at absolute stream time t (seconds).
    // Appends note events; the voice state is in dec.v_*.
    void process(const float* hist, double t, std::vector<NoteEvent>& events) {
        const long end = pyround(t * cfg.sample_rate);
        const long prev_end = end - cfg.delta_samples();
        Slot* prev = find(prev_end);
        const double t0 = timing ? clock() : 0.0;
        fe.compute(hist, prev ? prev->db.data() : nullptr, feat);
        if (prev) prev->used = false;  // popped, like the Python dict
        Slot* s = free_slot(end);
        s->end = end;
        s->used = true;
        s->db = feat.db_short;
        const double t1 = timing ? clock() : 0.0;
        last_probs = net.predict_one(feat.x.data());
        const double t2 = timing ? clock() : 0.0;
        dec.step(t, last_probs, last_probs + net.out_len, feat.mag_long.data(), int(feat.mag_long.size()),
                 feat.rms_db, events);
        if (timing) {
            const double t3 = clock();
            stage.frontend += t1 - t0;
            stage.network += t2 - t1;
            stage.decoder += t3 - t2;
            ++stage.frames;
        }
    }

    void reset() {
        stage = StageTimes{};
        dec.reset();
        for (Slot& s : cache_) s.used = false;
    }

    PitchNet& net;
    const FrontendConfig cfg;
    Frontend fe;
    Decoder dec;
    Features feat;
    const float* last_probs = nullptr;  // [2][n_pitch] of the last frame

    // per-stage time, summed over frames (seconds); only measured while `timing` is set (bench)
    struct StageTimes { double frontend = 0, network = 0, decoder = 0; long frames = 0; };
    bool timing = false;
    StageTimes stage;

private:
    static double clock() {
        return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    }
    struct Slot {
        long end = 0;
        bool used = false;
        std::vector<float> db;
    };
    Slot* find(long end) {
        for (Slot& s : cache_)
            if (s.used && s.end == end) return &s;
        return nullptr;
    }
    // frames were skipped: entries older than end - delta can never be asked for again
    Slot* free_slot(long end) {
        for (Slot& s : cache_)
            if (s.used && s.end <= end - cfg.delta_samples()) s.used = false;
        Slot* oldest = &cache_[0];
        for (Slot& s : cache_) {
            if (!s.used) return &s;
            if (s.end < oldest->end) oldest = &s;
        }
        return oldest;
    }
    std::vector<Slot> cache_;
};

}  // namespace pt
