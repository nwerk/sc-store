"""Command line: ``python -m polytracker {run,wav,bench,info} ...``"""
from __future__ import annotations

import argparse
import json
import sys

import numpy as np

from .decoder import DecoderParams
from .engine import DEFAULT_MODEL, Tracker
from .net import PitchNetNP
from .outputs import MONO_MODES, OscOutput
from .perf import blas_warning, choose_hop, measure, summary
from .realtime import Runner, die_with_parent, jack_rt_priority, set_realtime


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
    g.add_argument("--confirm-ms", type=float, default=d.on_confirm_ms,
                   help="frame probability must hold this long before a note starts without an onset")
    g.add_argument("--correct-ms", type=float, default=d.correct_ms,
                   help="a note's pitch may be corrected this long after its start (0 = off, 60 = tuned)")
    g.add_argument("--correct-span", type=int, default=d.correct_span,
                   help="neighbours up to this many semitones may replace a provisional note (plus 19 and 24)")
    g.add_argument("--correct-drop", type=float, default=d.correct_drop,
                   help="a provisional note is replaced only once its frame probability is below this")
    g.add_argument("--voices", type=int, default=d.max_voices)
    g.add_argument("--no-refine", action="store_true", help="report nominal semitone frequencies only")


def _hop(s: str):
    if s == "auto":
        return s
    try:
        return int(s)
    except ValueError:
        raise argparse.ArgumentTypeError("--hop takes a number of samples or 'auto'")


def _params(a) -> DecoderParams:
    return DecoderParams(on_thresh=a.on, off_thresh=a.off, onset_thresh=a.onset, gate_db=a.gate_db,
                         on_confirm_ms=a.confirm_ms, correct_ms=a.correct_ms, correct_span=a.correct_span,
                         correct_drop=a.correct_drop, max_voices=a.voices, refine=not a.no_refine)


def cmd_run(a):
    die_with_parent()
    from .audio import JackSource

    src = JackSource(a.input, a.client_name)
    w = blas_warning()
    if w:
        print(f"[polytracker] warning: {w}", flush=True)
    set_realtime(a.rt_priority, a.cpu, jack_rt_priority(src.client))  # before measuring, so the choice reflects the real scheduling
    model = PitchNetNP.load(a.model)
    load = lambda hop: Tracker(model, params=_params(a), sample_rate=src.sample_rate, hop=hop)
    tracker = choose_hop(load, log=lambda m: print(m, flush=True)) if a.hop == "auto" else load(a.hop)
    if src.sample_rate != tracker.model.cfg.sample_rate:
        print(f"[polytracker] warning: JACK runs at {src.sample_rate} Hz, model was trained at "
              f"{tracker.model.cfg.sample_rate} Hz (windows are rescaled)", flush=True)
    out = None
    if not a.no_osc:
        if a.bus is None:
            sys.exit("--bus (first control bus of the tracker block) is required unless --no-osc")
        out = OscOutput(_hostport(a.scsynth), _hostport(a.lang), a.bus, a.voices, a.mono_mode)
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
    print(f"numpy {np.__version__}")
    w = blas_warning()
    if w:
        print(f"warning: {w}")
    model = PitchNetNP.load(a.model)
    for hop in ([a.hop] if a.hop else [256, 512]):
        tracker = Tracker(model, params=_params(a), sample_rate=a.sample_rate, hop=hop)
        print(summary(tracker, measure(tracker, a.seconds)))
    print("(six voices sounding; `run --hop auto` picks the smallest hop with mean <= 45% and p99 <= 80% of it)")


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
    r.add_argument("--hop", type=_hop, default="auto",
                   help="samples between analysis frames: 256 (5.3 ms), 512, or 'auto' (default: measure this "
                        "machine at startup and take 256 if it keeps up comfortably, else 512)")
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
    b.add_argument("--hop", type=int, default=None, help="default: measure 256 and 512")
    b.add_argument("--sample-rate", type=int, default=48000)
    b.add_argument("--seconds", type=float, default=4.0, help="length of the test signal")
    _add_decoder_args(b)
    b.set_defaults(fn=cmd_bench)

    i = sub.add_parser("info", help="show model metadata")
    i.add_argument("--model", default=str(DEFAULT_MODEL))
    i.set_defaults(fn=cmd_info)

    a = ap.parse_args(argv)
    try:
        a.fn(a)
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
