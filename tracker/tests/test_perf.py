"""CPU-saving paths must not change results; the automatic hop choice and the BLAS check."""
import numpy as np
import pytest

from polytracker import perf
from polytracker.config import midi_to_hz
from polytracker.engine import Tracker
from polytracker.frontend import Frontend
from polytracker.refine import PitchRefiner
from conftest import chord


@pytest.fixture(scope="module")
def tracker():
    return Tracker.load()


def test_cached_flux_spectrum_is_exact(tracker):
    """Reusing the short spectrum of the frame ``delta`` samples back gives the same network input, also
    after skipped frames (the realtime loop jumps ahead when it falls behind)."""
    cfg, fe = tracker.cfg, tracker.fe
    x = chord([110.0, 220.0, 329.6], seconds=0.6, decay=2.0)
    x[len(x) // 2:] += chord([146.8], seconds=0.3)  # a new note half way
    padded = fe.pad(x)
    tracker._db_short.clear()
    ends = [k * cfg.hop for k in range(1, len(x) // cfg.hop)]
    ends = ends[:40] + ends[47:]  # a gap of several frames
    cache = {}
    for end in ends:
        hist = padded[end:end + cfg.history]
        ref = fe.compute(hist[None, :])
        got = fe.compute(hist[None, :], cache.pop(end - cfg.delta_samples, None))
        cache[end] = got.db_short
        np.testing.assert_array_equal(got.x, ref.x)


def test_process_cache_stays_small(tracker):
    cfg = tracker.cfg
    x = chord([196.0], seconds=1.0)
    padded = tracker.fe.pad(x)
    tracker._db_short.clear()
    for k in list(range(1, 30)) + list(range(60, 120, 3)):  # consecutive, then every third frame
        end = k * cfg.hop
        tracker.process(padded[end:end + cfg.history], end / cfg.sample_rate)
    assert len(tracker._db_short) <= 2 * (cfg.delta_samples // cfg.hop) + 2
    tracker.dec.reset()
    tracker._db_short.clear()


def test_band_levels_matches_scalar(cfg):
    r = PitchRefiner(cfg, cfg.scaled(cfg.long_win))
    mag = np.abs(np.random.default_rng(3).standard_normal(cfg.scaled(cfg.long_win) // 2 + 1)).astype(np.float32)
    f0s = np.r_[midi_to_hz(np.arange(38, 89)), 9000.0, 23000.0]  # incl. harmonics beyond the spectrum
    np.testing.assert_allclose(r.band_levels(mag, f0s), [r.band_level(mag, f) for f in f0s], rtol=1e-12)
    assert r.band_levels(mag, []).shape == (0,)


def test_refine_precomputed_collisions_match(cfg):
    fe = Frontend(cfg)
    mag = fe.compute(fe.frames_from_signal(chord([110.0, 164.8, 220.0], 0.5), np.array([24000 - 1]))).mag_long[0]
    r = PitchRefiner(cfg, fe.n_long)
    others = [164.8, 220.0]
    assert r.refine(mag, 110.0, others) == r.refine(mag, 110.0, None, r.collision_harmonics(others))
    assert r.refine(mag, 110.0, []) == r.refine(mag, 110.0, None, np.empty((0, 10)))


def _fake_measure(per_hop_ms):
    def m(tracker, seconds=1.0, warmup=20):
        return np.full(100, per_hop_ms[tracker.cfg.hop])
    return m


@pytest.mark.parametrize("cost, expect", [({256: 1.0, 512: 1.0}, 256),  # 19% of 5.3 ms
                                          ({256: 3.0, 512: 3.2}, 512),  # 56% of 5.3 ms, 30% of 10.7 ms
                                          ({256: 9.0, 512: 9.0}, 512)])  # nothing fits: largest hop + warning
def test_choose_hop(monkeypatch, cost, expect):
    model = Tracker.load().model
    monkeypatch.setattr(perf, "measure", _fake_measure(cost))
    logs = []
    tr = perf.choose_hop(lambda hop: Tracker(model, hop=hop), log=logs.append)
    assert tr.cfg.hop == expect
    assert any("warning" in l for l in logs) == (expect == 512 and cost[512] > 0.45 * 10.67)


def test_measure_runs_real_tracker(tracker):
    ms = perf.measure(tracker, seconds=0.3, warmup=5)
    assert ms.size > 20 and np.all(ms > 0)
    assert not tracker.dec.voices().active.any()  # left clean for the live loop


def test_blas_warning(monkeypatch):
    monkeypatch.setattr(perf, "blas_libraries", lambda: ["/usr/lib/aarch64-linux-gnu/blas/libblas.so.3.11.0"])
    assert "libopenblas0" in perf.blas_warning()
    monkeypatch.setattr(perf, "blas_libraries",
                        lambda: ["/usr/lib/aarch64-linux-gnu/openblas-pthread/libblas.so.3"])
    assert perf.blas_warning() is None
    monkeypatch.setattr(perf, "blas_libraries", lambda: [])  # unknown (not Linux, static build): stay quiet
    assert perf.blas_warning() is None
