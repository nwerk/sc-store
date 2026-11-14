"""CPU measurements: the ``bench`` command and the automatic hop choice of ``run --hop auto``."""
from __future__ import annotations

import os
import time

import numpy as np

from .engine import Tracker

# A frame may use this share of its hop on average, and its 99th percentile this share. The rest is headroom for
# the OS, scsynth sharing the CPU, and the moments when every voice refines in the same frame.
AUTO_MEAN_LOAD = 0.45
AUTO_P99_LOAD = 0.80
AUTO_HOPS = (256, 512)  # must divide the model's delta lag (1024 at 48 kHz)

_FAST_BLAS = ("openblas", "blis", "mkl", "atlas", "accelerate", "armpl")


def bench_signal(sr: int, seconds: float) -> np.ndarray:
    """Six ringing strings (open E major chord) plus noise: the decoder's worst case, every voice busy."""
    t = np.arange(int(sr * seconds)) / sr
    x = sum(0.06 * np.sin(2 * np.pi * f * h * t) / h
            for f in (82.41, 123.47, 164.81, 207.65, 246.94, 329.63) for h in range(1, 9))
    return (x + 0.002 * np.random.default_rng(0).standard_normal(len(t))).astype(np.float32)


def measure(tracker: Tracker, seconds: float = 4.0, warmup: int = 20) -> np.ndarray:
    """Wall-clock milliseconds per frame of ``tracker.process`` on :func:`bench_signal`."""
    cfg = tracker.cfg
    x = bench_signal(cfg.sample_rate, seconds)
    hist = tracker.fe.pad(x)
    times = []
    for i in range((len(x) - cfg.hop) // cfg.hop):
        end = (i + 1) * cfg.hop
        h = hist[end:end + cfg.history]
        t0 = time.perf_counter()
        tracker.process(h, end / cfg.sample_rate)
        times.append(time.perf_counter() - t0)
    tracker.dec.reset()
    tracker._db_short.clear()
    return np.array(times[warmup:]) * 1e3


def budget_ms(tracker: Tracker) -> float:
    return 1e3 * tracker.cfg.hop / tracker.cfg.sample_rate


def summary(tracker: Tracker, ms: np.ndarray) -> str:
    b = budget_ms(tracker)
    return (f"hop {tracker.cfg.hop} ({b:.2f} ms budget): mean {ms.mean():.3f} ms  p50 {np.percentile(ms, 50):.3f}  "
            f"p99 {np.percentile(ms, 99):.3f}  max {ms.max():.3f}  -> {100 * ms.mean() / b:.1f}% of one core")


def choose_hop(load, seconds: float = 1.0, log=print) -> Tracker:
    """Return a tracker with the smallest hop in :data:`AUTO_HOPS` this machine can sustain.

    ``load(hop)`` builds a :class:`Tracker`. Takes about ``seconds`` of audio per candidate (well under a second
    of wall time even on a Raspberry Pi 4).
    """
    tracker = None
    for hop in AUTO_HOPS:
        tracker = load(hop)
        ms = measure(tracker, seconds)
        b = budget_ms(tracker)
        mean, p99 = ms.mean() / b, np.percentile(ms, 99) / b
        ok = mean <= AUTO_MEAN_LOAD and p99 <= AUTO_P99_LOAD
        log(f"[polytracker] auto hop: {summary(tracker, ms)}, p99 {100 * p99:.0f}% -> {'ok' if ok else 'too slow'}")
        if ok:
            return tracker
    log(f"[polytracker] warning: even hop {tracker.cfg.hop} is tight on this machine; "
        "try --voices 4, --no-refine or an idle core (--cpu)")
    return tracker


def blas_libraries() -> list[str]:
    """Paths of the BLAS libraries numpy has loaded (Linux; empty elsewhere)."""
    a = np.ones((8, 8), dtype=np.float32)
    a @ a  # make sure the BLAS is loaded
    try:
        with open("/proc/self/maps") as f:
            libs = {line.split()[-1] for line in f if ".so" in line}
    except OSError:
        return []
    return sorted(p for p in libs if any(k in os.path.basename(p).lower() for k in ("blas", "mkl", "armpl"))
                  or "openblas" in p.lower())


def blas_warning() -> str | None:
    """A hint when numpy runs on the unoptimised reference BLAS (Debian's ``libblas3``), else ``None``."""
    libs = blas_libraries()
    if not libs or any(k in p.lower() for p in libs for k in _FAST_BLAS):
        return None
    return ("numpy uses the reference BLAS (" + ", ".join(libs) + "); the network runs several times slower. "
            "Install OpenBLAS:  sudo apt install libopenblas0-pthread")
