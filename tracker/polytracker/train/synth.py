"""Synthetic electric/acoustic guitar performances with exact note labels.

Additive string model (inharmonic partials, pluck/pickup combs, frequency
dependent decay, beating, pick noise) plus a randomised signal chain
(pickup EQ, optional amp distortion + cabinet, room, hum/hiss, gain).
Strings are monophonic: a new note on a string cuts the previous one, like on
a real guitar. Labels are exported as a 1 kHz piano roll plus onset times.
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
from scipy import signal as sps

from ..config import FrontendConfig

TUNINGS = {
    "standard": [40, 45, 50, 55, 59, 64],
    "drop_d": [38, 45, 50, 55, 59, 64],
    "eb": [39, 44, 49, 54, 58, 63],
    "dadgad": [38, 45, 50, 55, 57, 62],
    "open_g": [38, 43, 50, 55, 59, 62],
}
TUNING_WEIGHTS = {"standard": 0.62, "drop_d": 0.14, "eb": 0.1, "dadgad": 0.07, "open_g": 0.07}

ROLL_RATE = 1000  # labels per second


@dataclass
class NoteEvent:
    string: int
    midi: int  # nominal (fretted) pitch
    onset: float  # seconds
    velocity: float  # 0..1
    length: float  # seconds the player intends to sustain
    legato: bool = False  # hammer-on / pull-off: no pick
    vibrato_cents: float = 0.0
    vibrato_rate: float = 5.5
    bend_semitones: float = 0.0
    bend_time: float = 0.15
    slide_from: float = 0.0  # start offset in semitones
    muted: bool = False  # dead note: noise only
    palm_mute: bool = False


@dataclass
class Excerpt:
    audio: np.ndarray  # float32 mono
    roll: np.ndarray  # [ms, n_pitch] uint8
    onsets: list  # [(time_s, pitch_index)]
    sample_rate: int


# ------------------------------------------------------------------ note rendering


def _render_note(rng, sr, note: NoteEvent, total: float, tau1: float, damp_at: float | None):
    """Render one plucked string. Returns (samples, pitch_track_midi at ROLL_RATE for [onset, onset+len))."""
    n = int(total * sr)
    t = np.arange(n, dtype=np.float32) / sr
    base = float(note.midi)

    # pitch offset in semitones over time
    off = np.zeros(n, dtype=np.float32)
    if note.bend_semitones:
        ramp = np.clip((t - 0.03) / note.bend_time, 0.0, 1.0)
        off += note.bend_semitones * (0.5 - 0.5 * np.cos(np.pi * ramp))
    if note.slide_from:
        ramp = np.clip(t / 0.12, 0.0, 1.0)
        off += note.slide_from * (1.0 - ramp)
    if note.vibrato_cents:
        fade = np.clip((t - 0.15) / 0.2, 0.0, 1.0)
        off += (note.vibrato_cents / 100.0) * fade * np.sin(2 * np.pi * note.vibrato_rate * t + rng.uniform(0, 6.28))
    midi_t = base + off
    f0 = 440.0 * np.power(2.0, (midi_t - 69.0) / 12.0)
    phase0 = np.cumsum(2 * np.pi * f0 / sr).astype(np.float64)

    f_max = float(f0.max())
    n_part = int(min(48, np.floor(0.45 * sr / f_max)))
    h = np.arange(1, n_part + 1, dtype=np.float32)
    inharm = rng.uniform(0.0, 3e-4)
    ratio = h * np.sqrt(1.0 + inharm * h * h)

    slope = rng.uniform(0.6, 1.8)
    beta = rng.uniform(0.08, 0.5)  # pluck position
    gamma = rng.uniform(0.07, 0.25)  # pickup position
    comb = np.maximum(np.abs(np.sin(np.pi * h * beta)) * np.abs(np.sin(np.pi * h * gamma)), 0.12)
    amp = comb / np.power(h, slope)
    amp *= np.exp(rng.normal(0.0, 0.25, n_part)).astype(np.float32)
    k_dec = rng.uniform(0.01, 0.25)
    if note.palm_mute:
        tau1 = min(tau1, rng.uniform(0.06, 0.2))
    tau = tau1 / (1.0 + k_dec * np.power(h, 1.6))
    phi = rng.uniform(0, 2 * np.pi, n_part)
    beat_hz = rng.uniform(0.1, 2.5, n_part)
    beat_depth = rng.uniform(0.0, 0.45, n_part) * (rng.random() < 0.7)
    beat_phi = rng.uniform(0, 2 * np.pi, n_part)

    out = np.zeros(n, dtype=np.float32)
    attack = 1.0 - np.exp(-t / rng.uniform(0.0006, 0.004 if not note.legato else 0.012))
    for i0 in range(0, n_part, 16):
        sl = slice(i0, min(n_part, i0 + 16))
        ph = ratio[sl, None] * phase0[None, :] + phi[sl, None]
        env = np.exp(-t[None, :] / tau[sl, None])
        beat = 1.0 + beat_depth[sl, None] * np.cos(2 * np.pi * beat_hz[sl, None] * t[None, :] + beat_phi[sl, None])
        out += (amp[sl, None] * env * beat * np.sin(ph).astype(np.float32)).sum(axis=0)
    out *= attack

    if damp_at is not None and damp_at < total:
        td = rng.uniform(0.008, 0.04)
        k = int(damp_at * sr)
        out[k:] *= np.exp(-(t[k:] - damp_at) / td)

    if not note.legato:
        m = int(0.012 * sr)
        noise = rng.standard_normal(m).astype(np.float32) * np.exp(-np.arange(m) / (sr * rng.uniform(0.001, 0.004)))
        sos = sps.butter(2, rng.uniform(1500, 7000), btype="low", fs=sr, output="sos")
        out[:m] += sps.sosfilt(sos, noise).astype(np.float32) * rng.uniform(0.0, 0.25) * np.abs(out[: 4 * m]).max()

    peak = np.abs(out).max() + 1e-9
    out *= note.velocity / peak
    if note.muted:  # dead note: a short band-limited thud without pitch
        thud = rng.standard_normal(n).astype(np.float32) * np.exp(-t / 0.03)
        out = sps.sosfilt(sps.butter(2, [200, 2500], btype="band", fs=sr, output="sos"), thud).astype(np.float32)
        out *= note.velocity * 0.5 / (np.abs(out).max() + 1e-9)
    return out, midi_t


# ------------------------------------------------------------------ performance generator


def _chord_frets(rng, tuning):
    """Random playable fretting: returns fret or None for every string."""
    base = int(rng.integers(0, 13))
    span = int(rng.integers(0, 4))
    frets = []
    for s in range(6):
        r = rng.random()
        if r < 0.12:
            frets.append(None)
        elif r < 0.3 and base > 0:
            frets.append(0)
        else:
            frets.append(base + int(rng.integers(0, span + 1)))
    if sum(f is not None for f in frets) < 2:
        frets[int(rng.integers(0, 6))] = base
        frets[int(rng.integers(0, 6))] = base + 2
    return frets


def _schedule(rng, duration: float, tuning):
    notes: list[NoteEvent] = []
    t = rng.uniform(0.05, 0.6)
    style = rng.choice(["line", "strum", "arp", "mix", "power"], p=[0.3, 0.25, 0.15, 0.2, 0.1])
    string = int(rng.integers(0, 6))
    fret = int(rng.integers(0, 15))
    while t < duration - 0.15:
        kind = style if style != "mix" else rng.choice(["line", "strum", "arp", "power"])
        vel = float(np.exp(rng.uniform(np.log(0.08), 0.0)))
        if kind == "line":
            iv = rng.choice([0.1, 0.15, 0.2, 0.3, 0.45, 0.6]) * rng.uniform(0.85, 1.2)
            if rng.random() < 0.3:
                string = int(np.clip(string + rng.integers(-1, 2), 0, 5))
            step = int(rng.choice([-4, -3, -2, -1, 0, 1, 2, 3, 4, 5, 7]))
            fret = int(np.clip(fret + step, 0, 22))
            if rng.random() < 0.15:  # repeated pitch
                fret = fret
            legato = rng.random() < 0.18
            note = NoteEvent(string, tuning[string] + fret, t, vel, iv * rng.uniform(0.7, 1.6), legato=legato)
            if not legato:
                if rng.random() < 0.18:
                    note.vibrato_cents = rng.uniform(8, 40)
                    note.vibrato_rate = rng.uniform(4.0, 7.0)
                if rng.random() < 0.08:
                    note.bend_semitones = float(rng.choice([0.5, 1.0, 1.0, 2.0]))
                    note.bend_time = rng.uniform(0.08, 0.3)
                if rng.random() < 0.06:
                    note.slide_from = float(rng.choice([-4, -2, -1, 2, 3]))
                note.palm_mute = rng.random() < 0.12
            notes.append(note)
            t += iv
        elif kind in ("strum", "power"):
            frets = _chord_frets(rng, tuning)
            if kind == "power":
                s0 = int(rng.integers(0, 3))
                base = int(rng.integers(0, 12))
                frets = [None] * 6
                frets[s0] = base
                frets[s0 + 1] = base + 2
                if rng.random() < 0.7:
                    frets[s0 + 2] = base + 2
            order = list(range(6)) if rng.random() < 0.5 else list(range(5, -1, -1))
            gap = rng.uniform(0.003, 0.025)
            sus = rng.choice([0.25, 0.5, 0.9, 1.6]) * rng.uniform(0.8, 1.3)
            pm = rng.random() < 0.15
            for k, s in enumerate(order):
                if frets[s] is None:
                    continue
                v = vel * rng.uniform(0.6, 1.0)
                notes.append(NoteEvent(s, tuning[s] + frets[s], t + k * gap + rng.normal(0, 0.0015), v, sus, palm_mute=pm))
            if rng.random() < 0.1:
                s = int(rng.integers(0, 6))
                notes.append(NoteEvent(s, tuning[s], t + rng.uniform(0, 0.05), vel * 0.15, 0.1, muted=True))
            t += sus * rng.uniform(0.7, 1.0) + rng.uniform(0.0, 0.3)
        else:  # arpeggio
            frets = _chord_frets(rng, tuning)
            strings = [s for s in range(6) if frets[s] is not None]
            if rng.random() < 0.5:
                strings = strings[::-1]
            gap = rng.uniform(0.07, 0.28)
            ring = rng.uniform(0.8, 2.5)
            for k, s in enumerate(strings):
                notes.append(NoteEvent(s, tuning[s] + frets[s], t + k * gap, vel * rng.uniform(0.7, 1.0), ring))
            t += gap * len(strings) + rng.uniform(0.0, 0.4)
        if rng.random() < 0.08:
            t += rng.uniform(0.4, 1.5)  # pause
    return notes


def apply_fx(rng, x: np.ndarray, sr: int, p_amp: float = 0.4, p_room: float = 0.3) -> np.ndarray:
    """Randomised pickup EQ, optional amp + cabinet, room, noise and gain. Also used to augment real recordings."""
    x = x.astype(np.float32)
    silent = np.abs(x).max() < 1e-6
    x = x / (np.abs(x).max() + 1e-9)

    # pickup / body colouration
    sos = [sps.butter(2, rng.uniform(55, 110), btype="high", fs=sr, output="sos")]
    sos.append(sps.butter(rng.integers(1, 3), rng.uniform(2500, 12000), btype="low", fs=sr, output="sos"))
    if rng.random() < 0.7:
        f, q, g = rng.uniform(700, 4000), rng.uniform(0.8, 3.0), rng.uniform(-4, 9)
        a = 10 ** (g / 40)
        w0 = 2 * np.pi * f / sr
        al = np.sin(w0) / (2 * q)
        b = np.array([1 + al * a, -2 * np.cos(w0), 1 - al * a])
        aa = np.array([1 + al / a, -2 * np.cos(w0), 1 - al / a])
        sos.append(sps.tf2sos(b / aa[0], aa / aa[0]))
    x = sps.sosfilt(np.vstack(sos), x).astype(np.float32)
    x /= np.abs(x).max() + 1e-9

    if rng.random() < p_amp:  # amp
        drive = float(np.exp(rng.uniform(np.log(1.5), np.log(40.0))))
        bias = rng.uniform(0.0, 0.3) if rng.random() < 0.5 else 0.0
        x = np.tanh(drive * x + bias) - np.tanh(bias)
        cab = [sps.butter(4, rng.uniform(3000, 6500), btype="low", fs=sr, output="sos"),
               sps.butter(2, rng.uniform(70, 130), btype="high", fs=sr, output="sos")]
        x = sps.sosfilt(np.vstack(cab), x).astype(np.float32)
        x /= np.abs(x).max() + 1e-9

    if rng.random() < p_room:  # room / reverb
        rt = rng.uniform(0.08, 0.7)
        n_ir = int(rt * sr)
        ir = rng.standard_normal(n_ir) * np.exp(-6.9 * np.arange(n_ir) / n_ir)
        ir[0] = 0.0
        wet = rng.uniform(0.05, 0.4)
        x = (x + wet * sps.fftconvolve(x, ir / np.sqrt((ir ** 2).sum()), mode="full")[: len(x)] * 0.5).astype(np.float32)

    n = len(x)
    t = np.arange(n, dtype=np.float32) / sr
    hiss = 10 ** (rng.uniform(-78, -48) / 20)
    x += hiss * rng.standard_normal(n).astype(np.float32)
    if rng.random() < 0.4:
        hum_f = rng.choice([50.0, 60.0])
        hum = sum(rng.uniform(0.2, 1.0) / k * np.sin(2 * np.pi * hum_f * k * t + rng.uniform(0, 6.28)) for k in range(1, 5))
        x += (10 ** (rng.uniform(-72, -45) / 20) * hum).astype(np.float32)

    if not silent:
        level_db = rng.uniform(-38.0, -3.0)
        x *= (10 ** (level_db / 20)) / (np.abs(x).max() + 1e-9)
    return x.astype(np.float32)


def render_excerpt(rng: np.random.Generator, cfg: FrontendConfig, duration: float = 6.0) -> Excerpt:
    sr = cfg.sample_rate
    name = rng.choice(list(TUNINGS), p=[TUNING_WEIGHTS[k] for k in TUNINGS])
    tuning = TUNINGS[str(name)]
    if rng.random() < 0.04:  # noise-only excerpt: teaches silence rejection
        notes: list[NoteEvent] = []
    else:
        notes = _schedule(rng, duration, tuning)
    notes = [n for n in notes if cfg.pitch_lo - 4 <= n.midi <= cfg.pitch_hi + 4]
    notes.sort(key=lambda n: n.onset)

    n_total = int(duration * sr)
    mix = np.zeros(n_total + sr, dtype=np.float32)
    roll = np.zeros((int(duration * ROLL_RATE) + 1, cfg.n_pitch), dtype=np.uint8)
    onsets = []

    by_string: dict[int, list[NoteEvent]] = {}
    for n in notes:
        by_string.setdefault(n.string, []).append(n)

    for s, lst in by_string.items():
        lst.sort(key=lambda n: n.onset)
        for i, n in enumerate(lst):
            next_on = lst[i + 1].onset if i + 1 < len(lst) else None
            tau1 = float(np.exp(rng.uniform(np.log(0.5), np.log(5.0))))
            natural_end = n.onset + min(tau1 * 4.6, 8.0)  # fundamental about 40 dB down
            damp_at = n.length if (rng.random() < 0.75 or n.palm_mute or n.muted) else None
            if next_on is not None and (damp_at is None or n.onset + damp_at > next_on):
                damp_at = max(0.01, next_on - n.onset)
            end = min(natural_end, duration)
            if damp_at is not None:
                end = min(end, n.onset + damp_at + 0.04)
            if next_on is not None:
                end = min(end, next_on + 0.004)
            total = min(end - n.onset + 0.15, duration - n.onset)
            if total <= 0.03:
                continue
            audio, midi_t = _render_note(rng, sr, n, total, tau1, damp_at)
            # string cut by the next note on the same string
            if next_on is not None:
                cut = int((next_on - n.onset) * sr)
                if cut < len(audio):
                    fade = min(int(0.004 * sr), len(audio) - cut)
                    audio[cut:cut + fade] *= np.linspace(1, 0, fade, dtype=np.float32)
                    audio[cut + fade:] = 0.0
            i0 = int(n.onset * sr)
            seg = audio[: max(0, n_total - i0)]
            mix[i0:i0 + len(seg)] += seg
            if n.muted:
                continue
            ms0, ms1 = int(n.onset * ROLL_RATE), int(end * ROLL_RATE)
            idx = np.arange(ms0, min(ms1, roll.shape[0]))
            pitch = np.rint(midi_t[np.minimum((idx / ROLL_RATE - n.onset) * sr, len(midi_t) - 1).astype(int)]).astype(int)
            ok = (pitch >= cfg.pitch_lo) & (pitch <= cfg.pitch_hi)
            roll[idx[ok], pitch[ok] - cfg.pitch_lo] = 1
            p0 = int(np.rint(midi_t[0]))
            if cfg.pitch_lo <= p0 <= cfg.pitch_hi:
                onsets.append((n.onset, p0 - cfg.pitch_lo))

    audio = apply_fx(rng, mix[:n_total], sr)
    return Excerpt(audio=audio, roll=roll, onsets=onsets, sample_rate=sr)
