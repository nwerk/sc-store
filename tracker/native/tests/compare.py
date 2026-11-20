"""Checks the native tracker against the Python one, frame by frame.

Both run the realtime path (one frame per hop, the flux spectrum reused from the frame ``delta`` samples
back) on the same audio; compared are the network input, the network output, every note event and the voice
frequencies and amplitudes. Run from tracker/ after ``make -C native``:

    .venv/bin/python native/tests/compare.py            # all cases
    .venv/bin/python native/tests/compare.py -v         # also print the event lists

Exit status 0 if everything matches within the tolerances below.
"""
from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
TRACKER = HERE.parent.parent
sys.path.insert(0, str(TRACKER))

from polytracker.config import midi_to_hz  # noqa: E402
from polytracker.decoder import DecoderParams  # noqa: E402
from polytracker.engine import Tracker  # noqa: E402
from polytracker.net import PitchNetNP  # noqa: E402

BINARY = HERE.parent / "build" / "polytracker"

# float32 FFTs of different libraries differ in the last bits, so the features differ by ~1e-6 and the
# probabilities by about as much. A note decision can still flip when a probability sits within that distance
# of a threshold; events are therefore compared exactly, and a mismatch is reported with the probabilities
# that caused it.
# The largest feature differences sit in the spectral-change channel of near-silent frames (hiss at -80 dB), where
# float32 rounding is large relative to the signal; measured: 5.5e-5 at 48 kHz, 1.6e-4 at 44.1 kHz (Bluestein FFT),
# with network outputs within 6e-6.
TOL_FEATURES = 5e-4
TOL_PROBS = 1e-4
TOL_FREQ_CENTS = 0.05
TOL_AMP = 1e-4


def pluck(f0, seconds, sr, start=0.0, amp=0.15, decay=1.5, bend_cents=0.0, vibrato_cents=0.0):
    """A plucked string: 10 decaying harmonics, optional bend (linear over the note) and vibrato (5.5 Hz)."""
    t = np.arange(int(seconds * sr)) / sr
    cents = bend_cents * t / max(seconds, 1e-9) + vibrato_cents * np.sin(2 * np.pi * 5.5 * t)
    phase = 2 * np.pi * np.cumsum(f0 * 2.0 ** (cents / 1200.0)) / sr
    x = np.zeros_like(t)
    for h in range(1, 11):
        x += amp / h * np.sin(h * phase * np.sqrt(1 + 8e-5 * h * h)) * np.exp(-decay * h ** 0.5 * t)
    s0 = int(start * sr)
    out = np.zeros(s0 + len(x))
    out[s0:] = x
    return out


def mix(parts, sr):
    n = max(len(p) for p in parts)
    y = np.zeros(n)
    for p in parts:
        y[:len(p)] += p
    return y


def performance(sr, seed=1):
    """Single notes, chords, a bend, vibrato, a repeated note, silence and a noise burst."""
    rng = np.random.default_rng(seed)
    m = lambda n: float(midi_to_hz(n))
    parts = [
        pluck(m(40), 1.0, sr, 0.1),                                            # low E
        pluck(m(64), 0.6, sr, 0.5, amp=0.1),
        *[pluck(m(n), 1.2, sr, 1.3, amp=0.08) for n in (45, 52, 57, 61, 64)],  # A major chord
        pluck(m(67), 1.0, sr, 2.8, bend_cents=150.0),                         # bend
        pluck(m(71), 1.2, sr, 3.9, vibrato_cents=25.0),                       # vibrato
        *[pluck(m(55), 0.25, sr, 5.2 + 0.3 * i) for i in range(4)],           # repeated note
        *[pluck(m(n), 1.0, sr, 6.8, amp=0.07) for n in (40, 47, 52, 56, 59, 64)],  # six strings (E major)
    ]
    y = mix(parts, sr)
    y = np.concatenate([y, np.zeros(int(0.5 * sr))])
    burst = slice(int(7.9 * sr), int(8.1 * sr))
    y[burst] += 0.05 * rng.standard_normal(burst.stop - burst.start)
    y += 1e-4 * rng.standard_normal(len(y))                                   # pickup hiss
    return y.astype(np.float32)


def run_python(x, sr, hop, params):
    tr = Tracker(PitchNetNP.load(TRACKER / "models" / "guitar_v1.npz"), params=params, sample_rate=sr, hop=hop)
    cfg, fe, dec = tr.cfg, tr.fe, tr.dec
    padded = fe.pad(x)
    cache = {}
    feats, probs, voices, events = [], [], [], []
    for end in range(hop, len(x) + 1, hop):
        hist = padded[end:end + cfg.history]
        f = fe.compute(hist[None, :], cache.pop(end - cfg.delta_samples, None))
        cache[end] = f.db_short
        pr = tr.model.predict_one(f.x[0]).copy()
        ev = dec.step(end / sr, pr[0], pr[1], f.mag_long[0], float(f.rms_db[0]))
        feats.append(f.x[0].copy())
        probs.append(pr)
        voices.append(np.stack([dec.v_freq, dec.v_amp], axis=1).copy())
        events += [(e.kind, e.t, e.voice, e.pitch, e.freq, e.amp) for e in ev]
    return np.array(feats), np.array(probs), np.array(voices), events


def run_native(x, sr, hop, params, tmp):
    wav, fp, pp, vp = (tmp / n for n in ("in.f32", "feat.f32", "probs.f32", "voices.f64"))
    x.astype("<f4").tofile(wav)
    cmd = [str(BINARY), "frames", str(wav), "--sample-rate", str(sr), "--hop", str(hop), "--features", str(fp),
           "--probs", str(pp), "--voices-out", str(vp), "--voices", str(params.max_voices),
           "--on", repr(params.on_thresh), "--off", repr(params.off_thresh), "--onset", repr(params.onset_thresh),
           "--confirm-ms", repr(params.on_confirm_ms), "--correct-ms", repr(params.correct_ms),
           "--correct-span", str(params.correct_span), "--correct-drop", repr(params.correct_drop)]
    if not params.refine:
        cmd.append("--no-refine")
    out = subprocess.run(cmd, check=True, capture_output=True, text=True).stdout
    events = []
    for line in out.splitlines():
        k, t, v, p, f, a = line.split()
        events.append((k, float(t), int(v), int(p), float(f), float(a)))
    return np.fromfile(fp, "<f4"), np.fromfile(pp, "<f4"), np.fromfile(vp, "<f8"), events


def compare(name, x, sr=48000, hop=256, params=None, verbose=False):
    params = params or DecoderParams()
    with tempfile.TemporaryDirectory() as d:
        pf, pp, pv, pe = run_python(x, sr, hop, params)
        nf, npr, nv, ne = run_native(x, sr, hop, params, Path(d))
    nf, npr, nv = nf.reshape(pf.shape), npr.reshape(pp.shape), nv.reshape(pv.shape)
    ok = True
    df, dp = np.abs(nf - pf).max(), np.abs(npr - pp).max()
    problems = []
    if df > TOL_FEATURES:
        problems.append(f"features differ by {df:.2e} (channel/bin {np.unravel_index(np.abs(nf - pf).argmax(), pf.shape)})")
    if dp > TOL_PROBS:
        problems.append(f"probabilities differ by {dp:.2e}")
    same_decisions = [(e[0], round(e[1], 6), e[2], e[3]) for e in pe] == [(e[0], round(e[1], 6), e[2], e[3]) for e in ne]
    if not same_decisions:
        problems.append(f"events differ: python {len(pe)}, native {len(ne)}")
        for i, (a, b) in enumerate(zip(pe, ne)):
            if (a[0], round(a[1], 6), a[2], a[3]) != (b[0], round(b[1], 6), b[2], b[3]):
                fr = int(round(a[1] * sr / hop)) - 1
                problems.append(f"  first difference at event {i}: python {a[:4]}, native {b[:4]} "
                                f"(frame {fr}, frame probs of pitch {a[3] - 38}: py {pp[fr, 0, a[3] - 38]:.7f} "
                                f"native {npr[fr, 0, a[3] - 38]:.7f})")
                break
    else:
        fe = [abs(1200 * np.log2(b[4] / a[4])) for a, b in zip(pe, ne) if a[4] > 0 and b[4] > 0]
        ae = [abs(b[5] - a[5]) for a, b in zip(pe, ne)]
        if fe and max(fe) > TOL_FREQ_CENTS:
            problems.append(f"event frequencies differ by up to {max(fe):.3f} cents")
        if ae and max(ae) > TOL_AMP:
            problems.append(f"event amplitudes differ by up to {max(ae):.2e}")
        both = (pv[..., 0] > 0) & (nv[..., 0] > 0)
        vf = np.abs(1200 * np.log2(nv[..., 0][both] / pv[..., 0][both])).max() if both.any() else 0.0
        va = np.abs(nv[..., 1] - pv[..., 1]).max()
        if vf > TOL_FREQ_CENTS:
            problems.append(f"voice frequencies differ by up to {vf:.3f} cents")
        if va > TOL_AMP:
            problems.append(f"voice amplitudes differ by up to {va:.2e}")
    ok = not problems
    n_on = sum(e[0] == "on" for e in pe)
    n_mv = sum(e[0] == "move" for e in pe)
    print(f"{'ok  ' if ok else 'FAIL'} {name:34s} frames {len(pf):5d}  notes {n_on:3d}  moves {n_mv:3d}  "
          f"max diff: features {df:.1e}  probs {dp:.1e}")
    for p in problems:
        print("     " + p)
    if verbose:
        for a, b in zip(pe, ne):
            print(f"     py {a[0]:4s} {a[1]:8.4f} v{a[2]} {a[3]} {a[4]:8.3f} {a[5]:.3f} | "
                  f"nat {b[0]:4s} {b[1]:8.4f} v{b[2]} {b[3]} {b[4]:8.3f} {b[5]:.3f}")
    return ok


def main():
    if not BINARY.exists():
        sys.exit(f"{BINARY} not found: build it first with  make -C native")
    verbose = "-v" in sys.argv
    sr = 48000
    x = performance(sr)
    results = [
        compare("performance, hop 256", x, verbose=verbose),
        compare("performance, hop 512", x, hop=512, verbose=verbose),
        compare("performance, 4 voices", x, params=DecoderParams(max_voices=4), verbose=verbose),
        compare("performance, no refine", x, params=DecoderParams(refine=False), verbose=verbose),
        compare("performance, 44.1 kHz", performance(44100, seed=2), sr=44100, hop=236, verbose=verbose),
        compare("silence", np.zeros(sr, dtype=np.float32), verbose=verbose),
        compare("performance, correction", x, params=DecoderParams(correct_ms=60.0), verbose=verbose),
        compare("performance, old thresholds", x, params=DecoderParams(on_thresh=0.7, onset_thresh=0.65,
                                                                       on_confirm_ms=8.0), verbose=verbose),
    ]
    gs = TRACKER / "data" / "guitarset" / "audio_mono-pickup_mix" / "05_Funk2-108-Eb_comp_mix.wav"
    if gs.exists():  # real playing: corrections actually happen here
        import soundfile as sf
        from scipy.signal import resample_poly
        y, gsr = sf.read(str(gs), dtype="float32")
        y = resample_poly(y[: 20 * gsr], 160, 147).astype(np.float32) if gsr == 44100 else y[: 20 * gsr]
        results.append(compare("GuitarSet 20 s, correction", y, params=DecoderParams(correct_ms=60.0),
                               verbose=verbose))
    print("all match" if all(results) else "MISMATCH")
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
