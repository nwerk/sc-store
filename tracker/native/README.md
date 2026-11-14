# Native tracker (C++)

A C++ port of the realtime path of `polytracker`: frontend, network, decoder, JACK input and OSC output. Same
command line, same OSC messages, same notes as `python -m polytracker run`, at about a third of the CPU on the
laptop. `classes/inputtracker.scd` starts it instead of the Python tracker as soon as it is built
(`engine: \auto`; `\python` forces the Python one).

Training, evaluation and the `wav` command stay in Python. Only `run`, `bench` and an offline `frames` mode
(for the tests) exist here.

## Build

Needs only a C++17 compiler, no libraries: JACK is loaded at runtime (`libjack.so.0`, which every JACK
installation has), and the model is read from `models/guitar_v1.ptm`, which is committed.

```bash
make -C tracker/native            # -> tracker/native/build/polytracker  (about 10 s on a Pi 4)
tracker/native/build/polytracker bench
```

On the Pi, build on the Pi itself (`-mcpu=native` targets its CPU). If `g++` is missing:
`sudo apt install g++ make`, which needs internet once. `make` writes the binary under a temporary name and
renames it, so a power loss during the build never leaves a broken binary behind.

After training or fine-tuning a model, export it for the native tracker:

```bash
cd tracker && .venv/bin/python native/export_model.py models/mine.npz    # -> models/mine.ptm
```

## Commands

```bash
build/polytracker run --input system:capture_1 --bus 130 ...   # what sclang starts; same options as Python
build/polytracker bench [--hop 256|512] [--seconds 4]           # per-frame cost on this machine
build/polytracker frames in.f32 [--hop 256] [--probs p.f32]     # offline run of raw float32 mono audio
```

Unknown options are an error, like in the Python CLI.

## Tests

```bash
cd tracker && .venv/bin/python native/tests/compare.py
```

Runs Python and native frame by frame over a synthetic performance (single notes, a six-string chord, a bend,
vibrato, a repeated note, a noise burst, hiss) at hop 256 and 512, with 4 voices, without refinement, at
44.1 kHz and on silence. It compares the network input, the network output, every note event and the voice
frequencies and amplitudes. Note decisions must be identical. The numbers differ only by float32 rounding
(features < 2e-4, probabilities < 1e-5).

## Measured

Same machine, same benchmark (six voices sounding), mean per frame:

| machine | Python | native |
|---|---|---|
| laptop (i9-13900H, performance core) | 2.8 ms | 0.85 ms |
| Raspberry Pi 4 | 7.1 ms | not measured yet: run `bench` |

On the laptop, the network went from 1.0 ms (numpy) to 0.56 ms, and the frontend from 1.1 ms to 0.27 ms. The
decoder went from 0.6 ms to under 0.01 ms; in Python it was mostly interpreter overhead.

## Layout

| file | port of |
|---|---|
| `src/model.*` | `config.py`, `net.py` (register-blocked GEMM, GCC vector types: AVX on x86, NEON on ARM) |
| `src/fft.h` | numpy's `rfft`/`irfft` (radix 2; Bluestein for the non-power-of-two windows at other sample rates) |
| `src/frontend.*` | `frontend.py` |
| `src/decoder.*` | `decoder.py`, `refine.py` |
| `src/tracker.h` | `engine.py` (incl. the reuse of the short spectrum from `delta` samples back) |
| `src/jack_source.h` | `audio.py` (`JackSource`) |
| `src/osc.h` | `oscmini.py` |
| `src/main.cpp` | `__main__.py`, `realtime.py`, `outputs.py`, `perf.py` |

When the Python tracker changes, port the change here too and run `compare.py`.
