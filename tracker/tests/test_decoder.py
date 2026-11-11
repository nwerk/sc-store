import numpy as np
import pytest

from polytracker.config import FrontendConfig, midi_to_hz
from polytracker.decoder import Decoder, DecoderParams
from polytracker.frontend import Frontend
from conftest import chord

HOP_S = 256 / 48000


def make(cfg, **kw):
    p = DecoderParams(refine=False, **kw)
    return Decoder(cfg, p)


def drive(dec, cfg, frames, start=0.0):
    """frames: list of (frame_probs dict {pitch_idx: p}, onset dict)."""
    events = []
    for i, (pf, po) in enumerate(frames):
        f = np.zeros(cfg.n_pitch)
        o = np.zeros(cfg.n_pitch)
        for k, v in pf.items():
            f[k] = v
        for k, v in po.items():
            o[k] = v
        events += dec.step(start + i * HOP_S, f, o, None, 0.0)
    return events


def test_note_on_off_with_hysteresis(cfg):
    dec = make(cfg)
    frames = [({}, {})] * 3
    frames += [({10: 0.9}, {})] * 10
    frames += [({10: 0.5}, {})] * 20      # between off and on threshold: must keep sounding
    frames += [({10: 0.05}, {})] * 20
    ev = drive(dec, cfg, frames)
    assert [e.kind for e in ev] == ["on", "off"]
    assert ev[0].pitch == cfg.pitch_lo + 10 and ev[0].voice == 0
    assert ev[1].t > ev[0].t + 12 * HOP_S  # off came after the hysteresis plateau + confirm time


def test_on_confirm_delays_start(cfg):
    dec = make(cfg, on_confirm_ms=10.0)
    ev = drive(dec, cfg, [({5: 0.9}, {})] * 10)
    assert ev and ev[0].t - 0.0 >= 0.010 - 1e-9


def test_onset_head_triggers_early_and_retriggers(cfg):
    dec = make(cfg, on_confirm_ms=50.0)
    # frame head only 0.4 (below on_thresh, above half of it) but the onset head fires: start immediately
    ev = drive(dec, cfg, [({7: 0.4}, {7: 0.9})] + [({7: 0.9}, {})] * 40)
    assert ev[0].kind == "on" and ev[0].t == 0.0
    # repeated pick while the string still rings -> off/on pair on the same voice
    frames = [({7: 0.9}, {})] * 30 + [({7: 0.9}, {7: 0.9})] + [({7: 0.9}, {})] * 5
    ev2 = drive(dec, cfg, frames, start=1.0)
    assert [e.kind for e in ev2] == ["off", "on"] and ev2[0].voice == ev2[1].voice


def test_no_retrigger_inside_refractory_time(cfg):
    dec = make(cfg, retrigger_ms=90.0)
    ev = drive(dec, cfg, [({7: 0.9}, {7: 0.9})] + [({7: 0.9}, {})] * 3 + [({7: 0.9}, {7: 0.9})] + [({7: 0.9}, {})] * 3)
    assert [e.kind for e in ev] == ["on"]


def test_polyphony_cap_and_voice_reuse(cfg):
    dec = make(cfg, on_confirm_ms=0.0)
    chord_probs = {k: 0.9 for k in range(8)}
    ev = drive(dec, cfg, [(chord_probs, {})] * 4)
    ons = [e for e in ev if e.kind == "on"]
    assert len(ons) == 6 and sorted(e.voice for e in ons) == list(range(6))
    # release one note, the freed voice is reused by the next
    ev = drive(dec, cfg, [({**{k: 0.9 for k in range(1, 6)}}, {})] * 10, start=1.0)
    assert [e.kind for e in ev] == ["off"]
    freed = ev[0].voice
    ev = drive(dec, cfg, [({**{k: 0.9 for k in range(1, 6)}, 20: 0.9}, {})] * 3, start=2.0)
    assert ev[0].kind == "on" and ev[0].voice == freed


def test_gate_silences(cfg):
    dec = make(cfg, on_confirm_ms=0.0, gate_db=-60.0)
    ev = []
    for i in range(10):
        f = np.zeros(cfg.n_pitch)
        f[3] = 0.95
        ev += dec.step(i * HOP_S, f, np.zeros(cfg.n_pitch), None, -90.0)
    assert ev == []


def test_amplitude_and_frequency_follow_signal(cfg):
    """With real spectra: nominal frequency without refinement, measured detune with refinement."""
    fe = Frontend(cfg)
    f_true = midi_to_hz(57) * 2 ** (23 / 1200)  # A3, 23 cents sharp
    x = chord([f_true], amp=0.05)
    feat = fe.compute_signal(x, np.array([30000]))
    p = DecoderParams(on_confirm_ms=0.0)
    dec = Decoder(cfg, p, n_fft=fe.n_long)
    pf = np.zeros(cfg.n_pitch)
    pf[57 - cfg.pitch_lo] = 0.95
    ev = dec.step(0.0, pf, np.zeros(cfg.n_pitch), feat.mag_long[0], float(feat.rms_db[0]))
    assert ev and ev[0].pitch == 57
    cents = 1200 * np.log2(ev[0].freq / f_true)
    assert abs(cents) < 4.0, cents
    assert 0.3 < ev[0].amp < 1.0
