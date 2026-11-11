"""Command line: ``python -m polytracker {run,wav,bench,info} ...``"""
from __future__ import annotations

import argparse
import json
import sys
import time

import numpy as np

from .decoder import DecoderParams
from .engine import DEFAULT_MODEL, Tracker
from .net import PitchNetNP
from .outputs import MONO_MODES, OscOutput
from .realtime import Runner, die_with_parent, set_realtime


def _hostport(s: str, default_host="127.0.0.1"):
    if ":" in s:
        h, p = s.rsplit(":", 1)
        return h or default_host, int(p)
    return default_host, int(s)


def _add_decoder_args(ap):
    g = ap.add_argument_group("note decoding")
    d = DecoderParams()
    g.add_argument("--on", type=float, default=d.on_thresh, help="frame probability that starts a note")
    g.add_argument("--off", type=float, default=d.off_thresh, help="frame probability below which a note ends")
    g.add_argument("--onset", type=float, default=d.onset_thresh, help="onset-head probability that signals a pick")
    g.add_argument("--gate-db", type=float, default=d.gate_db, help="silence gate on the 85 ms RMS level (dBFS)")
    g.add_argument("--voices", type=int, default=d.max_voices)
    g.add_argument("--no-refine", action="store_true", help="report nominal semitone frequencies only")


def _params(a) -> DecoderParams:
    return DecoderParams(on_thresh=a.on, off_thresh=a.off, onset_thresh=a.onset, gate_db=a.gate_db,
                         max_voices=a.voices, refine=not a.no_refine)


def cmd_run(a):
    die_with_parent()
    from .audio import JackSource

    src = JackSource(a.input, a.client_name)
    tracker = Tracker.load(a.model, params=_params(a), sample_rate=src.sample_rate, hop=a.hop)
    if src.sample_rate != tracker.model.cfg.sample_rate:
        print(f"[polytracker] warning: JACK runs at {src.sample_rate} Hz, model was trained at "
              f"{tracker.model.cfg.sample_rate} Hz (windows are rescaled)", flush=True)
    out = None
    if not a.no_osc:
        if a.bus is None:
            sys.exit("--bus (first control bus of the tracker block) is required unless --no-osc")
        out = OscOutput(_hostport(a.scsynth), _hostport(a.lang), a.bus, a.voices, a.mono_mode)
    set_realtime(a.rt_priority, a.cpu)
    Runner(tracker, src, out, a.control_port, a.parent_pid, verbose=a.verbose).run()


def cmd_wav(a):
    import soundfile as sf

    x, sr = sf.read(a.file, dtype="float32", always_2d=True)
    x = x.mean(axis=1)
    tracker = Tracker.load(a.model, params=_params(a), sample_rate=sr, hop=a.hop)
    if a.realtime:
        from .audio import WavSource

        out = OscOutput(_hostport(a.scsynth), _hostport(a.lang), a.bus, a.voices, a.mono_mode) if a.bus is not None else None
        Runner(tracker, WavSource(x, sr), out, verbose=True).run()
        return
    events = tracker.run_signal(x)
    rows = [{"t": round(e.t, 4), "kind": e.kind, "voice": e.voice, "midi": e.pitch,
             "freq": round(e.freq, 2), "amp": round(e.amp, 3)} for e in events]
    if a.json:
        with open(a.json, "w") as f:
            json.dump(rows, f, indent=1)
    for r in rows:
        print(f"{r['t']:8.3f}  {r['kind']:3s}  voice {r['voice']}  midi {r['midi']:3d}  {r['freq']:8.2f} Hz  amp {r['amp']:.2f}")
    print(f"{sum(r['kind'] == 'on' for r in rows)} notes")


def cmd_bench(a):
    tracker = Tracker.load(a.model, params=_params(a), sample_rate=a.sample_rate, hop=a.hop)
    cfg = tracker.cfg
    rng = np.random.default_rng(0)
    t = np.arange(cfg.sample_rate * 4) / cfg.sample_rate
    x = sum(0.1 * np.sin(2 * np.pi * f * h * t) / h for f in (110.0, 164.8, 220.0, 330.0) for h in range(1, 9))
    x = (x + 0.002 * rng.standard_normal(len(t))).astype(np.float32)
    hist = tracker.fe.pad(x)
    n = (len(x) - cfg.hop) // cfg.hop
    times = []
    for i in range(n):
        end = (i + 1) * cfg.hop
        h = hist[end:end + cfg.history]
        t0 = time.perf_counter()
        tracker.process(h, end / cfg.sample_rate)
        times.append(time.perf_counter() - t0)
    ms = np.array(times[20:]) * 1e3
    budget = 1e3 * cfg.hop / cfg.sample_rate
    print(f"hop {cfg.hop} ({budget:.2f} ms budget): mean {ms.mean():.3f} ms  p50 {np.percentile(ms, 50):.3f}  "
          f"p99 {np.percentile(ms, 99):.3f}  max {ms.max():.3f}  -> {100 * ms.mean() / budget:.1f}% of one core")


def cmd_info(a):
    m = PitchNetNP.load(a.model)
    print(json.dumps({k: v for k, v in m.meta.items() if k != "layers"}, indent=1))
    n = sum(int(np.prod(m.w[i].shape)) + m.b[i].size for i in m.w)
    print(f"parameters: {n:,}")


def main(argv=None):
    ap = argparse.ArgumentParser(prog="polytracker", description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="realtime tracker (JACK in, OSC out)")
    r.add_argument("--input", default="system:capture_1", help="JACK port to listen to")
    r.add_argument("--client-name", default="polytracker")
    r.add_argument("--model", default=str(DEFAULT_MODEL))
    r.add_argument("--hop", type=int, default=None, help="samples between analysis frames (default: model's, 256)")
    r.add_argument("--scsynth", default="127.0.0.1:57110", help="scsynth UDP address (bus writes)")
    r.add_argument("--lang", default="127.0.0.1:57120", help="sclang UDP address (note events)")
    r.add_argument("--bus", type=int, help="index of the first control bus of the tracker block")
    r.add_argument("--control-port", type=int, default=57150, help="UDP port for /polytracker/set etc.")
    r.add_argument("--mono-mode", default="latest", choices=MONO_MODES)
    r.add_argument("--no-osc", action="store_true")
    r.add_argument("--cpu", type=int, default=None, help="pin the tracker to this CPU core")
    r.add_argument("--rt-priority", type=int, default=50, help="SCHED_FIFO priority (0 = off)")
    r.add_argument("--parent-pid", type=int, default=None, help="exit when this process disappears")
    r.add_argument("-v", "--verbose", action="store_true")
    _add_decoder_args(r)
    r.set_defaults(fn=cmd_run)

    w = sub.add_parser("wav", help="track a WAV file")
    w.add_argument("file")
    w.add_argument("--model", default=str(DEFAULT_MODEL))
    w.add_argument("--hop", type=int, default=None)
    w.add_argument("--json")
    w.add_argument("--realtime", action="store_true", help="play the file through the realtime loop")
    w.add_argument("--scsynth", default="127.0.0.1:57110")
    w.add_argument("--lang", default="127.0.0.1:57120")
    w.add_argument("--bus", type=int)
    w.add_argument("--mono-mode", default="latest", choices=MONO_MODES)
    _add_decoder_args(w)
    w.set_defaults(fn=cmd_wav)

    b = sub.add_parser("bench", help="per-frame CPU cost on this machine")
    b.add_argument("--model", default=str(DEFAULT_MODEL))
    b.add_argument("--hop", type=int, default=None)
    b.add_argument("--sample-rate", type=int, default=48000)
    _add_decoder_args(b)
    b.set_defaults(fn=cmd_bench)

    i = sub.add_parser("info", help="show model metadata")
    i.add_argument("--model", default=str(DEFAULT_MODEL))
    i.set_defaults(fn=cmd_info)

    a = ap.parse_args(argv)
    a.fn(a)


if __name__ == "__main__":
    main()
