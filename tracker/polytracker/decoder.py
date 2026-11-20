"""Turns per-frame pitch probabilities into note events and per-voice state.

Time-based (not frame-count based) so dropped frames or a different hop do not
change the behaviour. Hysteresis avoids flicker, the onset head re-triggers
repeated notes and lets new notes start before the frame head is fully sure.

Correction (``correct_ms`` > 0): a note is provisional for its first ``correct_ms``. If, in that time, a related
pitch (a neighbour within ``correct_span`` semitones, or an octave, twelfth or two octaves away) wants to start
while the provisional note has lost its support (frame probability below ``correct_drop``), the voice is moved
to the new pitch ("move" event) instead of ending one note and starting another. Notes can then start on less
evidence: a wrong first guess costs a pitch change inside the attack, not a second pluck.
"""
from __future__ import annotations

import math
from dataclasses import dataclass, field, asdict

import numpy as np

from .config import FrontendConfig, midi_to_hz
from .refine import PitchRefiner


@dataclass
class DecoderParams:
    # on/onset/on_confirm_ms tuned on GuitarSet player 04: notes start mostly from the onset head (at half of
    # on_thresh), the frame head alone needs more certainty
    on_thresh: float = 0.8  # frame probability that starts a note
    off_thresh: float = 0.4  # frame probability below which a note is ending
    onset_thresh: float = 0.4  # onset-head probability that signals a pick
    on_confirm_ms: float = 2.0  # frame probability must hold this long (0 = immediate)
    off_confirm_ms: float = 15.0
    retrigger_ms: float = 90.0  # minimum time between two onsets of the same pitch
    max_voices: int = 6
    gate_db: float = -80.0  # long-window RMS below this silences the tracker
    amp_range_db: float = 60.0  # voice amplitude 0 at -range dBFS, 1 at 0 dBFS
    refine: bool = True
    glide_alpha: float = 0.6  # smoothing of the refined frequency (1 = none)
    refine_every_ms: float = 12.0  # pitch refinement interval per note (it is the most expensive decoder step)
    correct_ms: float = 0.0  # a note's pitch may be corrected (moved) this long after its start (0 = never; 60 tuned)
    correct_span: int = 12  # neighbours up to this many semitones count as related (plus 19 and 24)
    correct_drop: float = 0.7  # the provisional pitch must have fallen below this frame probability

    def to_dict(self):
        return asdict(self)


@dataclass
class NoteEvent:
    kind: str  # "on" | "off" | "move" (same voice, new pitch, no new attack; ``prev`` = previous MIDI note)
    t: float  # seconds (time of the frame that produced the event)
    voice: int
    pitch: int  # MIDI note
    freq: float
    amp: float
    prev: int = -1


@dataclass
class VoiceState:
    active: np.ndarray
    midi: np.ndarray
    freq: np.ndarray
    amp: np.ndarray
    t_on: np.ndarray = field(default=None)


class Decoder:
    def __init__(self, cfg: FrontendConfig, params: DecoderParams | None = None, n_fft: int | None = None):
        self.cfg = cfg
        self.p = params or DecoderParams()
        self.n_pitch = cfg.n_pitch
        self.nominal_hz = midi_to_hz(cfg.pitch_lo + np.arange(self.n_pitch))
        self.refiner = PitchRefiner(cfg, n_fft or cfg.scaled(cfg.long_win))
        self.reset()

    def reset(self):
        n, v = self.n_pitch, self.p.max_voices
        self.active = np.zeros(n, dtype=bool)
        self.voice_of = np.full(n, -1, dtype=np.int64)
        self.t_on = np.full(n, -1e9)
        self.above_since = np.full(n, np.nan)
        self.below_since = np.full(n, np.nan)
        self.armed = np.ones(n, dtype=bool)
        self.est_freq = self.nominal_hz.copy()
        self.est_harm = self.refiner.collision_harmonics(self.est_freq)  # [n_pitch, 10], kept in sync with est_freq
        self.t_refined = np.full(n, -1e9)
        self.v_pitch = np.full(v, -1, dtype=np.int64)  # pitch index per voice
        self.v_midi = np.full(v, -1, dtype=np.int64)
        self.v_freq = np.zeros(v)
        self.v_amp = np.zeros(v)
        self.v_t_on = np.full(v, -1e9)

    # ------------------------------------------------------------------ helpers
    def _free_voice(self, pf, cand):
        free = np.flatnonzero(self.v_pitch < 0)
        if free.size:
            return int(free[0])
        act = self.v_pitch
        weakest = int(np.argmin(pf[act]))
        if pf[cand] > pf[act[weakest]] + 0.1:
            return -2 - weakest  # signal: steal this voice
        return -1

    def _set_freq(self, p, f):
        self.est_freq[p] = f
        self.est_harm[p] = self.refiner.collision_harmonics(f)[0]

    def _amps(self, mag, f0s) -> np.ndarray:
        """Voice amplitude 0..1 from the spectrum level around the first harmonics of each ``f0``."""
        f0s = np.asarray(f0s, dtype=np.float64)
        if mag is None or not f0s.size:
            return np.zeros(f0s.size)
        level = self.refiner.band_levels(mag, f0s)
        with np.errstate(divide="ignore"):
            db = 20.0 * np.log10(level)
        return np.where(level > 0.0, np.clip(1.0 + db / self.p.amp_range_db, 0.0, 1.0), 0.0)

    def _start(self, p, t, pf, mag, events, voice=None):
        v = voice if voice is not None else self._free_voice(pf, p)
        if v == -1:
            return
        if v <= -2:
            v = -2 - v
            self._stop(int(self.v_pitch[v]), t, events)
        self.active[p] = True
        self.voice_of[p] = v
        self.t_on[p] = t
        self.above_since[p] = np.nan
        self.below_since[p] = np.nan
        self.armed[p] = False
        self._set_freq(p, self.nominal_hz[p])
        self.t_refined[p] = t
        self.v_pitch[v] = p
        self.v_midi[v] = self.cfg.pitch_lo + p
        self.v_t_on[v] = t
        f = self.nominal_hz[p]
        if self.p.refine and mag is not None:
            fr, _ = self.refiner.refine(mag, f, None, self._others_h(p))
            if fr is not None:
                f = fr
                self._set_freq(p, fr)
        self.v_freq[v] = f
        self.v_amp[v] = self._amps(mag, [f])[0]
        events.append(NoteEvent("on", t, v, int(self.v_midi[v]), float(f), float(self.v_amp[v])))

    def _provisional(self, q, t, pf):
        """The provisional note that pitch ``q`` corrects, or -1."""
        P = self.p
        best, best_pf = -1, 2.0
        for p in np.flatnonzero(self.active):
            d = abs(int(p) - int(q))
            if t - self.t_on[p] >= P.correct_ms / 1e3 or pf[p] >= P.correct_drop:
                continue
            if (d <= P.correct_span or d in (12, 19, 24)) and pf[p] < best_pf:
                best, best_pf = int(p), float(pf[p])
        return best

    def _move(self, p, q, t, mag, events):
        """Hand the voice of note ``p`` to pitch ``q``. The note keeps its start time (and its window)."""
        v = int(self.voice_of[p])
        t_on = self.t_on[p]
        self.active[p] = False
        self.voice_of[p] = -1
        self.below_since[p] = np.nan
        self.active[q] = True
        self.voice_of[q] = v
        self.t_on[q] = t_on
        self.above_since[q] = np.nan
        self.below_since[q] = np.nan
        self.armed[q] = False
        f = self.nominal_hz[q]
        self._set_freq(q, f)
        self.t_refined[q] = t
        if self.p.refine and mag is not None:
            fr, _ = self.refiner.refine(mag, f, None, self._others_h(q))
            if fr is not None:
                f = fr
                self._set_freq(q, fr)
        prev = int(self.v_midi[v])
        self.v_pitch[v] = q
        self.v_midi[v] = self.cfg.pitch_lo + q
        self.v_freq[v] = f
        self.v_amp[v] = self._amps(mag, [f])[0]
        events.append(NoteEvent("move", t, v, int(self.v_midi[v]), float(f), float(self.v_amp[v]), prev))

    def _stop(self, p, t, events):
        v = int(self.voice_of[p])
        if v < 0:
            return
        events.append(NoteEvent("off", t, v, int(self.cfg.pitch_lo + p), float(self.v_freq[v]), 0.0))
        self.active[p] = False
        self.voice_of[p] = -1
        self.below_since[p] = np.nan
        self.v_pitch[v] = -1
        self.v_amp[v] = 0.0  # frequency stays as the last value for release tails

    def _others_h(self, p):
        """Harmonics of every sounding note except ``p`` (what refinement must not lock onto)."""
        m = self.active.copy()
        m[p] = False
        return self.est_harm[m]

    # ------------------------------------------------------------------ main step
    def step(self, t: float, p_frame: np.ndarray, p_onset: np.ndarray, mag: np.ndarray | None = None,
             rms_db: float = 0.0) -> list[NoteEvent]:
        P = self.p
        events: list[NoteEvent] = []
        if rms_db < P.gate_db:
            p_frame = np.zeros_like(p_frame)
            p_onset = np.zeros_like(p_onset)

        trig = (p_onset >= P.onset_thresh) & self.armed
        self.armed[trig] = False
        self.armed |= p_onset < 0.5 * P.onset_thresh
        retrig_s, on_s, off_s = P.retrigger_ms / 1e3, P.on_confirm_ms / 1e3, P.off_confirm_ms / 1e3

        for p in np.flatnonzero(self.active):
            if p_frame[p] < P.off_thresh:
                if np.isnan(self.below_since[p]):
                    self.below_since[p] = t
                if t - self.below_since[p] >= off_s:
                    self._stop(int(p), t, events)
            else:
                self.below_since[p] = np.nan
                if trig[p] and t - self.t_on[p] >= retrig_s:
                    v = int(self.voice_of[p])
                    self._stop(int(p), t, events)
                    self._start(int(p), t, p_frame, mag, events, voice=v)

        wanted = (p_frame >= P.on_thresh) | (trig & (p_frame >= 0.5 * P.on_thresh))
        cands = np.flatnonzero(~self.active & wanted)
        for p in cands[np.argsort(-p_frame[cands])]:
            fast = trig[p] and p_frame[p] >= 0.5 * P.on_thresh
            if np.isnan(self.above_since[p]):
                self.above_since[p] = t
            if fast or t - self.above_since[p] >= on_s:
                old = self._provisional(p, t, p_frame) if P.correct_ms > 0 else -1
                if old >= 0:
                    self._move(old, int(p), t, mag, events)
                else:
                    self._start(int(p), t, p_frame, mag, events)
        self.above_since[~self.active & ~wanted] = np.nan

        self._track(t, mag)
        return events

    def _track(self, t, mag):
        """Refresh frequency/amplitude of the sounding voices (frequency refinement is throttled to save CPU)."""
        refine_s = self.p.refine_every_ms / 1e3
        act = np.flatnonzero(self.active)
        if not act.size:
            return
        if self.p.refine and mag is not None:
            for p in act[t - self.t_refined[act] >= refine_s]:
                p = int(p)
                self.t_refined[p] = t
                f = self.est_freq[p]
                fr, _ = self.refiner.refine(mag, float(f), None, self._others_h(p))
                if fr is not None and abs(1200.0 * math.log2(fr / f)) < 40.0:  # real pitch moves are smooth
                    a = self.p.glide_alpha
                    self._set_freq(p, (1.0 - a) * f + a * fr)
        vs = self.voice_of[act]
        self.v_freq[vs] = self.est_freq[act]
        self.v_amp[vs] = self._amps(mag, self.est_freq[act])

    def voices(self) -> VoiceState:
        return VoiceState(active=self.v_pitch >= 0, midi=self.v_midi.copy(), freq=self.v_freq.copy(),
                          amp=self.v_amp.copy(), t_on=self.v_t_on.copy())
