import numpy as np

from polytracker.config import FrontendConfig, midi_to_hz
from polytracker.frontend import Frontend, _triangle_filterbank
from conftest import chord


def test_shapes_and_bounds(cfg):
    fe = Frontend(cfg)
    x = chord([110.0])
    f = fe.compute_signal(x, np.array([20000, 30000]))
    assert f.x.shape == (2, cfg.n_channels, cfg.n_fine)
    assert f.x.dtype == np.float32 and np.isfinite(f.x).all()
    assert f.mag_long.shape == (2, fe.n_long // 2 + 1)


def test_sparse_filterbank_equals_dense(cfg):
    fe = Frontend(cfg)
    bps = cfg.bins_per_semitone
    grid_hz = midi_to_hz(cfg.grid_lo + np.arange(cfg.n_grid) / bps)
    dense = _triangle_filterbank(fe.n_long, cfg.sample_rate, grid_hz, 2.0 ** (1.0 / (12 * bps)))
    mag = np.random.default_rng(0).random((3, fe.n_long // 2 + 1)).astype(np.float32)
    np.testing.assert_allclose(fe.fb_long(mag), mag @ dense, rtol=1e-4, atol=1e-5)


def test_harmonic_stack_points_at_fundamental(cfg):
    """A harmonic tone must light up the S_long fundamental channel at its own pitch (+- the FFT resolution)."""
    fe = Frontend(cfg)
    f0 = 440.0  # A4 = MIDI 69
    f = fe.compute_signal(chord([f0], harmonics=6), np.array([24000]))
    stacked = f.x[0, : cfg.n_harmonics].sum(axis=0)  # all harmonic channels
    peak_pitch = cfg.pitch_lo + (int(np.argmax(stacked)) - 1) / cfg.bins_per_semitone
    assert abs(peak_pitch - 69) < 0.7


def test_frames_are_causal(cfg):
    """Changing samples after the frame end must not change the frame."""
    fe = Frontend(cfg)
    rng = np.random.default_rng(1)
    x = (0.1 * rng.standard_normal(30000)).astype(np.float32)
    y = x.copy()
    y[20001:] = 0.9 * rng.standard_normal(len(y) - 20001)
    a = fe.compute_signal(x, np.array([20000])).x
    b = fe.compute_signal(y, np.array([20000])).x
    np.testing.assert_array_equal(a, b)


def test_onset_raises_flux_channel(cfg):
    fe = Frontend(cfg)
    sr = cfg.sample_rate
    x = np.zeros(sr, dtype=np.float32)
    x[20000:] = chord([220.0], seconds=1.0)[: sr - 20000]
    h = cfg.n_harmonics
    flux_on = fe.compute_signal(x, np.array([20000 + 600])).x[0, 2 * h]
    flux_before = fe.compute_signal(x, np.array([19000])).x[0, 2 * h]
    assert flux_on.max() > 0.5 and flux_before.max() <= 0.05


def test_other_sample_rate_scales_windows():
    cfg44 = FrontendConfig().with_rate(44100)
    fe = Frontend(cfg44)
    assert fe.n_long % 16 == 0 and abs(fe.n_long / 44100 - 4096 / 48000) < 0.002
    f = fe.compute_signal(chord([110.0], sr=44100, seconds=1.0), np.array([30000]))
    assert np.isfinite(f.x).all()


def test_silence_is_finite_and_quiet(cfg):
    fe = Frontend(cfg)
    f = fe.compute_signal(np.zeros(20000, dtype=np.float32), np.array([15000]))
    assert np.isfinite(f.x).all()
    assert f.rms_db[0] < -100
