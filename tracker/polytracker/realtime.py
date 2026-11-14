"""Realtime loop: audio source -> frames -> network -> decoder -> OSC."""
from __future__ import annotations

import ctypes
import gc
import os
import re
import signal
import sys
import time

import numpy as np

from .decoder import DecoderParams
from .engine import Tracker
from .outputs import MONO_MODES, OscOutput
from .oscmini import ControlServer

SETTABLE = {
    "on": "on_thresh", "off": "off_thresh", "onset": "onset_thresh", "gate_db": "gate_db",
    "retrigger_ms": "retrigger_ms", "on_confirm_ms": "on_confirm_ms", "off_confirm_ms": "off_confirm_ms",
    "amp_range_db": "amp_range_db", "glide_alpha": "glide_alpha",
}


def set_realtime(priority: int, cpu: int | None):
    if cpu is not None and hasattr(os, "sched_setaffinity"):
        try:
            os.sched_setaffinity(0, {cpu})
        except OSError as e:
            print(f"[polytracker] cannot pin to cpu {cpu}: {e}", flush=True)
    if priority > 0 and hasattr(os, "sched_setscheduler"):
        try:
            os.sched_setscheduler(0, os.SCHED_FIFO, os.sched_param(priority))
            print(f"[polytracker] SCHED_FIFO priority {priority}", flush=True)
        except (PermissionError, OSError) as e:
            print(f"[polytracker] no realtime priority ({e}); add the user to the 'audio' group with rtprio limits", flush=True)


def die_with_parent():
    """Linux: get SIGTERM when sclang goes away so the tracker never lingers."""
    try:
        ctypes.CDLL("libc.so.6").prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
    except Exception:
        pass


class Runner:
    def __init__(self, tracker: Tracker, source, output: OscOutput | None, control_port: int | None = None,
                 parent_pid: int | None = None, max_backlog_hops: int = 8, verbose: bool = False):
        self.tracker, self.source, self.out = tracker, source, output
        self.cfg = tracker.cfg
        self.parent_pid = parent_pid
        self.max_backlog = max_backlog_hops
        self.verbose = verbose
        self.running = True
        self.paused = False
        self._was_paused = False
        self.frames = self.dropped = 0
        self.control = None
        if control_port:
            self.control = ControlServer(control_port, {
                "/polytracker/set": self._on_set,
                "/polytracker/reset": self._on_reset,
                "/polytracker/quit": self._on_quit,
            })

    # ---- control messages
    def _on_set(self, name, value=None, *_):
        name = re.sub(r"(?<!^)(?=[A-Z])", "_", str(name)).lower()  # sclang sends camelCase: monoMode -> mono_mode
        if name == "mono_mode":
            if value not in MONO_MODES:
                print(f"[polytracker] mono_mode must be one of {MONO_MODES}, got {value!r}", flush=True)
            elif self.out is not None:
                self.out.mono_mode = value
        elif name == "refine":
            self.tracker.dec.p.refine = bool(int(value))
        elif name == "pause":
            self.paused = bool(int(value))
        elif name in SETTABLE:
            setattr(self.tracker.dec.p, SETTABLE[name], float(value))
        else:
            print(f"[polytracker] unknown setting {name!r}; known: {sorted(SETTABLE) + ['mono_mode', 'refine', 'pause']}", flush=True)

    def _on_reset(self, *_):
        self.tracker.dec.reset()
        if self.out:
            self.out.clear()

    def _on_quit(self, *_):
        self.running = False

    def _parent_alive(self) -> bool:
        if not self.parent_pid:
            return True
        try:
            os.kill(self.parent_pid, 0)
            return os.getppid() == self.parent_pid or os.getppid() != 1
        except ProcessLookupError:
            return False

    # ---- main loop
    def run(self):
        cfg, tr = self.cfg, self.tracker
        hop, H, sr = cfg.hop, cfg.history, cfg.sample_rate
        cap = H + hop * 64 + 8192
        buf = np.zeros(cap, dtype=np.float32)
        fill, base = H, -H  # buf[0] is absolute sample `base`; the first H samples are leading silence
        total = 0
        next_end = hop
        busy = 0.0
        worst = 0.0
        last_stats = last_parent = t_start = time.perf_counter()
        frames_at_stats = 0
        gc.collect()
        gc.freeze()
        gc.set_threshold(200_000, 50, 50)
        if self.control:
            self.control.start()
        self.source.start()
        if self.out:
            self.out.hello(str(self.tracker.model.meta.get("name", "polytracker")))
        print(f"[polytracker] running: {sr} Hz, hop {hop} ({1000 * hop / sr:.1f} ms), "
              f"history {H}, voices {tr.dec.p.max_voices}", flush=True)
        try:
            while self.running and not getattr(self.source, "shutdown", False):
                finishing = getattr(self.source, "done", False)  # sampled before reading: nothing can be lost
                self.source.wait(0.05)
                new = self.source.read_available()
                if new.size:
                    if fill + new.size > cap:
                        keep = H + hop * 16
                        buf[:keep] = buf[fill - keep:fill]
                        base += fill - keep
                        fill = keep
                    buf[fill:fill + new.size] = new[: cap - fill]
                    fill += min(new.size, cap - fill)
                    total += new.size
                    if total - next_end >= self.max_backlog * hop and not self.paused:  # fell behind: jump to the newest frame
                        skip = (total - next_end) // hop
                        self.dropped += skip
                        next_end += skip * hop
                if self.paused:  # idle: keep draining audio, but spend no CPU on analysis
                    if not self._was_paused:
                        tr.dec.reset()
                        if self.out:
                            self.out.clear()
                        self._was_paused = True
                    next_end = (total // hop + 1) * hop
                else:
                    self._was_paused = False
                while next_end <= total and not self.paused:
                    lo = next_end - base - H
                    hist = buf[lo:lo + H]
                    t0 = time.perf_counter()
                    events = tr.process(hist, next_end / sr)
                    if self.out:
                        self.out.send_block(tr.dec.voices())
                        if events:
                            self.out.send_events(events)
                    dt = time.perf_counter() - t0
                    busy += dt
                    worst = max(worst, dt)
                    self.frames += 1
                    next_end += hop
                    if self.verbose:
                        for e in events:
                            print(f"{e.t:9.3f} {e.kind:3s} v{e.voice} midi {e.pitch} {e.freq:7.2f} Hz amp {e.amp:.2f}", flush=True)
                now = time.perf_counter()
                if now - last_stats >= 1.0:
                    load = busy / (now - last_stats)
                    if self.out:
                        self.out.send_stats(load, self.frames, self.dropped, worst * 1e3)
                    if self.verbose:
                        print(f"[polytracker] load {100 * load:.1f}%  worst {worst * 1e3:.2f} ms  frames {self.frames} "
                              f"dropped {self.dropped} xruns {getattr(self.source, 'xruns', 0)}", flush=True)
                    last_stats, busy, worst = now, 0.0, 0.0
                if now - last_parent >= 1.0:
                    last_parent = now
                    if not self._parent_alive():
                        print("[polytracker] parent process gone, exiting", flush=True)
                        break
                if finishing and next_end > total:
                    break
        finally:
            if self.out:
                self.out.clear()
            if self.control:
                self.control.stop()
            self.source.stop()
