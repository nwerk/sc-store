"""Constants shared by training, offline evaluation and the realtime tracker.

Everything the trained network depends on lives in :class:`FrontendConfig`.
Training and the realtime tracker import the same object, so the feature
layout cannot drift between the two.
"""
from __future__ import annotations

import math
from dataclasses import asdict, dataclass

import numpy as np

REF_RATE = 48000  # window lengths below are expressed in samples at this rate


@dataclass(frozen=True)
class FrontendConfig:
    sample_rate: int = REF_RATE
    hop: int = 256  # samples between frames (5.3 ms at 48 kHz)

    # Output pitch range (MIDI). D2 allows drop-D tuning, E6 is fret 24 on the high E string.
    pitch_lo: int = 38
    pitch_hi: int = 88
    bins_per_semitone: int = 3

    # Log-frequency spectral grid the harmonic stacks are gathered from.
    grid_lo: int = 36
    grid_semitones: int = 90
    n_harmonics: int = 8

    # Analysis windows in samples at REF_RATE (scaled for other sample rates).
    long_win: int = 4096  # 85 ms  - resolves low strings through their upper harmonics
    short_win: int = 1024  # 21 ms  - fast response for high notes, onsets and decays
    acf_win: int = 2048  # 43 ms  - periodicity evidence for the low register
    delta_lag: int = 1024  # lag of the spectral-flux channel (must be a multiple of hop)
    window_peak: float = 0.85  # asymmetric window: peak position, keeps the newest samples audible
    acf_multiples: int = 2  # ACF is sampled at lag, 2*lag, ...
    db_range: float = 60.0  # dynamic range kept per frame, relative to the frame maximum
    db_floor: float = -60.0  # the frame reference never drops below this (dBFS)

    @property
    def n_pitch(self) -> int:
        return self.pitch_hi - self.pitch_lo + 1

    @property
    def n_fine(self) -> int:
        return self.n_pitch * self.bins_per_semitone

    @property
    def n_grid(self) -> int:
        return self.grid_semitones * self.bins_per_semitone

    @property
    def n_channels(self) -> int:
        return 3 * self.n_harmonics + self.acf_multiples + 2 + 1

    def scaled(self, n: int) -> int:
        """Window length in samples for this sample rate (multiple of 16)."""
        return max(16, int(round(n * self.sample_rate / REF_RATE / 16.0)) * 16)

    @property
    def history(self) -> int:
        """Number of past samples one frame needs."""
        return max(self.scaled(self.long_win), self.scaled(self.acf_win), self.scaled(self.short_win) + self.delta_samples)

    @property
    def delta_samples(self) -> int:
        return self.scaled(self.delta_lag)

    def to_dict(self) -> dict:
        return asdict(self)

    @staticmethod
    def from_dict(d: dict) -> "FrontendConfig":
        known = {k: v for k, v in d.items() if k in FrontendConfig.__dataclass_fields__}
        return FrontendConfig(**known)

    def with_rate(self, sample_rate: int, hop: int | None = None) -> "FrontendConfig":
        d = self.to_dict()
        d["sample_rate"] = int(sample_rate)
        if hop is not None:
            d["hop"] = int(hop)
        return FrontendConfig.from_dict(d)


def midi_to_hz(m):
    return 440.0 * np.power(2.0, (np.asarray(m, dtype=np.float64) - 69.0) / 12.0)


def hz_to_midi(f):
    return 69.0 + 12.0 * np.log2(np.maximum(np.asarray(f, dtype=np.float64), 1e-9) / 440.0)


def harmonic_offsets(cfg: FrontendConfig) -> np.ndarray:
    """Grid-bin offset of harmonic h (1-based) relative to its fundamental."""
    return np.array(
        [int(round(12 * cfg.bins_per_semitone * math.log2(h))) for h in range(1, cfg.n_harmonics + 1)]
    )
