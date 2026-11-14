# Polyphonic guitar pitch tracker

Replaces the Tartini-based `inputtracker.scd`. A small neural network (74 k parameters, 279 KB, pure numpy
at inference time) tracks up to **6 simultaneous notes** from a mono guitar signal and delivers them to
SuperCollider as note on/off events **and** as control buses. The mono `freqBus` / `ampBus` / `lagAmpBus` /
`trigBus` that the existing patches consume are still provided.

```
guitar ──► JACK ──┬─► scsynth ─ \polyTracker (amp, onsets, mono smoothing) ─► freqBus / ampBus / lagAmpBus / trigBus
                  │                  ▲ In.kr(block)
                  └─► polytracker (Python, own JACK client)
                        frontend (FFT features) ─► PitchNet (numpy) ─► decoder (hysteresis, onsets, voices)
                                                                      └► pitch refinement (cents)
                        ├── /c_setn  ─────────────► scsynth: 22 control buses (per-voice freq/amp/gate, mono)
                        └── /polytracker/noteOn|noteOff|stats|ready ─► sclang
```

sclang is never in the audio path: the tracker writes into scsynth's control buses directly over UDP.

## Use it from SuperCollider

```supercollider
("classes/inputtracker.scd").loadRelative;
s.waitForBoot {
    ~freqBus = Bus.control(s, 1);  ~ampBus = Bus.control(s, 1);
    ~tracker = ~polyTrackerNew.(s, (inChan: 0, freqBus: ~freqBus, ampBus: ~ampBus)).start;
    ~tracker.onNoteOn  = { |voice, midi, freq, amp| ... };
    ~tracker.onNoteOff = { |voice, midi| ... };
    // in a SynthDef:  In.kr(~tracker.voiceFreqBus.index, 6)   voiceAmpBus / voiceGateBus likewise
};
~tracker.set(\monoMode, \lowest);   // latest (default) | lowest | highest | loudest
~tracker.set(\on, 0.8);             // decoder thresholds at runtime: on, off, onset, gate_db, retrigger_ms, ...
~tracker.run(false);                // pause (also stops the Python analysis => 0 % CPU); run(true) resumes
~tracker.quit;                      // NOT .stop (Object:stop exists and does nothing)
```

`~polyTrackerNew` options (all optional): `inChan`, `freqBus`/`ampBus`/`lagAmpBus`/`trigBus` (Bus objects, else
allocated), `target`/`addAction`, `synthArgs` (extra `\polyTracker` args such as `[\holdLast, 1]`), `jackPort`
(default `system:capture_<inChan+1>`), `python`, `model`, `monoMode`, `hop` (`\auto` = default, `256`, `512`),
`cpu` (pin to a core), `rtPriority`,
`decoderArgs` (extra command line, e.g. `"--hop 512 --no-refine"`), `autoLaunch`, `verbose`.
The Python process is started and supervised by sclang (it exits by itself when sclang dies, and when
`~tracker.run(false)` is set it idles). On Windows `autoLaunch` is off: start `python -m polytracker run`
yourself.

Existing patches: `main_tape.scd`, `main_multi.scd` and `main_sustain.scd` use the new tracker. The old
`\tartiniTracker_sigmundStyle` SynthDef name still exists as an alias of `\polyTracker`.

### Bus block (22 control buses, allocated by `~polyTrackerNew`, layout shared with `outputs.py`)

| offset | content |
|---|---|
| 0 | mono frequency in Hz (0 = no note), chosen by `monoMode` |
| 1 | mono amplitude 0..1 |
| 2 | number of sounding notes |
| 3 | heartbeat (changes on every update; `\polyTracker` mutes the mono pitch if it stops) |
| 4–9 | frequency per voice (Hz; keeps the last value after release) |
| 10–15 | amplitude per voice 0..1 |
| 16–21 | gate per voice (0/1) |

Notes are measured in cents (`refine`, on by default) where at least two clean harmonics are visible and fall
back to the nominal semitone frequency otherwise (dense chords).

## Install

```bash
# workstation (inference + training)
./scripts/install.sh --train
# Raspberry Pi: reuse the apt numpy, only add JACK-Client
sudo apt install python3-numpy python3-venv libjack-jackd2-0 libopenblas0-pthread
./scripts/install.sh
.venv/bin/python -m polytracker bench       # per-frame cost on THIS machine
```

`libopenblas0-pthread` matters: Debian's `python3-numpy` is satisfied by the unoptimised reference BLAS
(`libblas3`), on which the network runs several times slower. `install.sh`, `bench` and `run` check which BLAS
numpy loaded and print a warning if it is the reference one.

`.venv/bin/python` inside `tracker/` is picked up automatically by `inputtracker.scd`.

**Native tracker:** `make -C tracker/native` builds a C++ port of the realtime tracker (same notes, about a third
of the CPU, no Python needed at runtime). `inputtracker.scd` uses it automatically once it is built. See
[native/README.md](native/README.md).
For real-time scheduling the user needs an `rtprio` limit (the pisound image already grants this to `@audio`);
without it the tracker still runs, with a warning.

## What was measured

Training data: synthetic guitar performances (`polytracker/train/synth.py`: plucked-string additive model with
inharmonicity, pick/pickup position, string-wise monophony, hammer-ons, bends, vibrato, slides, palm mutes,
dead notes, five tunings, amp/cabinet/room/noise chain) plus **GuitarSet** (Xi et al. 2018, CC BY 4.0;
pickup mix and microphone recordings of players 00–03). Player 04 was used to pick checkpoints and tune the
decoder thresholds; **player 05 was never used for anything but the numbers below** (60 recordings per row,
50 ms onset tolerance, labels at 1 ms resolution). Reproduce with `scripts/train_all.sh` and
`python -m polytracker.train.evaluate --model models/guitar_v1.npz --guitarset data/guitarset --split test`.

| GuitarSet player 05 (unseen) | pickup mix | microphone |
|---|---|---|
| frame precision / recall / F1 | 0.849 / 0.899 / **0.873** | 0.849 / 0.872 / **0.861** |
| onset precision / recall / F1 | 0.729 / 0.783 / **0.755** | 0.689 / 0.734 / **0.711** |
| onset delay after annotated onset, median / 90th pct | 6.2 / 30 ms | 10.9 / 35 ms |
| pitch error of reported frequency, median | 3.9 cents | 4.1 cents |
| frames within 10 / 25 cents | 74 % / 93 % | 74 % / 93 % |

(Player 04, used for tuning: frame F1 0.860 / 0.835, onset F1 0.697 / 0.645.)

Read these numbers with their limits in mind:

* Frame precision can be under-estimated: GuitarSet labels end when the annotator says the note ended, while
  the tracker may keep a string that is still audibly ringing.
* Pitch error is measured against GuitarSet's hexaphonic-pickup contour of the matching string. I did not
  analyse the ~7 % of frames beyond 25 cents in detail; bends, vibrato and slides (which move faster than the
  85 ms analysis window follows) and wrongly matched strings are the likely causes.
* This is a statistical model: dense chords, heavy distortion and sympathetic ringing produce wrong or missing
  notes. It does not reach the accuracy of monophonic pitch trackers on single notes (which have a much easier
  problem); for monophonic playing the pitch within a note is nevertheless refined to a few cents.
* It has not been run on your guitar and signal chain. If a source of errors shows up (wrong octave on the low
  E, ghost notes with a fuzz), record 1–2 minutes, tune with `set(\on, ...)`, and consider fine-tuning (below).

Range: MIDI 38–88 (D2 to E6; drop-D works, lower tunings do not). Two strings sounding the same pitch are one
note.

### Latency

* The decision for a note is made on the frame that ends at most one hop (5.3 ms) after the new audio. Measured
  against GuitarSet's onset labels the median delay is 4–6 ms (pickup) / ~10 ms (mic), 90th percentile ≈ 30 ms
  (soft attacks, strummed chords). The onset head can start a note before the frame head is certain, which is
  where the low median comes from.
* On top come one JACK period of the capture path and ≤ 1.3 ms for scsynth to read the new bus values
  (`blockSize 64`). Transport Python → scsynth is UDP over loopback.
* The pitch value of a held note follows with the 85 ms window (bends/vibrato are smoothed, `glide_alpha`).
* The amplitude and the onset trigger of `\polyTracker` (`Amplitude`, `Onsets`) run inside scsynth with no
  extra latency; use them when you need the fastest possible reaction and the tracker for the pitch.

### CPU

Measured on the development laptop (x86-64, one thread, `python -m polytracker bench`, all six voices sounding):

| hop | budget | mean per frame | p99 | share of one core |
|---|---|---|---|---|
| 256 (default, 5.3 ms) | 5.33 ms | 0.47 ms | 0.67 ms | 9 % |
| 512 (10.7 ms) | 10.67 ms | 0.50 ms | 0.82 ms | 5 % |

Live through JACK with 40 s of synthetic polyphony (up to 4 notes, bends, vibrato): 13–17 % of one core, worst
frame ≤ 3.4 ms, no dropped frames, and the same 203 notes as the offline run. Per frame: frontend ~0.15 ms (two
thirds of it FFTs), network ~0.17 ms, decoder ~0.1 ms with four notes sounding.

The realtime path avoids repeated work without changing a single output value (checked bit for bit against the
previous version on numpy 1.24 and 2.5, and in `tests/test_perf.py`): the short spectrum a frame compares
against for the onset channel is the one computed four frames earlier and is reused, the network's
single-frame path has every buffer and view precomputed and writes each layer straight into the next one's
input, and the decoder handles all voices with array operations instead of per-note Python loops.

**Raspberry Pi 4 numbers were not measured** (no Pi was available during development). A Cortex-A72 core is
several times slower than a laptop core for this kind of numpy code, so expect roughly 30–60 % of the budget at
hop 256. To make sure it fits anyway, `run` uses **`--hop auto`** by default: at startup it measures one second
of six-voice audio at hop 256, keeps it if the mean stays under 45 % and the 99th percentile under 80 % of the
budget, and otherwise switches to hop 512 (half the CPU, at most 5.3 ms more latency). The choice is printed
(`auto hop: ...`). Force a value with `hop: 256` / `hop: 512` in `~polyTrackerNew` or `--hop` on the command
line. If even hop 512 is tight: `--no-refine`, `cpu: 3` (an otherwise idle core), `--voices 4`.
`python -m polytracker run -v` prints the real load every second; the tracker skips ahead instead of falling
behind (`dropped` in the stats).

## Design

* **Frontend** (`frontend.py`, one frame = last 4096 samples): log-frequency spectra at 3 bins/semitone from an
  85 ms window (resolves low strings) and a 21 ms window (fast response), spectral change over 21 ms (onsets),
  and the autocorrelation at the pitch lag. Each of these is gathered as a *harmonic stack* (the first 8
  harmonics of every candidate pitch become 8 channels), so a plain convolution over pitch sees all partials of
  a candidate at once. Asymmetric windows keep the newest samples loudest. No look-ahead: a frame never
  depends on audio after its end (unit tested), so training and live use are identical.
* **Network** (`train/model.py`, `net.py`): fine-grid convs → stride-3 to semitones → 5 residual dilated
  blocks (dilations 1, 12, 7, 5, 12: octave/fifth relations) → two heads per semitone: *frame active* and
  *onset*. BatchNorm is folded into the weights on export; `PitchNetNP.predict_one` is an allocation-free
  single-frame path (~0.2 ms).
* **Decoder** (`decoder.py`): hysteresis (`on`/`off`), confirmation times, onset-triggered start/retrigger with a
  refractory period, voice allocation with stealing of the weakest voice, a silence gate. Everything is
  time-based, not frame-count based.
* **Refiner** (`refine.py`): per note, the long-window spectrum is searched around each of the first harmonics
  (excluding those that coincide with another active note), parabolic interpolation, inharmonicity
  correction, weighted-median agreement of the votes. Costs ~0.025 ms per note and is throttled to every 12 ms.
* **Runtime** (`realtime.py`, `perf.py`): hop chosen by a startup measurement; JACK callback only copies into a ring buffer; analysis runs in its own
  (optionally SCHED_FIFO, pinned) thread of the process; GC is frozen; stats and heartbeats go to sclang once a
  second; SIGTERM when the parent dies.

## Training / improving the model

```bash
./scripts/install.sh --train
./scripts/train_all.sh                 # downloads GuitarSet (1.4 GB), renders data, trains (~45 min, 20 cores)
.venv/bin/python -m polytracker.train.tune_decoder --model models/guitar_v1.npz --guitarset data/guitarset
.venv/bin/python -m pytest tests
```

To adapt to your own instrument, add recordings with note annotations as another source in
`train/data.py` (`GuitarSetSource` shows the pattern) and fine-tune with `--init runs/stageB.pt`.
The frontend settings live in `config.py` and are stored in the model file; changing them requires retraining.

## Command line

```bash
python -m polytracker wav song.wav                 # note list, offline
python -m polytracker wav song.wav --realtime --bus 10     # through the real-time loop, writes to scsynth
python -m polytracker run --input system:capture_1 --bus 10 -v   # what sclang starts (--hop auto by default)
python -m polytracker bench                        # cost per frame at hop 256 and 512, BLAS check
python -m polytracker info
scripts/jack_play.py song.wav --connect polytracker:in     # simulate a guitar on JACK
```

Control messages (UDP, default port 57150): `/polytracker/set name value` (`on off onset gate_db retrigger_ms
on_confirm_ms off_confirm_ms amp_range_db glide_alpha refine mono_mode pause`), `/polytracker/reset`,
`/polytracker/quit`. Events to sclang: `/polytracker/noteOn voice midi freq amp`, `/polytracker/noteOff voice
midi`, `/polytracker/stats load frames dropped worst_ms`, `/polytracker/ready model bus voices`.
