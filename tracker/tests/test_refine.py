import time

import numpy as np
import pytest

from polytracker.config import FrontendConfig, midi_to_hz
from polytracker.frontend import Frontend
from polytracker.refine import PitchRefiner
from conftest import chord


def _spectrum(freqs, cfg, amp=0.05, seconds=1.0, end=30000):
    fe = Frontend(cfg)
    x = chord(freqs, amp=amp, seconds=seconds)
    return fe, fe.compute_signal(x, np.array([end])).mag_long[0]


@pytest.mark.parametrize("midi,cents", [(40, 0), (40, -31), (45, 17), (52, 40), (59, -25), (64, 12), (76, 33)])
def test_single_note_detune(cfg, midi, cents):
    f_true = midi_to_hz(midi) * 2 ** (cents / 1200)
    fe, mag = _spectrum([f_true], cfg)
    r = PitchRefiner(cfg, fe.n_long)
    f, level = r.refine(mag, float(midi_to_hz(midi)), [])
    assert f is not None
    assert abs(1200 * np.log2(f / f_true)) < 6.0


def test_chord_members_do_not_disturb_each_other(cfg):
    """E2 + B2 + E3 share harmonics: an estimate is either withheld or accurate, never pulled off by the others."""
    notes = {40: 14, 47: -9, 52: 21}
    freqs = {m: midi_to_hz(m) * 2 ** (c / 1200) for m, c in notes.items()}
    fe, mag = _spectrum(list(freqs.values()), cfg)
    r = PitchRefiner(cfg, fe.n_long)
    for m, f_true in freqs.items():
        others = [f for k, f in freqs.items() if k != m]
        f, _ = r.refine(mag, float(midi_to_hz(m)), others)
        if f is not None:
            assert abs(1200 * np.log2(f / f_true)) < 12.0, (m, 1200 * np.log2(f / f_true))


def test_octave_dyad_is_measured(cfg):
    """A and the A+13 semitones above overlap little: both fundamentals get measured."""
    notes = {45: 10, 58: -20}
    freqs = {m: midi_to_hz(m) * 2 ** (c / 1200) for m, c in notes.items()}
    fe, mag = _spectrum(list(freqs.values()), cfg)
    r = PitchRefiner(cfg, fe.n_long)
    for m, f_true in freqs.items():
        f, _ = r.refine(mag, float(midi_to_hz(m)), [x for k, x in freqs.items() if k != m])
        assert f is not None and abs(1200 * np.log2(f / f_true)) < 6.0


def test_returns_none_without_signal(cfg):
    fe = Frontend(cfg)
    mag = fe.compute_signal(np.zeros(30000, dtype=np.float32), np.array([29000])).mag_long[0]
    assert PitchRefiner(cfg, fe.n_long).refine(mag, 110.0, []) == (None, 0.0)


def test_cost_per_call(cfg):
    fe, mag = _spectrum([110.0, 220.0, 330.0], cfg)
    r = PitchRefiner(cfg, fe.n_long)
    t0 = time.perf_counter()
    for _ in range(200):
        r.refine(mag, 110.0, [220.0, 330.0])
    assert (time.perf_counter() - t0) / 200 < 2e-3
