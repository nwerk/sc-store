"""Train the pitch network.

Two-stage recipe (the full command lines are in scripts/train_all.sh)::

    python -m polytracker.train.make_pool --out data/pool --excerpts 3072
    python -m polytracker.train.train --pool data/pool --guitarset data/guitarset --gs-weight 0.0 --out runs/stageA
    python -m polytracker.train.train --pool data/pool --guitarset data/guitarset --gs-kind both --gs-weight 0.6 \\
        --init runs/stageA.pt --lr 1e-3 --out runs/stageB
"""
from __future__ import annotations

import argparse
import math
import os
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader

from ..config import FrontendConfig
from ..frontend import Frontend
from .data import FrameDataset, GuitarSetSource, OnlineSynthSource, PoolSource, choose_ends, labels_at
from .guitarset import load_guitarset
from .model import PitchNet


def fixed_validation(source, cfg: FrontendConfig, n_excerpts: int, k: int, seed: int):
    rng = np.random.default_rng(seed)
    fe = Frontend(cfg)
    xs, yf, yo = [], [], []
    for _ in range(n_excerpts):
        ex = source.sample(rng)
        ends = choose_ends(rng, len(ex.audio), ex.onsets, ex.sample_rate, k)
        f = fe.compute_signal(ex.audio, ends)
        a, b = labels_at(ends, ex.sample_rate, ex.roll, ex.onsets)
        xs.append(f.x), yf.append(a), yo.append(b)
    return torch.from_numpy(np.concatenate(xs)), torch.from_numpy(np.concatenate(yf)), torch.from_numpy(np.concatenate(yo))


@torch.no_grad()
def frame_metrics(model: nn.Module, x, yf, yo, thr: float = 0.5):
    model.eval()
    logits = torch.cat([model(x[i:i + 2048]) for i in range(0, len(x), 2048)])
    pf, po = torch.sigmoid(logits[:, 0]), torch.sigmoid(logits[:, 1])
    out = {}
    for name, p, y in (("frame", pf, yf), ("onset", po, yo)):
        pred = p >= thr
        tp = (pred & (y > 0.5)).sum().item()
        fp = (pred & (y <= 0.5)).sum().item()
        fn = (~pred & (y > 0.5)).sum().item()
        pr, rc = tp / max(1, tp + fp), tp / max(1, tp + fn)
        out[name] = (pr, rc, 2 * pr * rc / max(1e-9, pr + rc))
    model.train()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pool", help="directory with synth_*.npz shards (default: render online)")
    ap.add_argument("--val-pool", help="separate synthetic validation shards")
    ap.add_argument("--guitarset", help="GuitarSet root (annotation/, audio_mono-pickup_mix/, ...)")
    ap.add_argument("--gs-kind", default="mix", choices=["mix", "mic", "both"])
    ap.add_argument("--gs-weight", type=float, default=0.5, help="share of GuitarSet excerpts in the stream")
    ap.add_argument("--gs-train-players", default="0,1,2,3", help="comma separated; use 0,1,2,3,4 to also train on the val player")
    ap.add_argument("--init", help="checkpoint (.pt) to start from")
    ap.add_argument("--steps", type=int, default=6000)
    ap.add_argument("--excerpts-per-batch", type=int, default=8)
    ap.add_argument("--frames-per-excerpt", type=int, default=128)
    ap.add_argument("--lr", type=float, default=2e-3)
    ap.add_argument("--wd", type=float, default=1e-4)
    ap.add_argument("--workers", type=int, default=max(1, (os.cpu_count() or 4) - 4))
    ap.add_argument("--threads", type=int, default=4, help="torch intra-op threads of the training process")
    ap.add_argument("--width", type=int, default=64)
    ap.add_argument("--fine-width", type=int, default=32)
    ap.add_argument("--eval-every", type=int, default=500)
    ap.add_argument("--out", required=True, help="output prefix: writes <out>.pt and <out>.npz")
    ap.add_argument("--seed", type=int, default=0)
    a = ap.parse_args()

    os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
    torch.manual_seed(a.seed)
    torch.set_num_threads(a.threads)
    cfg = FrontendConfig()
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)

    synth = PoolSource(a.pool, cfg) if a.pool else OnlineSynthSource(cfg)
    sources, weights = [synth], [1.0 - a.gs_weight if a.guitarset else 1.0]
    val_sets = {"synth": fixed_validation(PoolSource(a.val_pool, cfg) if a.val_pool else OnlineSynthSource(cfg), cfg, 24, 100, 4242)}
    if a.guitarset:
        players = tuple(int(p) for p in a.gs_train_players.split(","))
        kinds = ["mix", "mic"] if a.gs_kind == "both" else [a.gs_kind]
        train_recs, val_recs = [], []
        for kind in kinds:
            allrecs = load_guitarset(a.guitarset, cfg, None, kind, half=True)
            train_recs += [r for r in allrecs if r.player in players]
            val_recs += [r for r in allrecs if r.player == 4]
        print(f"GuitarSet: {len(train_recs)} train recordings, {len(val_recs)} val recordings")
        sources.append(GuitarSetSource(train_recs, cfg))
        weights.append(a.gs_weight)
        val_sets["guitarset(p04)"] = fixed_validation(GuitarSetSource(val_recs, cfg, p_fx=0.0), cfg, 40, 100, 4243)

    model = PitchNet(cfg, fine_width=a.fine_width, width=a.width)
    if a.init:
        model.load_state_dict(torch.load(a.init, map_location="cpu"))
    print(f"parameters: {model.n_params():,}")
    opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=a.wd)
    warm = 200
    sched = torch.optim.lr_scheduler.LambdaLR(
        opt, lambda s: min(1.0, (s + 1) / warm) * (0.5 * (1 + math.cos(math.pi * min(1.0, s / a.steps))) * 0.97 + 0.03))
    bce = nn.BCEWithLogitsLoss()

    ds = FrameDataset(cfg, sources, weights, a.frames_per_excerpt, seed=a.seed + 1)
    dl = iter(DataLoader(ds, batch_size=a.excerpts_per_batch, num_workers=a.workers, prefetch_factor=6,
                         persistent_workers=True))
    model.train()
    t0, run = time.time(), 0.0
    best = -1.0
    for step in range(1, a.steps + 1):
        x, yf, yo = next(dl)
        x, yf, yo = x.flatten(0, 1), yf.flatten(0, 1), yo.flatten(0, 1)
        logits = model(x)
        loss = bce(logits[:, 0], yf) + 0.5 * bce(logits[:, 1], yo)
        opt.zero_grad(set_to_none=True)
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 2.0)
        opt.step()
        sched.step()
        run = 0.98 * run + 0.02 * loss.item() if step > 1 else loss.item()
        if step % 50 == 0:
            print(f"\rstep {step}/{a.steps} loss {run:.4f}  {step / (time.time() - t0):.1f} it/s", end="", flush=True)
        if step % a.eval_every == 0 or step == a.steps:
            line = []
            score = 0.0
            for name, (vx, vyf, vyo) in val_sets.items():
                m = frame_metrics(model, vx, vyf, vyo)
                line.append(f"{name}: frame P/R/F1 {m['frame'][0]:.3f}/{m['frame'][1]:.3f}/{m['frame'][2]:.3f} onset F1 {m['onset'][2]:.3f}")
                score = m["frame"][2]
            print(f"\nstep {step}  " + "  |  ".join(line))
            torch.save(model.state_dict(), a.out + ".pt")
            if score > best:
                best = score
                torch.save(model.state_dict(), a.out + ".best.pt")
    model.eval()
    model.export(a.out + ".npz", {"trained_steps": a.steps, "guitarset": bool(a.guitarset)})
    print(f"\nwrote {a.out}.pt / .npz  ({time.time() - t0:.0f}s)")


if __name__ == "__main__":
    main()
