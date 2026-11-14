"""GuitarSet (CC BY 4.0, Xi et al. 2018) loader: mono pickup-mix / mic audio + JAMS note annotations."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from scipy import signal as sps

from ..config import FrontendConfig
from .synth import ROLL_RATE

SUBDIRS = {"mix": ("audio_mono-pickup_mix", "_mix.wav"), "mic": ("audio_mono-mic", "_mic.wav")}
SPLITS = {"train": (0, 1, 2, 3), "val": (4,), "test": (5,)}


@dataclass
class Recording:
    name: str
    player: int
    audio: np.ndarray  # float32 @ cfg.sample_rate
    roll: np.ndarray  # [ms, n_pitch] uint8
    onsets: list  # [(time_s, pitch_index)]
    contour: np.ndarray | None = None  # [n_strings, ms] ground-truth f0 in Hz (0 = unvoiced), GuitarSet only


def parse_contours(j: dict, duration: float) -> np.ndarray:
    """GuitarSet stores one dense pitch contour per string (hexaphonic pickup, ~5.8 ms resolution)."""
    n_ms = int(duration * ROLL_RATE) + 1
    out = []
    for ann in j["annotations"]:
        if ann["namespace"] != "pitch_contour":
            continue
        d = ann["data"]
        t = np.asarray(d["time"], dtype=np.float64)
        if len(t) < 2:  # string never played
            out.append(np.zeros(n_ms))
            continue
        f = np.array([v["frequency"] if v["voiced"] else 0.0 for v in d["value"]])
        grid = np.arange(n_ms) / ROLL_RATE
        idx = np.clip(np.searchsorted(t, grid), 1, len(t) - 1)
        near = np.where(np.abs(t[idx - 1] - grid) < np.abs(t[idx] - grid), idx - 1, idx)
        c = f[near]
        c[np.abs(t[near] - grid) > 0.012] = 0.0
        out.append(c)
    return np.stack(out) if out else np.zeros((0, n_ms))


def parse_jams(path: Path, cfg: FrontendConfig, duration: float, contours: bool = False):
    j = json.loads(Path(path).read_text())
    roll = np.zeros((int(duration * ROLL_RATE) + 1, cfg.n_pitch), dtype=np.uint8)
    onsets = []
    for ann in j["annotations"]:
        if ann["namespace"] != "note_midi":
            continue
        for d in ann["data"]:
            p = int(round(d["value"]))
            if not (cfg.pitch_lo <= p <= cfg.pitch_hi):
                continue
            a, b = int(d["time"] * ROLL_RATE), int((d["time"] + d["duration"]) * ROLL_RATE)
            roll[a:b, p - cfg.pitch_lo] = 1
            onsets.append((float(d["time"]), p - cfg.pitch_lo))
    return roll, onsets, (parse_contours(j, duration) if contours else None)


def _load_audio(path: Path, cfg: FrontendConfig, cache: Path | None, half: bool = False) -> np.ndarray:
    if cache is not None and cache.exists():
        x = np.load(cache)
        return x if half else x.astype(np.float32)
    import soundfile as sf

    x, sr = sf.read(str(path), dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    if sr != cfg.sample_rate:
        g = np.gcd(sr, cfg.sample_rate)
        x = sps.resample_poly(x, cfg.sample_rate // g, sr // g).astype(np.float32)
    if cache is not None:
        cache.parent.mkdir(parents=True, exist_ok=True)
        np.save(cache, x.astype(np.float16))
    return x


def load_guitarset(root: str | Path, cfg: FrontendConfig, split: str | None = None, kind: str = "mix",
                   limit: int | None = None, contours: bool = False, half: bool = False) -> list[Recording]:
    root = Path(root)
    sub, suffix = SUBDIRS[kind]
    players = SPLITS[split] if split else tuple(range(6))
    recs = []
    for jp in sorted((root / "annotation").glob("*.jams")):
        player = int(jp.stem[:2])
        if player not in players:
            continue
        wav = root / sub / (jp.stem + suffix)
        if not wav.exists():
            continue
        audio = _load_audio(wav, cfg, root / "cache48k" / f"{jp.stem}_{kind}.npy", half)
        roll, onsets, contour = parse_jams(jp, cfg, len(audio) / cfg.sample_rate, contours)
        recs.append(Recording(jp.stem, player, audio, roll, onsets, contour))
        if limit and len(recs) >= limit:
            break
    return recs
