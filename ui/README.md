# TouchOSC layout

`main.tosc` is the layout and the source of truth. `main.xml` is the same layout, readable for diffs, and is generated.

## Versions

A layout's version is the hash of its **OSC contract**: every control's address, type, button type,
send / receive flags and argument ranges. Moving controls or changing colours keeps the version. Changing an
address, adding a control or changing a range gives a new one, so no version numbers are bumped by hand.

After every change to the layout:

```sh
python3 ui/build.py            # stamps main.tosc, regenerates main.xml and ui_manifest.scd
python3 ui/build.py --from-xml # same, when main.xml was edited instead of main.tosc
python3 ui/build.py --check    # change nothing, only report (the pre-commit hook runs this)
```

Commit all three files. Enable the pre-commit hook once per clone with `git config core.hooksPath .githooks`.

## On stage

1. When the layout loads, its root script sends `/ui/hello <version> <build>`. It does the same whenever SC sends `/ui/ping`, which happens at boot.
2. `osc/ui_version.scd` compares the version with `ui_manifest.scd` and answers `/ui/status`. The label
   `uiStatus`, on the heartbeat button, shows `UI cbcbf6d4` in green, or `UI OUTDATED …` in red. On a
   mismatch, the post window also explains it and the pisound LEDs flash three times.
3. A layout from before the versioning never says hello. It is reported as unversioned as soon as it sends
   its first control.
4. At boot, SC also checks that every tablet control has an OSCdef and warns about the ones that don't.

## Grain recorder (bottom left of the grain page)

The grain buffer is a loop of *BufferLen* seconds that the write head runs through all the time.

| Control | What it does |
|---|---|
| **REC** | on: the input is written into the loop. Overdub: *Feedback* sets how much of the old content stays, and the grains follow just behind the write head. off: the loop is kept and keeps playing. |
| status line | `RECORDING` / `LOOP` (holds a recording) / sample name / `EMPTY`, plus the loop length |
| **CLEAR** | empties the loop; REC stays as it is |
| **LOAD SAMPLE** | loads the next file from `samples/` (wav, aif, flac, ogg) and switches REC off, so the sample isn't overwritten right away |

*BufferLen* creates a new, empty loop once the fader has been still for 0.4 s. Loading a preset keeps the
loop unless the preset has a different length.

All on/off buttons are toggle buttons: the tablet sends the new state, and SC sends it back. This keeps the
lights in sync with what the patch does.

## FFT page: the spectral feedback effect

`synths/fft_prism.scd`, after the grains. What enters is heard once, shaped by the lower row of faders, and then
goes round a loop. Every round it is shifted, transposed and delayed.

| Control | What it does |
|---|---|
| **Pad** X | frequency shift per round, middle = none. Small shifts sweep endlessly (barber pole), large ones stack inharmonic echoes that climb (right) or sink (left) |
| **Pad** Y | feedback. The top of the pad sustains for ever; the loop settles at a fixed level instead of growing |
| **FREEZE** | holds the spectrum of the moment as a standing wash. It keeps feeding the loop, so the pad stacks and spirals it |
| *Level* | level of the effect, 0 = dry grains only |
| *Source* | what feeds it: the grains (bottom) or the grain input, i.e. guitar / cembalo / tape as chosen with the IN buttons (top) |
| *Loop Time* | extra delay per round, up to 1.5 s: from a resonance to separate echoes |
| *Warp* | transposition per round in semitones (± one octave, middle = off): +12 climbs in octaves, +7 in fifths |
| *Smear* | blurs neighbouring partials into bands of noise |
| *Sieve* | removes a random part of the partials, differently left and right |
| *Flicker* | how often the sieve picks new partials; bottom = a fixed comb |
| *Blur* | scrambles the phases: a little smears the attacks, the top leaves a wash without attacks |
| *Filter* | inside the loop: middle = open, below = low-pass, above = high-pass |

The line under the pad and the small lines on *Source*, *Loop Time*, *Warp* and *Filter* show the values in real
units. The pad's position is stored in presets like the faders. Presets from before this effect load it neutral.

## Multi XY page: what a finger does

Every finger on the pad is one grain voice (up to five). **XY ON** switches the pad on (the normal grain voice
pauses). The four buttons next to it choose what the two axes do; the line at the top of the pad says it too.

| Mapping | X | Y |
|---|---|---|
| **CLASSIC** | place in the loop | longer grains, more detune, crush and scatter (the mapping the pad always had) |
| **HARP** | place in the loop | pitch in steps of a pentatonic scale, one step per grid line; middle = as recorded |
| **BOW** | scrub through the loop: silent while the finger rests, moving it plays the loop at the finger's speed and in its direction | brightness |
| **PULSE** | place in the loop | pulse rate in steps from 1 to 32 per second; several fingers make polyrhythms |

**HOLD**: a voice keeps playing when its finger leaves, and the next touch adds another voice. After five, the
oldest is replaced. In BOW, a finger that leaves while moving keeps its speed. HOLD off releases every voice that
has no finger on it. Mapping and HOLD are stored in presets.

New mappings are added in `main_multi.scd` (`~xyMaps`), plus a button named `xyMap/<name>` on the page.

## Getting the layout onto the tablet

While `run-sc-main_multi.sh` runs, it serves this folder of the running checkout:
`http://<pi or laptop>:8080/main.tosc`. The launcher prints the URLs, and `UI_HTTP_PORT=0` switches it off.
The start page `http://<pi or laptop>:8080/` (`index.html`) has a "Load layout" button and shows the version
this machine expects. Add it to the tablet's home screen (Chrome: ⋮ → Add to home screen) and open the
downloaded file with TouchOSC. Because the file comes from the checkout that is running, it always matches
the code.
