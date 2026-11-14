"""Classical spectral refinement of a note's fundamental frequency.

The network decides *which* semitones sound; this module measures *how exactly*
they are tuned (bends, vibrato, intonation) from the long-window magnitude
spectrum. Harmonics that coincide with the harmonics of another active note
are ignored, so chords do not pull each other's estimates.
"""
from __future__ import annotations

import math

import numpy as np

from .config import FrontendConfig

INHARMONICITY = 8e-5  # typical guitar string stiffness coefficient


class PitchRefiner:
    def __init__(self, cfg: FrontendConfig, n_fft: int, max_harmonics: int = 6, max_dev_cents: float = 35.0,
                 collision_bins: float = 3.5, agree_cents: float = 12.0):
        self.sr = cfg.sample_rate
        self.n_fft = n_fft
        self.bin_hz = self.sr / n_fft
        self.max_h = max_harmonics
        self.max_dev = max_dev_cents
        self.collision_bins = collision_bins  # harmonics closer than this to another note's harmonics are ignored
        self.agree_cents = agree_cents  # harmonic votes further than this from the weighted median are discarded
        self.nyq_limit = 0.45 * self.sr
        # harmonic number and stiffness stretch, precomputed: f_h = f0 * h * stretch_h
        self._h = np.arange(1, 17, dtype=np.float64)
        self._stretch = np.sqrt(1.0 + INHARMONICITY * self._h * self._h)
        self._bl_off = np.arange(-1, 2)  # band_level looks at the nearest bin and its two neighbours

    def _harmonics(self, f0, count: int):
        """Stretched harmonic frequencies; ``f0`` may be a scalar or an array (one row per f0)."""
        f0 = np.asarray(f0, dtype=np.float64)
        return f0[..., None] * self._h[:count] * self._stretch[:count] if f0.ndim else f0 * self._h[:count] * self._stretch[:count]

    def collision_harmonics(self, f0s) -> np.ndarray:
        """Harmonics of other sounding notes that ``refine`` avoids, ``[len(f0s), 10]``."""
        return self._harmonics(np.asarray(f0s, dtype=np.float64).reshape(-1), 10)

    def refine(self, mag: np.ndarray, f_guess: float, others, other_h: np.ndarray | None = None) -> tuple[float | None, float]:
        """Returns ``(refined_f0 or None, level)``; level is the RMS magnitude of the used harmonics.

        ``others``: frequencies of the other sounding notes. ``other_h`` (their ``collision_harmonics``) may be
        passed instead to avoid recomputing them for every note of a frame.
        """
        bin_hz = self.bin_hz
        n_bins = len(mag)
        harm = self._harmonics(f_guess, self.max_h)
        if other_h is None:
            other_h = self.collision_harmonics(others).ravel() if len(others) else np.empty(0)
        else:
            other_h = other_h.ravel()
        spacing_bins = f_guess / bin_hz
        if other_h.size:  # harmonics that sit on a partial of another sounding note
            collides = (np.abs(other_h[:, None] - harm[None, :]).min(axis=0) < self.collision_bins * bin_hz).tolist()
        else:
            collides = [False] * len(harm)
        votes = []
        level_sq = 0.0
        for h, exp_f in enumerate(harm.tolist(), start=1):
            if exp_f > self.nyq_limit or exp_f > 7000.0:
                break
            if collides[h - 1]:
                continue
            dev_bins = exp_f * (2.0 ** (self.max_dev / 1200.0) - 1.0) / bin_hz
            hw = max(1.5, min(dev_bins, 0.42 * spacing_bins))
            c = exp_f / bin_hz
            lo, hi = int(math.floor(c - hw)), int(math.ceil(c + hw))
            lo, hi = max(1, lo), min(n_bins - 2, hi)
            if hi <= lo:
                continue
            seg = mag[lo:hi + 1]
            k = int(np.argmax(seg)) + lo
            m = float(mag[k])
            if m < 1e-5 or k <= 1 or k >= n_bins - 2:
                continue
            a, b, g = math.log(mag[k - 1] + 1e-12), math.log(m + 1e-12), math.log(mag[k + 1] + 1e-12)
            if not (b >= a and b >= g):
                continue  # not a local maximum: the window edge, not a partial
            denom = a - 2.0 * b + g
            delta = 0.5 * (a - g) / denom if denom < -1e-9 else 0.0
            peak_f = (k + delta) * bin_hz
            # undo the stiffness stretch so every harmonic votes for the same f0
            votes.append((peak_f / (h * math.sqrt(1.0 + INHARMONICITY * h * h)), m * h, m))
        if len(votes) < 2:  # a single partial cannot be told apart from a neighbour's leakage
            return None, 0.0
        f = np.array([v[0] for v in votes])
        w = np.array([v[1] for v in votes])
        order = np.argsort(f)
        med = f[order][np.searchsorted(np.cumsum(w[order]), 0.5 * w.sum())]
        keep = np.abs(1200.0 * np.log2(f / med)) < self.agree_cents  # drop harmonics that disagree with the majority
        if keep.sum() < 2:
            return None, 0.0
        f0 = float((f[keep] * w[keep]).sum() / w[keep].sum())
        if abs(1200.0 * math.log2(f0 / f_guess)) > self.max_dev + 10:
            return None, 0.0
        level_sq = sum(v[2] ** 2 for v, k in zip(votes, keep) if k)
        return f0, math.sqrt(level_sq / keep.sum())

    def band_levels(self, mag: np.ndarray, f0s, harmonics: int = 4) -> np.ndarray:
        """Vectorised :meth:`band_level` for several fundamentals at once (same numbers)."""
        f0s = np.asarray(f0s, dtype=np.float64).reshape(-1)
        k = np.rint(self._harmonics(f0s, harmonics) / self.bin_hz).astype(np.int64)  # [V, H]
        valid = np.cumprod(k + 2 < len(mag), axis=1).astype(bool)  # band_level stops at the first harmonic out of range
        idx = np.clip(k[..., None] + self._bl_off, 0, len(mag) - 1)
        peak = mag[idx].max(axis=2).astype(np.float64)
        acc = np.where(valid, peak * peak, 0.0).sum(axis=1)
        n = valid.sum(axis=1)
        return np.where(n > 0, np.sqrt(acc / np.maximum(n, 1)), 0.0)

    def band_level(self, mag: np.ndarray, f0: float, harmonics: int = 4) -> float:
        """RMS magnitude of the strongest bin around the first few harmonics (full-scale sine == 1)."""
        acc = 0.0
        n = 0
        for exp_f in self._harmonics(f0, harmonics):
            k = int(round(exp_f / self.bin_hz))
            if k + 2 >= len(mag):
                break
            acc += float(mag[max(0, k - 1):k + 2].max()) ** 2
            n += 1
        return math.sqrt(acc / n) if n else 0.0
