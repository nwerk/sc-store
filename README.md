# SC-Store

SC-Store is a collection of SuperCollider instruments and effects for live
audio performance. Its patches route microphone or instrument input through
real-time synthesis and effects, with parameters controlled by MIDI hardware
and, for the granular patches, TouchOSC over OSC. The project includes a
granular looper, FFT processing, a pitch-responsive tape effect, a bouncing
ball physical-modeling synth, and an FFT-bin scramble effect.

## Patches

Each `main*.scd` file is a standalone patch entry point:

| File | What it runs |
| --- | --- |
| `main_multi.scd` | Combined granular/FFT and pitch-tracked tape setup, controlled through TouchOSC and a Boss FS-1-WL footswitch. The grain chain starts enabled; tape starts disabled. |
| `main_grain.scd` | Granular looper with FFT processing and TouchOSC control. |
| `main_tape.scd` | Pitch-tracked tape emulation effect. |
| `main_sustain.scd` | Pitch-tracked bouncing-ball synth, triggered by MIDI. |
| `main.scd` | FFT-bin scramble effect. |

The granular patches capture audio into a buffer and generate grains from it.
They provide live recording, buffer management, and controls for grain density,
duration, playback position, pitch, and related effects. `main_multi.scd`
combines this chain with the tape effect and offers synth selection and
TouchOSC state feedback.

## Requirements

- SuperCollider, including `sclang` and the `scsynth` audio server.
- An audio input and output configured for the patch you want to run.
- On Linux, the shared server configuration expects JACK (`JackDriver`) at
  48 kHz. The Windows branch is configured for a Focusrite USB ASIO device at
  48 kHz; adjust `config/serversetup.scd` if your audio device differs.
- MIDI hardware is needed for MIDI-triggered controls. TouchOSC is used for the
  OSC interface in the granular patches; set its destination address in the
  relevant `osc/oscconfig*.scd` file for your network.

The shell launchers target the project's embedded Pisound installation and
expect its system utilities and install paths. To run from another setup,
launch a patch directly with SuperCollider instead.

## Run a patch

From the repository directory, run the desired entry point with `sclang`, for
example:

```sh
sclang main_multi.scd
```

Use a different `main*.scd` filename to start another patch. Each entry point
loads its configuration and synthesis files relative to its own location.

## Repository layout

- `main*.scd` — patch entry points that configure and start a signal chain.
- `synths/` — granular, FFT, tape, scramble, and bouncing-ball SynthDefs.
- `classes/` — shared pitch/onset tracking and master-output SynthDefs.
- `config/` — platform-specific audio-server settings.
- `midi/` — MIDI setup and per-patch parameter mappings.
- `osc/` — OSC mappings, TouchOSC integration, and granular-patch presets.
- `launchers/` and `run-*.sh` — boot, button, and patch launch scripts for the
  embedded setup.

## Signal flow and controls

The patches allocate SuperCollider audio and control buses when the server
boots, then connect synths in signal-flow order. Shared components include a
Tartini-based pitch tracker, amplitude/onset tracking where needed, and master
output control. MIDI Continuous Controller (CC) values drive patch parameters;
the granular OSC interface provides faders, toggles, buffer and preset
management, and multi-touch grain control.
