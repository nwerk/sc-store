"""Evaluate the full pipeline (frontend -> network -> decoder) on annotated audio.

    python -m polytracker.train.evaluate --model models/guitar_v1.npz --guitarset data/guitarset --split test
"""
from __future__ import annotations

import argparse
import json
import time

import numpy as np

from ..config import FrontendConfig
from ..decoder import DecoderParams
from ..engine import Tracker
from ..net import PitchNetNP
from .guitarset import load_guitarset
from .synth import ROLL_RATE


def match_onsets(ref: list, est: list, tol: float = 0.05):
    """Greedy one-to-one matching of ``(time, pitch)`` onsets. Returns (tp, deltas)."""
    ref = sorted(ref)
    used = set()
    deltas = []
    for t, p in sorted(est):
        best, bd = None, tol + 1e-9
        for i, (rt, rp) in enumerate(ref):
            if i in used or rp != p:
                continue
            d = abs(rt - t)
            if d <= bd:
                best, bd = i, d
        if best is not None:
            used.add(best)
            deltas.append(t - ref[best][0])
    return len(deltas), deltas


def prf(tp, fp, fn):
    p, r = tp / max(1, tp + fp), tp / max(1, tp + fn)
    return p, r, 2 * p * r / max(1e-9, p + r)


def pitch_errors(run, rec, cfg):
    """Cents error of every sounding voice against the hexaphonic ground-truth contour of the matching string."""
    from ..config import midi_to_hz

    ms = np.clip(np.round(run.times * ROLL_RATE).astype(int), 0, rec.contour.shape[1] - 1)
    gt = rec.contour[:, ms]  # [strings, N]
    ref, nom = [], []
    for v in range(run.voice_midi.shape[1]):
        m = run.voice_midi[:, v]
        ok = m >= 0
        if not ok.any():
            continue
        nominal = midi_to_hz(np.maximum(m, 1))
        with np.errstate(divide="ignore", invalid="ignore"):
            dist = np.abs(1200 * np.log2(gt / nominal[None, :]))
        dist[gt <= 0] = np.inf
        best = dist.argmin(axis=0)
        bd = dist[best, np.arange(len(m))]
        sel = ok & (bd < 60.0)
        g = gt[best, np.arange(len(m))][sel]
        ref.append(1200 * np.log2(run.voice_freq[sel, v] / g))
        nom.append(1200 * np.log2(nominal[sel] / g))
    if not ref:
        return np.zeros(0), np.zeros(0)
    return np.concatenate(ref), np.concatenate(nom)


def evaluate_recordings(tracker: Tracker, recs, tol: float = 0.05, verbose: bool = False, cache: dict | None = None) -> dict:
    cfg = tracker.cfg
    f_tp = f_fp = f_fn = 0
    o_tp = o_fp = o_fn = 0
    o1_tp = o1_fp = o1_fn = 0
    deltas_all = []
    proc_ms = []
    err_ref, err_nom = [], []
    n_poly = []
    moves = []  # ms between a note's start and each correction of its pitch
    for r in recs:
        t0 = time.perf_counter()
        run = tracker.decode(cache[r.name]) if cache is not None else tracker.run_full(r.audio)
        events, times = run.events, run.times
        if r.contour is not None:
            e_ref, e_nom = pitch_errors(run, r, cfg)
            err_ref.append(e_ref), err_nom.append(e_nom)
        proc_ms.append((time.perf_counter() - t0) / len(times) * 1e3)
        # active-set per frame from decoder events
        active = np.zeros((len(times), cfg.n_pitch), dtype=bool)
        state = np.zeros(cfg.n_pitch, dtype=bool)
        ev_i = 0
        for i, t in enumerate(times):
            while ev_i < len(events) and events[ev_i].t <= t + 1e-9:
                e = events[ev_i]
                if e.kind == "move":
                    state[e.prev - cfg.pitch_lo] = False
                state[e.pitch - cfg.pitch_lo] = e.kind != "off"
                ev_i += 1
            active[i] = state
        ms = np.clip(np.round(times * ROLL_RATE).astype(int), 0, len(r.roll) - 1)
        gt = r.roll[ms] > 0
        f_tp += int((active & gt).sum()); f_fp += int((active & ~gt).sum()); f_fn += int((~active & gt).sum())
        n_poly.append(gt.sum(1).mean())

        # a moved note is one onset: heard at its start, with the pitch it was corrected to
        est, first, cur = [], [], {}
        for e in events:
            if e.kind == "on":
                cur[e.voice] = len(est)
                est.append([e.t, e.pitch - cfg.pitch_lo])
                first.append((e.t, e.pitch - cfg.pitch_lo))
            elif e.kind == "move":
                est[cur[e.voice]][1] = e.pitch - cfg.pitch_lo
                moves.append((e.t - est[cur[e.voice]][0]) * 1e3)
        est = [tuple(x) for x in est]
        tp, d = match_onsets(r.onsets, est, tol)
        o_tp += tp; o_fp += len(est) - tp; o_fn += len(r.onsets) - tp
        tp1, _ = match_onsets(r.onsets, first, tol)  # scored on the pitch heard first, before any move
        o1_tp += tp1; o1_fp += len(first) - tp1; o1_fn += len(r.onsets) - tp1
        deltas_all += d
        if verbose:
            fp_, fr_, ff_ = prf(f_tp, f_fp, f_fn)
            print(f"  {r.name}: frame F1(cum) {ff_:.3f}  onsets gt {len(r.onsets)} est {len(est)} matched {tp}")
    fm = prf(f_tp, f_fp, f_fn)
    om = prf(o_tp, o_fp, o_fn)
    d = np.array(deltas_all) * 1e3 if deltas_all else np.zeros(1)
    res = {
        "files": len(recs),
        "frame_precision": fm[0], "frame_recall": fm[1], "frame_f1": fm[2],
        "onset_precision": om[0], "onset_recall": om[1], "onset_f1": om[2],
        "onset_delay_ms_median": float(np.median(d)), "onset_delay_ms_p90": float(np.percentile(d, 90)),
        "onset_delay_ms_p10": float(np.percentile(d, 10)),
        "mean_polyphony": float(np.mean(n_poly)),
        "notes": o_tp + o_fp, "onset_f1_first_pitch": prf(o1_tp, o1_fp, o1_fn)[2],
        "moves": len(moves), "move_after_ms_median": float(np.median(moves)) if moves else 0.0,
        "ms_per_frame_offline": float(np.mean(proc_ms)),
    }
    if err_ref and sum(len(e) for e in err_ref):
        ref, nom = np.concatenate(err_ref), np.concatenate(err_nom)
        res.update({
            "pitch_voice_frames": int(len(ref)),
            "pitch_cents_median_abs": float(np.median(np.abs(ref))),
            "pitch_within_10c": float(np.mean(np.abs(ref) < 10)),
            "pitch_within_25c": float(np.mean(np.abs(ref) < 25)),
            "nominal_cents_median_abs": float(np.median(np.abs(nom))),
            "nominal_within_25c": float(np.mean(np.abs(nom) < 25)),
        })
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--guitarset")
    ap.add_argument("--split", default="test", choices=["train", "val", "test"])
    ap.add_argument("--kind", default="mix", choices=["mix", "mic"])
    ap.add_argument("--pool", help="synthetic shards to evaluate on instead")
    ap.add_argument("--limit", type=int)
    d = DecoderParams()
    ap.add_argument("--on", type=float, default=d.on_thresh)
    ap.add_argument("--off", type=float, default=d.off_thresh)
    ap.add_argument("--onset", type=float, default=d.onset_thresh)
    ap.add_argument("--confirm-ms", type=float, default=d.on_confirm_ms)
    ap.add_argument("--correct-ms", type=float, default=d.correct_ms)
    ap.add_argument("--correct-span", type=int, default=d.correct_span)
    ap.add_argument("--correct-drop", type=float, default=d.correct_drop)
    ap.add_argument("--tol", type=float, default=0.05)
    ap.add_argument("--json", help="write metrics to this file")
    ap.add_argument("-v", "--verbose", action="store_true")
    a = ap.parse_args()

    model = PitchNetNP.load(a.model)
    params = DecoderParams(on_thresh=a.on, off_thresh=a.off, onset_thresh=a.onset, on_confirm_ms=a.confirm_ms,
                           correct_ms=a.correct_ms, correct_span=a.correct_span, correct_drop=a.correct_drop)
    tracker = Tracker(model, params)
    if a.guitarset:
        recs = load_guitarset(a.guitarset, model.cfg, a.split, a.kind, a.limit, contours=True)
    else:
        from .data import PoolSource
        from .guitarset import Recording
        src, rng = PoolSource(a.pool, model.cfg), np.random.default_rng(7)
        recs = []
        for i in range(a.limit or 24):
            ex = src.sample(rng)
            recs.append(Recording(f"synth{i}", -1, ex.audio, ex.roll, ex.onsets))
    m = evaluate_recordings(tracker, recs, a.tol, a.verbose)
    for k, v in m.items():
        print(f"{k:26s} {v:.4f}" if isinstance(v, float) else f"{k:26s} {v}")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(m, f, indent=2)


if __name__ == "__main__":
    main()
