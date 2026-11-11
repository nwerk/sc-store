"""Training data: label construction, excerpt sources and the frame-sampling dataset."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import torch
from torch.utils.data import IterableDataset, get_worker_info

from ..config import FrontendConfig
from ..frontend import Frontend
from .guitarset import Recording
from .synth import ROLL_RATE, Excerpt, apply_fx, render_excerpt

ONSET_WINDOW = 0.03  # the onset head fires for 30 ms after a note starts


def labels_at(ends: np.ndarray, sr: int, roll: np.ndarray, onsets: list, onset_window: float = ONSET_WINDOW):
    """Frame / onset targets for frames whose newest sample is ``ends`` (sample indices)."""
    t = (np.asarray(ends) + 1) / sr
    ms = np.clip(np.round(t * ROLL_RATE).astype(np.int64), 0, len(roll) - 1)
    frame = roll[ms].astype(np.float32)
    onset = np.zeros_like(frame)
    for o, p in onsets:
        m = (t >= o) & (t < o + onset_window)
        onset[m, p] = 1.0
    return frame, onset


def choose_ends(rng, n_samples: int, onsets: list, sr: int, k: int, near_onset: float = 0.4) -> np.ndarray:
    n_near = int(k * near_onset) if onsets else 0
    ends = rng.integers(0, n_samples, size=k - n_near)
    if n_near:
        o = np.array([x[0] for x in onsets])
        pick = o[rng.integers(0, len(o), size=n_near)]
        near = ((pick + rng.uniform(-0.02, 0.12, size=n_near)) * sr).astype(np.int64)
        ends = np.concatenate([ends, np.clip(near, 0, n_samples - 1)])
    return ends


class PoolSource:
    """Pre-rendered synthetic excerpts stored in ``.npz`` shards (see ``make_pool.py``)."""

    def __init__(self, directory: str | Path, cfg: FrontendConfig):
        self.files = sorted(Path(directory).glob("synth_*.npz"))
        if not self.files:
            raise FileNotFoundError(f"no synth_*.npz shards in {directory}")
        self.cfg = cfg
        self._cache: tuple[int, dict] | None = None

    def _shard(self, rng):
        i = int(rng.integers(0, len(self.files)))
        if self._cache is None or self._cache[0] != i:
            z = np.load(self.files[i])
            self._cache = (i, {k: z[k] for k in z.files})
        return self._cache[1]

    def sample(self, rng) -> Excerpt:
        z = self._shard(rng)
        j = int(rng.integers(0, z["audio"].shape[0]))
        on = z["onsets"]
        on = on[on[:, 0] == j]
        return Excerpt(z["audio"][j].astype(np.float32), z["roll"][j], [(float(a), int(b)) for _, a, b in on], self.cfg.sample_rate)


class OnlineSynthSource:
    def __init__(self, cfg: FrontendConfig, duration: float = 6.0):
        self.cfg, self.duration = cfg, duration

    def sample(self, rng) -> Excerpt:
        return render_excerpt(rng, self.cfg, self.duration)


class GuitarSetSource:
    def __init__(self, recordings: list[Recording], cfg: FrontendConfig, duration: float = 6.0, p_fx: float = 0.6):
        self.recs, self.cfg, self.duration, self.p_fx = recordings, cfg, duration, p_fx

    def sample(self, rng) -> Excerpt:
        sr = self.cfg.sample_rate
        r = self.recs[int(rng.integers(0, len(self.recs)))]
        n = int(self.duration * sr)
        start = int(rng.integers(0, max(1, len(r.audio) - n))) if len(r.audio) > n else 0
        audio = r.audio[start:start + n].astype(np.float32)  # recordings are held as float16 while training
        t0 = start / sr
        ms0 = int(t0 * ROLL_RATE)
        roll = r.roll[ms0:ms0 + int(self.duration * ROLL_RATE) + 1]
        onsets = [(o - t0, p) for o, p in r.onsets if t0 <= o < t0 + len(audio) / sr]
        if rng.random() < self.p_fx:
            audio = apply_fx(rng, audio, sr, p_amp=0.25, p_room=0.2)
        else:
            audio = audio * (10 ** (rng.uniform(-30, -3) / 20) / (np.abs(audio).max() + 1e-9))
        return Excerpt(audio.astype(np.float32), roll, onsets, sr)


class FrameDataset(IterableDataset):
    """Endless stream of ``(x, frame_target, onset_target)`` chunks, ``frames_per_excerpt`` frames each."""

    def __init__(self, cfg: FrontendConfig, sources: list, weights: list[float], frames_per_excerpt: int = 192,
                 seed: int = 0):
        self.cfg, self.sources = cfg, sources
        w = np.asarray(weights, dtype=np.float64)
        self.p = w / w.sum()
        self.k, self.seed = frames_per_excerpt, seed

    def __iter__(self):
        info = get_worker_info()
        wid = info.id if info else 0
        torch.set_num_threads(1)
        rng = np.random.default_rng([self.seed, wid])
        fe = Frontend(self.cfg)
        while True:
            src = self.sources[int(rng.choice(len(self.sources), p=self.p))]
            ex = src.sample(rng)
            ends = choose_ends(rng, len(ex.audio), ex.onsets, ex.sample_rate, self.k)
            feats = fe.compute_signal(ex.audio, ends)
            yf, yo = labels_at(ends, ex.sample_rate, ex.roll, ex.onsets)
            yield torch.from_numpy(feats.x), torch.from_numpy(yf), torch.from_numpy(yo)
