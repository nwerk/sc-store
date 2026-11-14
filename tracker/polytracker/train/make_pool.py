"""Render a pool of synthetic guitar excerpts to ``synth_*.npz`` shards (multi-process).

    python -m polytracker.train.make_pool --out /tmp/pool --excerpts 4000
"""
from __future__ import annotations

import argparse
import os
import time
from multiprocessing import Pool
from pathlib import Path

import numpy as np

from ..config import FrontendConfig
from .synth import render_excerpt

SHARD = 32


def _make_shard(args):
    out, idx, seed, duration = args
    os.environ["OPENBLAS_NUM_THREADS"] = "1"
    cfg = FrontendConfig()
    rng = np.random.default_rng([seed, idx])
    audio, rolls, onsets = [], [], []
    for j in range(SHARD):
        ex = render_excerpt(rng, cfg, duration)
        audio.append(ex.audio.astype(np.float16))
        rolls.append(ex.roll)
        onsets.extend((j, t, p) for t, p in ex.onsets)
    path = Path(out) / f"synth_{idx:04d}.npz"
    np.savez(path, audio=np.stack(audio), roll=np.stack(rolls), onsets=np.array(onsets, dtype=np.float64).reshape(-1, 3))
    return idx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--excerpts", type=int, default=2048)
    ap.add_argument("--duration", type=float, default=6.0)
    ap.add_argument("--seed", type=int, default=1234)
    ap.add_argument("--procs", type=int, default=max(1, (os.cpu_count() or 2) - 2))
    ap.add_argument("--start-shard", type=int, default=0)
    a = ap.parse_args()
    Path(a.out).mkdir(parents=True, exist_ok=True)
    n_shards = -(-a.excerpts // SHARD)
    jobs = [(a.out, a.start_shard + i, a.seed, a.duration) for i in range(n_shards)]
    t0 = time.time()
    with Pool(a.procs) as pool:
        for k, _ in enumerate(pool.imap_unordered(_make_shard, jobs), 1):
            print(f"\r{k}/{n_shards} shards  {time.time() - t0:.0f}s", end="", flush=True)
    print()


if __name__ == "__main__":
    main()
