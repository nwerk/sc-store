// ============================================================
// OSC Address → CC Bus Index Mapping (Multi-Synth Patch)
// ============================================================
// Covers grain (indices 11–83), the pad (67–76), tape (remapped to 90–97), cembalo (100–109) and the FFT
// effect (110–119).
//
// Tape params use their ORIGINAL key names (badness, wavemix, etc.)
// pointing to new indices 90–96. This causes the \ape SynthDef to
// bake index 90–96 into its UGen graph at compile time, resolving
// the CC bus conflicts with grain.
//
// tape_* alias keys are included for use by midiconfig_multi.scd
// and as documentation. Both sets refer to the same bus slots.
//
// Loaded BEFORE midiconfig_multi.scd, SynthDef files, and
// oscconfig_multi.scd.
// ============================================================

~busNames = (
	// ---- Grain params (indices unchanged from main_grain.scd) ----
	masterVol:    ( index: 11 ),
	bufferLen:    ( index: 16 ),
	density:      ( index: 17 ),
	randomOctave: ( index: 18 ),
	rate:         ( index: 20 ),
	baseDur:      ( index: 21 ),
	jitter:       ( index: 22 ),
	playheadRand: ( index: 24 ),
	randDetune:   ( index: 26 ),
	feedback:     ( index: 46 ),
	octaveGroups: ( index: 50 ),
	bitDepth:     ( index: 54 ),
	speedModRate: ( index: 56 ),
	speedModDepth:( index: 57 ),
	freqModAmt:   ( index: 58 ),
	freqModFreq:  ( index: 59 ),
	panRand:      ( index: 60 ),
	filterFreq:   ( index: 61 ),
	timeStretch:  ( index: 62 ),
	fftFilter:    ( index: 64 ),
	fftMorph:     ( index: 65 ),
	fftFreezeVol: ( index: 66 ),
	param80:      ( index: 80, isLatch: true ),
	param81:      ( index: 81 ),
	param82:      ( index: 82 ),
	fftFreeze:    ( index: 83, isLatch: true ),

	// ---- Tape params: original key names, indices remapped to 90–96 ----
	// \ape SynthDef uses these key names at compile time; baking 90–96
	// into the UGen graph avoids all CC conflicts with grain params.
	badness:     ( index: 90 ),
	wavemix:     ( index: 91 ),
	wavemap:     ( index: 92 ),
	badnessmap:  ( index: 93 ),
	reverb_mix:  ( index: 94 ),
	reverb_room: ( index: 95 ),
	master:      ( index: 96 ),
	pluck:       ( index: 97 ),  // \apePoly: how much the picking position shapes each note (0 = off)

	// ---- tape_* aliases (same indices — used by midiconfig_multi.scd) ----
	tape_badness:     ( index: 90 ),
	tape_wavemix:     ( index: 91 ),
	tape_wavemap:     ( index: 92 ),
	tape_badnessmap:  ( index: 93 ),
	tape_reverb_mix:  ( index: 94 ),
	tape_reverb_room: ( index: 95 ),
	tape_master:      ( index: 96 ),
	tape_pluck:       ( index: 97 ),

	// ---- Cembalo params (free zone 100–109) ----
	// The cembalo's parameters live in sclang (they are read per note), not in a SynthDef, so these slots
	// only store the normalised fader values for presets and boot sync. ~setCembaloParam (main_multi.scd)
	// maps them to the real ranges.
	cembalo_volume:   ( index: 100 ),
	cembalo_bright:   ( index: 101 ),
	cembalo_noise:    ( index: 102 ),
	cembalo_warmth:   ( index: 103 ),
	cembalo_weird:    ( index: 104 ),
	cembalo_octave:   ( index: 105 ),
	cembalo_decay:    ( index: 106 ),
	cembalo_revMix:   ( index: 107 ),
	cembalo_room:     ( index: 108 ),
	cembalo_pluck:    ( index: 109 ),

	// ---- FFT effect \fftPrism (synths/fft_prism.scd; free zone 110–119) ----
	// It also uses fftFreeze (83) and fftFreezeVol (66, its level). fftFilter (64) and fftMorph (65) belonged to
	// the old \fftFreeze effect and are no longer read in this patch.
	fftSource:   ( index: 110 ),
	fftSpiral:   ( index: 111 ),  // pad X, 0.5 = no shift
	fftFeedback: ( index: 112 ),  // pad Y
	fftTime:     ( index: 113 ),
	fftWarp:     ( index: 114 ),  // 0.5 = no transposition
	fftSmear:    ( index: 115 ),
	fftSieve:    ( index: 116 ),
	fftFlicker:  ( index: 117 ),
	fftBlur:     ( index: 118 ),
	fftTilt:     ( index: 119 ),  // 0.5 = open

	// ---- Pad params (free zone 67–76; 110–119 is the FFT effect's) ----
	// \pad (synths/pad.scd) reads these slots directly; the indices are baked in at compile time.
	pad_volume:       ( index: 67 ),
	pad_wobble:       ( index: 68 ),  // depth of the pitch modulation (wow, flutter, scoop)
	pad_wobbleRate:   ( index: 69 ),
	pad_detune:       ( index: 70 ),
	pad_tone:         ( index: 71 ),
	pad_wave:         ( index: 72 ),
	pad_age:          ( index: 73 ),
	pad_attack:       ( index: 74 ),
	pad_release:      ( index: 75 ),
	pad_reverb:       ( index: 76 ),
);

// ---- ~oscMap: OSC address string → (busIndex, type) ----
// type: \fader (continuous 0–1), \toggle, \momentary, \preset
// All grain entries are copied verbatim from osc_mappings.scd.
// New /tape/* fader entries map to the remapped indices 90–97.

~oscMap = (
	// ---- Grain faders (Page 2: Grain Core) ----
	'/grain/density':      ( busIndex: 17, type: \fader, label: "Density" ),
	'/grain/duration':     ( busIndex: 21, type: \fader, label: "Grain Duration" ),
	'/grain/pitch':        ( busIndex: 20, type: \fader, label: "Grain Pitch" ),
	'/grain/speedModRate': ( busIndex: 56, type: \fader, label: "Speed Mod Rate" ),
	'/grain/speedModDepth':( busIndex: 57, type: \fader, label: "Speed Mod Depth" ),
	'/grain/jitter':       ( busIndex: 22, type: \fader, label: "Jitter" ),
	'/grain/playheadRand': ( busIndex: 24, type: \fader, label: "Playhead Rand" ),
	'/grain/bufferLen':    ( busIndex: 16, type: \fader, label: "Buffer Length" ),
	'/grain/feedback':     ( busIndex: 46, type: \fader, label: "Feedback" ),
	'/grain/timeStretch':  ( busIndex: 62, type: \fader, label: "Time Stretch" ),

	// ---- Grain faders (Page 3: Modulation & FX) ----
	'/grain/randomOctave': ( busIndex: 18, type: \fader, label: "Random Octave" ),
	'/grain/octaveGroups': ( busIndex: 50, type: \fader, label: "Octave Groups" ),
	'/grain/randDetune':   ( busIndex: 26, type: \fader, label: "Rand Detune" ),
	'/grain/freqModAmt':   ( busIndex: 58, type: \fader, label: "Freq Mod Amt" ),
	'/grain/freqModFreq':  ( busIndex: 59, type: \fader, label: "Freq Mod Freq" ),
	'/grain/bitDepth':     ( busIndex: 54, type: \fader, label: "Bit Depth" ),
	'/grain/panRand':      ( busIndex: 60, type: \fader, label: "Pan Random" ),
	'/grain/filterFreq':   ( busIndex: 61, type: \fader, label: "Filter Freq" ),

	// ---- FFT effect (page "fft"; synths/fft_prism.scd) ----
	// The pad /grain/fftPad (x = fftSpiral, y = fftFeedback) is not a fader: its two slots are listed in
	// ~fftPadSlots below and handled in oscconfig_multi.scd.
	'/grain/fftFreezeVol': ( busIndex: 66,  type: \fader, label: "FFT Level" ),
	'/grain/fftSource':    ( busIndex: 110, type: \fader, label: "FFT Source (grains .. grain input)" ),
	'/grain/fftTime':      ( busIndex: 113, type: \fader, label: "FFT Loop Time" ),
	'/grain/fftWarp':      ( busIndex: 114, type: \fader, label: "FFT Warp (transposition per round)" ),
	'/grain/fftSmear':     ( busIndex: 115, type: \fader, label: "FFT Smear" ),
	'/grain/fftSieve':     ( busIndex: 116, type: \fader, label: "FFT Sieve" ),
	'/grain/fftFlicker':   ( busIndex: 117, type: \fader, label: "FFT Sieve Flicker" ),
	'/grain/fftBlur':      ( busIndex: 118, type: \fader, label: "FFT Blur" ),
	'/grain/fftTilt':      ( busIndex: 119, type: \fader, label: "FFT Filter (low-pass .. open .. high-pass)" ),

	// ---- Master (persistent across pages) ----
	'/master/volume':      ( busIndex: 11, type: \fader, label: "Master Volume" ),

	// ---- Grain toggles (Page 4) ----
	'/grain/record':       ( type: \toggle,   label: "REC (the recorder's one switch, replaces Live Mode)" ),
	'/grain/reverse':      ( type: \toggle,   label: "Reverse" ),
	'/grain/fixedPos':     ( type: \toggle,   label: "Fixed Position" ),
	'/grain/fftFreeze':    ( type: \toggle,   label: "FFT Freeze" ),
	'/grain/densFromDur':  ( type: \toggle,   label: "Density from Duration" ),

	// ---- Grain momentary (Page 4) ----
	'/grain/octaveDown':   ( type: \momentary, label: "Octave Down" ),
	'/grain/octaveUp':     ( type: \momentary, label: "Octave Up" ),
	'/grain/pitchReset':   ( type: \momentary, label: "Pitch Reset" ),
	'/grain/deleteBuffer': ( type: \momentary, label: "CLEAR (empty the loop)" ),
	'/grain/loadSample':   ( type: \momentary, label: "LOAD SAMPLE (next file of samples/)" ),
	'/grain/stopAudio':    ( type: \momentary, label: "Stop Audio" ),

	// ---- Preset commands (Page 1) ----
	'/preset/load':        ( type: \preset,   label: "Load Preset" ),
	'/preset/save':        ( type: \preset,   label: "Save Preset" ),
	'/preset/delete':      ( type: \preset,   label: "Delete Preset" ),

	// ---- Tape faders (remapped to free zone 90–97) ----
	'/tape/badness':       ( busIndex: 90, type: \fader, label: "Tape Badness" ),
	'/tape/wavemix':       ( busIndex: 91, type: \fader, label: "Tape Wavemix" ),
	'/tape/wavemap':       ( busIndex: 92, type: \fader, label: "Tape Wavemap" ),
	'/tape/badnessmap':    ( busIndex: 93, type: \fader, label: "Tape Badnessmap" ),
	'/tape/reverbMix':     ( busIndex: 94, type: \fader, label: "Tape Reverb Mix" ),
	'/tape/reverbRoom':    ( busIndex: 95, type: \fader, label: "Tape Reverb Room" ),
	'/tape/volume':        ( busIndex: 96, type: \fader, label: "Tape Volume" ),
	'/tape/pluck':         ( busIndex: 97, type: \fader, label: "Tape Picking Position Amount" ),

	// ---- Cembalo faders (free zone 100–109; handled by ~setCembaloParam, see oscconfig_multi.scd) ----
	'/cembalo/volume':     ( busIndex: 100, type: \fader, label: "Cembalo Volume" ),
	'/cembalo/bright':     ( busIndex: 101, type: \fader, label: "Cembalo Bright" ),
	'/cembalo/noise':      ( busIndex: 102, type: \fader, label: "Cembalo Noise" ),
	'/cembalo/warmth':     ( busIndex: 103, type: \fader, label: "Cembalo Warmth" ),
	'/cembalo/weird':      ( busIndex: 104, type: \fader, label: "Cembalo Weird" ),
	'/cembalo/octave':     ( busIndex: 105, type: \fader, label: "Cembalo 4' String" ),
	'/cembalo/decay':      ( busIndex: 106, type: \fader, label: "Cembalo Decay" ),
	'/cembalo/revMix':     ( busIndex: 107, type: \fader, label: "Cembalo Reverb Mix" ),
	'/cembalo/room':       ( busIndex: 108, type: \fader, label: "Cembalo Reverb Room" ),
	'/cembalo/pluck':      ( busIndex: 109, type: \fader, label: "Cembalo Picking Position Amount" ),

	// ---- Pad faders (free zone 67–76; \pad reads the slots, generic fader handler) ----
	'/pad/volume':         ( busIndex: 67, type: \fader, label: "Pad Volume" ),
	'/pad/wobble':         ( busIndex: 68, type: \fader, label: "Pad Pitch Wobble Depth" ),
	'/pad/wobbleRate':     ( busIndex: 69, type: \fader, label: "Pad Pitch Wobble Rate" ),
	'/pad/detune':         ( busIndex: 70, type: \fader, label: "Pad Detune" ),
	'/pad/tone':           ( busIndex: 71, type: \fader, label: "Pad Tone (lowpass)" ),
	'/pad/wave':           ( busIndex: 72, type: \fader, label: "Pad Wave (saws .. pulse)" ),
	'/pad/age':            ( busIndex: 73, type: \fader, label: "Pad Tape Age" ),
	'/pad/attack':         ( busIndex: 74, type: \fader, label: "Pad Attack" ),
	'/pad/release':        ( busIndex: 75, type: \fader, label: "Pad Release" ),
	'/pad/reverb':         ( busIndex: 76, type: \fader, label: "Pad Reverb Mix" ),

	// ---- Grain input sources (toggles, any combination) ----
	'/grain/srcGuitar':    ( type: \toggle,   label: "Grain In: Guitar" ),
	'/grain/srcCembalo':   ( type: \toggle,   label: "Grain In: Cembalo" ),
	'/grain/srcTape':      ( type: \toggle,   label: "Grain In: Tape Synth" ),
	'/grain/srcPad':       ( type: \toggle,   label: "Grain In: Pad" ),
);

// ---- FFT effect: pad slots and starting values ----
// The pad's two slots are stored in presets like faders (osc/presets.scd adds them to ~presetFaderIndices).
~fftPadSlots = [~busNames[\fftSpiral].index, ~busNames[\fftFeedback].index];
// Neutral settings: the effect passes its input unchanged, silent until the level fader is raised.
// Applied at boot, and for the slots a preset from before this effect does not contain.
~fftDefaults = (
	fftSource: 0, fftSpiral: 0.5, fftFeedback: 0, fftTime: 0, fftWarp: 0.5,
	fftSmear: 0, fftSieve: 0, fftFlicker: 0.3, fftBlur: 0, fftTilt: 0.5
);

// ---- Reverse lookup: bus index → OSC address (for feedback) ----
~busToOsc = IdentityDictionary.new;
~oscMap.keysValuesDo { |addr, spec|
	if (spec[\busIndex].notNil) {
		~busToOsc[spec[\busIndex]] = addr;
	};
};

"OSC mappings (multi) loaded.".postln;
