# SC-Store — Copilot Project Instructions

## Project Overview

SC-Store is a **SuperCollider** audio synthesis and effects project designed for
live performance on embedded Linux (Raspberry Pi with pisound HAT). It provides
real-time synthesizers and audio effects controlled via MIDI hardware.

## Technology Stack

- **Language:** SuperCollider (`sclang` / `.scd` files); the pitch tracker additionally needs Python (`tracker/`)
- **Audio Server:** `scsynth` (SuperCollider server)
- **Target Platform:** Linux (Raspberry Pi + pisound HAT), with Windows fallback
- **MIDI Hardware:** MIDI Mix controller, FS-1-WL USB-MIDI footswitch
- **No SuperCollider plugins/Quarks** — all audio synthesis is native SuperCollider. The only external
  process is the polyphonic pitch tracker (`tracker/`: Python with numpy + JACK-Client, or its C++ port in
  `tracker/native/`, used when built), started from `inputtracker.scd`

## Repository Structure

```
sc-store/
├── main.scd              # Scramble FFT effect patch
├── main_sustain.scd      # Bouncing ball physical-modeling synth
├── main_tape.scd         # Tape emulation effect patch
├── classes/              # Shared SuperCollider classes
│   ├── inputtracker.scd  # Polyphonic ML pitch tracker bridge (~polyTrackerNew) + onset/amp SynthDef
│   ├── master.scd        # Master output volume control
│   └── pluckpos.scd      # Picking position (bridge / neck) from the guitar's brightness, for cembalo + tape synth
├── tracker/              # Polyphonic guitar pitch tracker (Python, see tracker/README.md)
├── ui/                   # TouchOSC layout (main.tosc) + its version stamp / manifest (see ui/README.md)
├── config/
│   └── serversetup.scd   # Platform-specific audio server config
├── launchers/
│   └── run-sc.sh         # Generic sclang launcher
├── midi/
│   ├── midiconfig.scd    # MIDI device init + CC bus management
│   └── mappings/         # Per-patch MIDI CC parameter mappings
├── synths/               # SynthDef definitions
│   ├── bouncing_ball.scd # Physical-modeling bouncing ball synth
│   ├── scramble.scd      # FFT bin scramble effect
│   ├── fft_prism.scd     # Spectral feedback effect after the grains (main_multi.scd; core UGens only)
│   └── tapeemulate.scd   # Tape saturation + reverb effect
├── run-sc-main_tape.sh   # Production launcher (tape patch)
└── run_main_bounce-sc.sh # Production launcher (bouncing ball)
```

## Architecture & Conventions

### Signal Flow

1. **Audio Input** → line-in microphone or instrument
2. **Pitch Tracking** (`inputtracker.scd` + `tracker/`) → per-voice frequency/amplitude/gate buses (6 voices),
   mono frequency/amplitude, transient trigger; note on/off events as OSC to sclang
3. **Synthesis / Effects** → one of three modes (scramble, bouncing ball, tape)
4. **Master Output** (`master.scd`) → stereo audio out

### Bus Architecture

- **CC Bus** (128 channels): all MIDI CC parameters, shared across patches
- **Frequency / Amplitude Buses**: pitch tracker mono outputs consumed by synths (`freqBus`, `ampBus`, `lagAmpBus`, `trigBus`)
- **Tracker block** (22 control buses, allocated by `~polyTrackerNew`): written by the Python tracker via `/c_setn`;
  layout documented at the top of `classes/inputtracker.scd` and in `tracker/polytracker/outputs.py` — keep both in sync
- **Audio Buses**: inter-synth signal routing (e.g., `bouncingBallBus`)

### Key Coding Conventions

- **SynthDef naming**: lowercase with camelCase (e.g., `\bouncingBallSmooth`, `\polyTracker`; `\tartiniTracker_sigmundStyle` is kept as a legacy alias)
- **MIDI mapping files**: one per patch, placed in `midi/mappings/`, named `<patch>_midi.scd`
- **Main patches** load dependencies via relative paths:
  ```supercollider
  ("config/serversetup.scd").loadRelative;
  ("midi/mappings/<patch>_midi.scd").loadRelative;
  ("midi/midiconfig.scd").loadRelative;
  ("synths/<synth>.scd").loadRelative;
  ```
- **CC values** are normalized to `0–1` range for continuous controls
- **Latching CCs** toggle on value `127` (for footswitch triggers)
- **Server boot** happens inside `s.waitForBoot { ... }` blocks
- **Platform detection**: `Platform.case` with `\linux` and `\windows` branches in server config

### What NOT to Do

- Do not introduce external plugins or Quarks without explicit approval
- Do not hardcode absolute paths in `.scd` files — use `loadRelative` and bus references
- Do not change the CC bus size (128 channels) without updating all mapping files
- Do not modify `serversetup.scd` platform branches without testing on both platforms
- Do not remove or rename existing SynthDef names as they may be referenced by external systems
