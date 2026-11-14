"""Grid-search the decoder thresholds on validation recordings (network outputs are computed once).

    python -m polytracker.train.tune_decoder --model models/guitar_v1.npz --guitarset data/guitarset --limit 30
"""
from __future__ import annotations

import argparse
import itertools
from multiprocessing import Pool

import numpy as np

from ..decoder import DecoderParams
from ..engine import Tracker
from ..net import PitchNetNP
from .evaluate import evaluate_recordings
from .guitarset import load_guitarset

_STATE = {}


def _init(model_path, recs, cache):
    _STATE["model"] = PitchNetNP.load(model_path)
    _STATE["recs"], _STATE["cache"] = recs, cache


def _score(cfg):
    on, off, onset, on_ms, off_ms = cfg
    p = DecoderParams(on_thresh=on, off_thresh=off, onset_thresh=onset, on_confirm_ms=on_ms,
                      off_confirm_ms=off_ms, refine=False)
    tr = Tracker(_STATE["model"], p)
    m = evaluate_recordings(tr, _STATE["recs"], cache=_STATE["cache"])
    return cfg, m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--guitarset", required=True)
    ap.add_argument("--split", default="val")
    ap.add_argument("--kind", default="mix")
    ap.add_argument("--limit", type=int, default=30)
    ap.add_argument("--procs", type=int, default=8)
    a = ap.parse_args()

    model = PitchNetNP.load(a.model)
    recs = load_guitarset(a.guitarset, model.cfg, a.split, a.kind, a.limit)
    tr = Tracker(model)
    cache = {}
    for r in recs:
        t, p, _, rms = tr.frame_probabilities(r.audio)
        cache[r.name] = (t, p, None, rms)
    grid = list(itertools.product([0.5, 0.6, 0.7], [0.3, 0.4, 0.5], [0.5, 0.65, 0.8], [0.0, 8.0], [15.0, 30.0]))
    print(f"{len(grid)} configurations on {len(recs)} recordings")
    with Pool(a.procs, initializer=_init, initargs=(a.model, recs, cache)) as pool:
        results = pool.map(_score, grid, chunksize=4)
    results.sort(key=lambda r: -(r[1]["frame_f1"] + r[1]["onset_f1"]))
    print("on   off  onset on_ms off_ms | frame P/R/F1        | onset P/R/F1        | delay med/p90 ms")
    for cfg, m in results[:12]:
        print(f"{cfg[0]:.2f} {cfg[1]:.2f} {cfg[2]:.2f} {cfg[3]:5.0f} {cfg[4]:5.0f}  | "
              f"{m['frame_precision']:.3f}/{m['frame_recall']:.3f}/{m['frame_f1']:.3f} | "
              f"{m['onset_precision']:.3f}/{m['onset_recall']:.3f}/{m['onset_f1']:.3f} | "
              f"{m['onset_delay_ms_median']:.1f}/{m['onset_delay_ms_p90']:.1f}")


if __name__ == "__main__":
    main()
