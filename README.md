# SC-Store

SC-Store is a collection of SuperCollider patches for live audio performance. It
combines real-time audio synthesis and effects with MIDI control, and is designed
primarily for Linux systems such as a Raspberry Pi with a pisound HAT. A Windows
audio-server configuration is also included.

## Patches

Each top-level `.scd` file is a standalone entry point:

| File | What it does |
| --- | --- |
| `main.scd` | Applies an FFT bin-scrambling effect to audio input. |
| `main_sustain.scd` | Runs a bouncing-ball physical-modeling synth. It tracks input pitch and uses a MIDI trigger to start bouncing sounds tuned to that pitch. |
| `main_tape.scd` | Runs a pitch-responsive synth patch with MIDI-controlled timbre and reverb. |

The patches share MIDI CC infrastructure, while the pitch-tracking patch uses
Tartini for pitch and amplitude analysis and Onsets for transient detection.

## Requirements

- SuperCollider, including `sclang` and `scsynth`
- An audio input source connected to input channel 0
- A MIDI controller for MIDI-controlled parameters and triggers
- The audio device and driver configured for your system

The included server configuration sets a 48 kHz sample rate. On Linux it selects
the `JackDriver`; on Windows it selects `Focusrite USB ASIO`. Change
`config/serversetup.scd` if your device setup differs.

MIDI setup currently searches for devices named `MIDI Mix` and
`FS-1-WL USB-MIDI`. MIDI CC assignments are defined separately for each patch
under `midi/mappings/`.

## Running

From the repository directory, start a patch with `sclang`:

```sh
sclang main.scd
```

Use `main_sustain.scd` for the bouncing-ball synth, or `main_tape.scd` for the
pitch-responsive synth patch. The scripts configure and boot the audio server
when run.

The scripts in `launchers/` and at the repository root are intended for a
specific Raspberry Pi installation: they use `/usr/local` paths and pisound
utilities. The bouncing-ball launcher currently references `main_bounce.scd`,
which is not present in this repository; run `sclang main_sustain.scd` directly
or update that launcher's path for your installation.

## Repository layout

```text
.
├── main.scd                    # FFT scramble patch
├── main_sustain.scd             # Bouncing-ball patch
├── main_tape.scd                # Pitch-responsive synth patch
├── classes/
│   ├── inputtracker.scd         # Pitch, amplitude, and onset tracking
│   └── master.scd               # Shared master-volume SynthDef
├── config/
│   └── serversetup.scd          # Linux and Windows audio-server settings
├── launchers/
│   └── run-sc.sh                # Raspberry Pi launcher
├── midi/
│   ├── midiconfig.scd           # MIDI connections and CC handling
│   └── mappings/                # Per-patch CC names and assignments
└── synths/                      # SynthDefs used by the patches
```
