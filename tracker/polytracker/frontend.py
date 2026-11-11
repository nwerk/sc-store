"""Causal, stateless feature frontend.

One call maps the most recent ``cfg.history`` samples to the network input of a
single frame. The same code runs in training (batches of frames cut from audio
files) and in the realtime tracker (one frame per hop), so there is no
train/serve skew by construction.

Per frame the input has shape ``[channels, n_fine]`` where ``n_fine`` is
``bins_per_semitone`` bins for every candidate pitch. Channels are:

* ``S_long``  harmonic stack of the 85 ms log spectrum   (n_harmonics channels)
* ``S_short`` harmonic stack of the 21 ms log spectrum   (n_harmonics channels)
* ``dS``      harmonic stack of the short-spectrum change over ``delta_lag``
* ``ACF``     normalised autocorrelation at the pitch period and its multiples
* two level channels (long/short window RMS) and a pitch-position channel
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np

from .config import FrontendConfig, harmonic_offsets, midi_to_hz


def asymmetric_window(n: int, peak: float) -> np.ndarray:
    """Smooth window whose maximum sits near the *end*, so new events show up quickly."""
    k = max(2, int(round(peak * n)))
    i = np.arange(n, dtype=np.float64)
    rise = np.sin(0.5 * np.pi * i[:k] / k) ** 2
    fall = np.cos(0.5 * np.pi * (i[k:] - k) / max(1, n - k)) ** 2
    return np.concatenate([rise, fall]).astype(np.float32)


def _triangle_filterbank(n_fft: int, sr: int, centers_hz: np.ndarray, step_ratio: float) -> np.ndarray:
    """Triangular filters on a log grid. Narrower than two FFT bins collapses to linear interpolation."""
    bin_hz = sr / n_fft
    freqs = np.arange(n_fft // 2 + 1, dtype=np.float64) * bin_hz
    c = centers_hz[None, :]
    half_up = np.maximum(c * (step_ratio - 1.0), bin_hz)
    half_dn = np.maximum(c * (1.0 - 1.0 / step_ratio), bin_hz)
    d = freqs[:, None] - c
    w = np.where(d >= 0, 1.0 - d / half_up, 1.0 + d / half_dn)
    return np.clip(w, 0.0, None).astype(np.float32)


class _SparseFilterbank:
    """Banded filterbank applied with gather + reduceat (about 2k non-zeros instead of 550k MACs)."""

    def __init__(self, dense: np.ndarray):
        cols, rows = np.nonzero(dense.T)  # sorted by column
        counts = np.bincount(cols, minlength=dense.shape[1])
        assert counts.min() > 0, "empty filter"
        self.rows = rows
        self.weights = dense[rows, cols].astype(np.float32)
        self.starts = np.concatenate([[0], np.cumsum(counts)[:-1]])

    def __call__(self, mag: np.ndarray) -> np.ndarray:
        return np.add.reduceat(mag[:, self.rows] * self.weights, self.starts, axis=1)


@dataclass
class Features:
    x: np.ndarray  # [B, C, n_fine] network input
    mag_long: np.ndarray  # [B, n_fft_long//2+1] linear magnitude, full-scale sine == 1.0
    rms_db: np.ndarray  # [B] RMS level of the long window in dBFS


class Frontend:
    def __init__(self, cfg: FrontendConfig):
        self.cfg = cfg
        sr = cfg.sample_rate
        self.n_long = cfg.scaled(cfg.long_win)
        self.n_short = cfg.scaled(cfg.short_win)
        self.n_acf = cfg.scaled(cfg.acf_win)
        self.delta = cfg.delta_samples
        self.history = cfg.history

        self.w_long = asymmetric_window(self.n_long, cfg.window_peak)
        self.w_short = asymmetric_window(self.n_short, cfg.window_peak)
        self.w_acf = asymmetric_window(self.n_acf, cfg.window_peak)
        self.norm_long = np.float32(2.0 / self.w_long.sum())
        self.norm_short = np.float32(2.0 / self.w_short.sum())

        bps = cfg.bins_per_semitone
        grid_midi = cfg.grid_lo + np.arange(cfg.n_grid) / bps
        grid_hz = midi_to_hz(grid_midi)
        step = 2.0 ** (1.0 / (12 * bps))
        self.fb_long = _SparseFilterbank(_triangle_filterbank(self.n_long, sr, grid_hz, step))
        self.fb_short = _SparseFilterbank(_triangle_filterbank(self.n_short, sr, grid_hz, step))

        # Fine bin j is centred on MIDI pitch_lo + (j - 1) / bps, i.e. bin 3*i+1 is pitch i.
        j = np.arange(cfg.n_fine)
        base = (cfg.pitch_lo - cfg.grid_lo) * bps - 1
        self.stack_idx = (base + j[None, :] + harmonic_offsets(cfg)[:, None]).astype(np.int64)
        assert self.stack_idx.min() >= 0 and self.stack_idx.max() < cfg.n_grid, "grid too small for stack"

        fine_hz = midi_to_hz(cfg.pitch_lo + (j - 1) / bps)
        lags = np.arange(1, cfg.acf_multiples + 1)[:, None] * (sr / fine_hz)[None, :]
        i0 = np.floor(lags).astype(np.int64)
        frac = (lags - i0).astype(np.float32)
        valid = (i0 + 1) < self.n_acf
        self.acf_i0 = np.where(valid, i0, 0)
        self.acf_w1 = np.where(valid, frac, 0.0).astype(np.float32)
        self.acf_w0 = np.where(valid, 1.0 - frac, 0.0).astype(np.float32)

        self.coord = (j / (cfg.n_fine - 1)).astype(np.float32)

    def compute(self, hist: np.ndarray) -> Features:
        """``hist``: ``[B, history]`` float32, newest sample last."""
        cfg = self.cfg
        hist = np.ascontiguousarray(hist, dtype=np.float32)
        B = hist.shape[0]
        R = cfg.db_range

        long_seg = hist[:, -self.n_long:]
        mag_long = np.abs(np.fft.rfft(long_seg * self.w_long, axis=1)).astype(np.float32) * self.norm_long
        short_now = hist[:, -self.n_short:]
        short_prev = hist[:, -(self.n_short + self.delta):-self.delta]
        mag_s = np.abs(np.fft.rfft(short_now * self.w_short, axis=1)).astype(np.float32) * self.norm_short
        mag_p = np.abs(np.fft.rfft(short_prev * self.w_short, axis=1)).astype(np.float32) * self.norm_short

        db_long = 20.0 * np.log10(self.fb_long(mag_long) + 1e-7)
        db_short = 20.0 * np.log10(self.fb_short(mag_s) + 1e-7)
        db_prev = 20.0 * np.log10(self.fb_short(mag_p) + 1e-7)

        ref_l = np.maximum(db_long.max(axis=1, keepdims=True), cfg.db_floor)
        ref_s = np.maximum(db_short.max(axis=1, keepdims=True), cfg.db_floor)
        s_long = np.clip((db_long - ref_l + R) / R, 0.0, 1.0)
        s_short = np.clip((db_short - ref_s + R) / R, 0.0, 1.0)
        d_spec = np.clip((np.maximum(db_short, -90.0) - np.maximum(db_prev, -90.0)) / 20.0, -1.0, 1.0)

        acf_seg = hist[:, -self.n_acf:] * self.w_acf
        spec = np.fft.rfft(acf_seg, n=2 * self.n_acf, axis=1)
        r = np.fft.irfft(spec.real ** 2 + spec.imag ** 2, n=2 * self.n_acf, axis=1)[:, : self.n_acf + 1]
        r = (r / (r[:, :1] + 1e-9)).astype(np.float32)
        acf = r[:, self.acf_i0] * self.acf_w0 + r[:, self.acf_i0 + 1] * self.acf_w1  # [B, K, n_fine]

        rms_l = np.sqrt(np.mean(long_seg.astype(np.float64) ** 2, axis=1) + 1e-12)
        rms_s = np.sqrt(np.mean(short_now.astype(np.float64) ** 2, axis=1) + 1e-12)
        rms_db = 20.0 * np.log10(rms_l)
        lvl = np.clip((np.stack([rms_db, 20.0 * np.log10(rms_s)], axis=1) + 80.0) / 80.0, 0.0, 1.0)

        n_fine = cfg.n_fine
        x = np.empty((B, cfg.n_channels, n_fine), dtype=np.float32)
        H = cfg.n_harmonics
        x[:, 0:H] = s_long[:, self.stack_idx]
        x[:, H:2 * H] = s_short[:, self.stack_idx]
        x[:, 2 * H:3 * H] = d_spec[:, self.stack_idx]
        c = 3 * H
        x[:, c:c + cfg.acf_multiples] = acf
        c += cfg.acf_multiples
        x[:, c:c + 2] = lvl[:, :, None]
        x[:, c + 2] = self.coord[None, :]
        return Features(x=x, mag_long=mag_long, rms_db=rms_db.astype(np.float32))

    def pad(self, signal: np.ndarray) -> np.ndarray:
        return np.concatenate([np.zeros(self.history, dtype=np.float32), np.asarray(signal, dtype=np.float32)])

    def frames_from_padded(self, padded: np.ndarray, ends: np.ndarray) -> np.ndarray:
        """Cut ``[len(ends), history]`` windows ending (inclusive) at sample indices ``ends`` of the unpadded signal."""
        idx = (np.asarray(ends, dtype=np.int64)[:, None] + 1) + np.arange(self.history)[None, :]
        return padded[idx]

    def frames_from_signal(self, signal: np.ndarray, ends: np.ndarray) -> np.ndarray:
        return self.frames_from_padded(self.pad(signal), ends)

    def compute_signal(self, signal: np.ndarray, ends: np.ndarray, chunk: int = 256) -> Features:
        """Features for many frames of one signal (training / evaluation)."""
        xs, mags, rms = [], [], []
        padded = self.pad(signal)
        for i in range(0, len(ends), chunk):
            f = self.compute(self.frames_from_padded(padded, ends[i:i + chunk]))
            xs.append(f.x)
            mags.append(f.mag_long)
            rms.append(f.rms_db)
        return Features(np.concatenate(xs), np.concatenate(mags), np.concatenate(rms))
