# Native tracker (C++)

A C++ port of the realtime path of `polytracker`: frontend, network, decoder, JACK input and OSC output. Same
command line, same OSC messages, same notes as `python -m polytracker run`, at about a fifth of the CPU on the
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
| laptop (i9-13900H, performance core, on battery) | 2.8 ms | 0.59 ms |
| Raspberry Pi 4 (32-bit OS, 1.8 GHz) | 7.1 ms | 1.67 ms (network 1.28, frontend 0.38, decoder 0.01) |

The laptop numbers were taken on battery in its power-saving profile (the core runs at well under 1 GHz then), so
they compare Python and native on one machine and say little about another one.

On the laptop, the network went from 1.0 ms (numpy) to 0.46 ms, and the frontend from 1.1 ms to 0.11 ms. The
decoder went from 0.6 ms to under 0.01 ms; in Python it was mostly interpreter overhead.

Where the time goes now, and what was done about it:

- Network (0.46 ms, 4.35 million multiply-adds per frame): the convolutions read the zero-padded input in place
  instead of copying it into an im2col matrix first. Per layer the input (20 kB) and one block of weights (6 kB)
  then fit the Pi 4's 32 kB L1 cache. The inner loop is within about 1.5x of what two multiply-add units can do,
  so what is left here is the size of the model.
- FFTs (four per frame, 0.07 ms): radix 4 on separate real and imaginary arrays, bit-reversal folded into the first
  pass, the real-FFT pre/post-processing done for bins k and n/2 - k together. A 4096-point transform went from
  54 to 21 microseconds.
- Rest of the frontend (0.04 ms): the triangular filters are contiguous dot products, the harmonic stacks are
  copied instead of gathered, the level sums use eight partial sums.

A live run costs more per frame than `bench`, which runs frames back to back: between two frames the thread sleeps,
and a CPU that scales its clock with the load slows down meanwhile (laptop: 17 % live against 12 % in `bench` at
hop 256). On the Pi, `run-sc-main_multi.sh` therefore sets the `performance` governor.

## 32-bit ARM (Raspberry Pi OS / Patchbox OS armhf)

GCC turns float vector arithmetic into NEON instructions on 32-bit ARM only with `-funsafe-math-optimizations`
(ARMv7 NEON flushes denormals to zero, which is not IEEE). Without it, every vector operation of the network and
the FFT is split into scalar ones with lane shuffles: the first Pi 4 measurement was 11.3 ms per frame, slower
than numpy. The Makefile therefore compiles `model.cpp` and `frontend.cpp` with that flag on `armv7l`/`armv8l`
(not the decoder, whose note decisions stay in plain IEEE arithmetic) and adds `-Wvector-operation-performance`,
so any vector code that is still split up shows as a warning during `make`.

`bench` and `run` print what the binary was built for, e.g. `native (C++, ARMv7 NEON)`; a build that would be
slow says so there. `bench` also prints the time per frame of frontend, network and decoder.

Pi 4 (32-bit OS, 1.8 GHz, `taskset -c 3`, patch stopped), mean time per frame:

| build | per frame | hop 256 |
|---|---|---|
| vector code compiled as scalar (no `-funsafe-math-optimizations`) | 11.3 ms | 213 % |
| NEON, generic vector code | 3.5 ms | 66 % (auto picks hop 512) |
| NEON, lane kernel for the network | 1.67 ms | 31 %, p99 35 % (auto picks hop 256) |

The convolution kernel on 32-bit ARM is written with NEON intrinsics: ARMv7 NEON has no fused multiply-add by a
lane, so from the generic vector code GCC copies each weight into a full register before every multiply-add.
`vmlaq_lane_f32` takes the weight straight from a lane. The kernel can be checked for correctness on x86, where
`tests/neon_shim.h` provides those intrinsics:

```bash
make clean && make SIMDFLAGS=-DPT_NEON_SHIM && cd .. && .venv/bin/python native/tests/compare.py
make -C native clean && make -C native     # back to the normal build
``` On x86 the same flag changes only rounding: `compare.py` still matches (features within
7e-5, probabilities within 3e-6).

## Realtime priority

The analysis thread asks for SCHED_FIFO (`--rt-priority`, default 50) so that ordinary processes cannot delay it.
It never runs above JACK's audio threads: if the requested priority is not below the one JACK gives its clients
(`jack_client_real_time_priority`; scsynth's audio thread has the same), it is lowered to one below it and a
line says so. A late pitch frame is inaudible, a late audio block is a dropout. `jackd` started without `-P` runs
at priority 10, so there the tracker ends up at 9.

## Layout

| file | port of |
|---|---|
| `src/model.*` | `config.py`, `net.py` (register-blocked convolution, GCC vector types: AVX on x86, NEON on ARM) |
| `src/fft.h` | numpy's `rfft`/`irfft` (radix 4; Bluestein for the non-power-of-two windows at other sample rates) |
| `src/frontend.*` | `frontend.py` |
| `src/decoder.*` | `decoder.py`, `refine.py` |
| `src/tracker.h` | `engine.py` (incl. the reuse of the short spectrum from `delta` samples back) |
| `src/jack_source.h` | `audio.py` (`JackSource`) |
| `src/osc.h` | `oscmini.py` |
| `src/main.cpp` | `__main__.py`, `realtime.py`, `outputs.py`, `perf.py` |

When the Python tracker changes, port the change here too and run `compare.py`.
