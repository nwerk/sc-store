"""Play a WAV file into a JACK output port (loops). Handy to test the tracker without a guitar.

    python scripts/jack_play.py song.wav --name guitar_sim --connect polytracker:in
"""
import argparse
import sys
import threading

import jack
import numpy as np
import soundfile as sf


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("--name", default="guitar_sim")
    ap.add_argument("--connect", action="append", default=[], help="input port(s) to connect to (repeatable)")
    ap.add_argument("--once", action="store_true", help="play once and exit instead of looping")
    ap.add_argument("--gain", type=float, default=1.0)
    a = ap.parse_args()

    client = jack.Client(a.name, no_start_server=True)
    x, sr = sf.read(a.file, dtype="float32", always_2d=True)
    x = x.mean(axis=1) * a.gain
    if sr != client.samplerate:
        from scipy.signal import resample_poly

        g = np.gcd(sr, client.samplerate)
        x = resample_poly(x, client.samplerate // g, sr // g).astype(np.float32)
    out = client.outports.register("out")
    pos = [0]
    done = threading.Event()

    @client.set_process_callback
    def process(frames):
        buf = out.get_buffer()
        n = len(x)
        i = pos[0]
        buf_np = np.frombuffer(buf, dtype=np.float32)
        chunk = x[i:i + frames]
        buf_np[:len(chunk)] = chunk
        if len(chunk) < frames:
            buf_np[len(chunk):] = 0.0
            if a.once:
                done.set()
            else:
                rest = frames - len(chunk)
                buf_np[len(chunk):] = x[:rest]
                pos[0] = rest
                return
        pos[0] = (i + frames) % n if not a.once else i + frames

    with client:
        for p in a.connect:
            client.connect(out, p)
        print(f"playing {a.file} on {a.name}:out ({len(x) / client.samplerate:.1f} s)", file=sys.stderr)
        try:
            done.wait() if a.once else threading.Event().wait()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
