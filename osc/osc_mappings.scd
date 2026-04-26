// ============================================================
// OSC Address → CC Bus Index Mapping (Granular Patch)
// ============================================================
// This file defines ~busNames (same structure as granular_midi.scd,
// reusing the same CC bus indices) and adds ~oscMap for
// bidirectional OSC address ↔ bus index lookup.
//
// Loaded BEFORE oscconfig.scd and midiconfig.scd.
// ============================================================

// ---- ~busNames: identical index mapping to granular_midi.scd ----
// The \gran synth reads In.kr(ccBus, 128) using these indices.
// We keep the full 128-slot dictionary so the existing synth code
// works without any changes.

~busNames = (
	param1:   ( index:1 ),
	param2:   ( index:2 ),
	param3:   ( index:3 ),
	param4:   ( index:4 ),
	param5:   ( index:5 ),
	param6:   ( index:6 ),
	param7:   ( index:7 ),
	param8:   ( index:8 ),
	param9:   ( index:9 ),
	param10:  ( index:10 ),
	masterVol:  ( index:11 ),
	param12:  ( index:12 ),
	param13:  ( index:13 ),
	param14:  ( index:14 ),
	param15:  ( index:15 ),
	bufferLen:( index:16 ),
	density:  ( index:17 ),
	randomOctave: ( index:18 ),
	param19:  ( index:19 ),
	rate:     ( index:20 ),
	baseDur:  ( index:21 ),
	jitter:   ( index:22 ),
	param23:  ( index:23 ),
	playheadRand: ( index:24 ),
	randDetune:   ( index:26 ),
	param27:  ( index:27 ),
	param28:  ( index:28 ),
	param29:  ( index:29 ),
	param30:  ( index:30 ),
	param31:  ( index:31 ),
	param32:  ( index:32 ),
	param33:  ( index:33 ),
	param34:  ( index:34 ),
	param35:  ( index:35 ),
	param36:  ( index:36 ),
	param37:  ( index:37 ),
	param38:  ( index:38 ),
	param39:  ( index:39 ),
	param40:  ( index:40 ),
	param41:  ( index:41 ),
	param42:  ( index:42 ),
	param43:  ( index:43 ),
	param44:  ( index:44 ),
	param45:  ( index:45 ),
	feedback: ( index:46 ),
	param47:  ( index:47 ),
	param48:  ( index:48 ),
	param49:  ( index:49 ),
	octaveGroups: ( index:50 ),
	param51:  ( index:51 ),
	param52:  ( index:52 ),
	param53:  ( index:53 ),
	bitDepth: ( index:54 ),
	param55:       ( index:55 ),
	speedModRate:  ( index:56 ),  // CC 56: Speed Modulation Rate (Dust Hz)
	speedModDepth: ( index:57 ),  // CC 57: Speed Modulation Depth (0–1)
	freqModAmt:  ( index:58 ),
	freqModFreq: ( index:59 ),
	panRand:  ( index:60 ),
	filterFreq: ( index:61 ),
	param62: ( index:62 ),
	param63:  ( index:63 ),
	fftFilter: ( index:64 ),
	fftMorph:  ( index:65 ),
	fftFreezeVol: ( index:66 ),
	param67:  ( index:67 ),
	param68:  ( index:68 ),
	param69:  ( index:69 ),
	param70:  ( index:70 ),
	param71:  ( index:71 ),
	param72:  ( index:72 ),
	param73:  ( index:73 ),
	param74:  ( index:74 ),
	param75:  ( index:75 ),
	param76:  ( index:76 ),
	param77:  ( index:77 ),
	param78:  ( index:78 ),
	param79:  ( index:79 ),
	param80:  ( index:80, isLatch:true ),
	param81:  ( index:81 ),
	param82:  ( index:82 ),
	fftFreeze: ( index:83, isLatch: true ),
	param84:  ( index:84 ),
	param85:  ( index:85 ),
	param86:  ( index:86 ),
	param87:  ( index:87 ),
	param88:  ( index:88 ),
	param89:  ( index:89 ),
	param90:  ( index:90 ),
	param91:  ( index:91 ),
	param92:  ( index:92 ),
	param93:  ( index:93 ),
	param94:  ( index:94 ),
	param95:  ( index:95 ),
	param96:  ( index:96 ),
	param97:  ( index:97 ),
	param98:  ( index:98 ),
	param99:  ( index:99 ),
	param100: ( index:100 ),
	param101: ( index:101 ),
	param102: ( index:102 ),
	param103: ( index:103 ),
	param104: ( index:104 ),
	param105: ( index:105 ),
	param106: ( index:106 ),
	param107: ( index:107 ),
	param108: ( index:108 ),
	param109: ( index:109 ),
	param110: ( index:110 ),
	param111: ( index:111 ),
	param112: ( index:112 ),
	param113: ( index:113 ),
	param114: ( index:114 ),
	param115: ( index:115 ),
	param116: ( index:116 ),
	param117: ( index:117 ),
	param118: ( index:118 ),
	param119: ( index:119 ),
	param120: ( index:120 ),
	param121: ( index:121 ),
	param122: ( index:122 ),
	param123: ( index:123 ),
	param124: ( index:124 ),
	param125: ( index:125 ),
	param126: ( index:126 ),
	param127: ( index:127 ),
	param128: ( index:128 )
);

// ---- ~oscMap: OSC address string → (busIndex, type) ----
// type: \fader (continuous 0–1), \toggle, \momentary
// Only the active parameters are listed here; unused paramN slots
// are not exposed to TouchOSC.

~oscMap = (
	// ---- Faders (Page 2: Grain Core) ----
	'/grain/density':     ( busIndex: 17, type: \fader, label: "Density" ),
	'/grain/duration':    ( busIndex: 21, type: \fader, label: "Grain Duration" ),
	'/grain/pitch':       ( busIndex: 20, type: \fader, label: "Grain Pitch" ),
	'/grain/speedModRate': ( busIndex: 56, type: \fader, label: "Speed Mod Rate" ),
	'/grain/speedModDepth':( busIndex: 57, type: \fader, label: "Speed Mod Depth" ),
	'/grain/jitter':      ( busIndex: 22, type: \fader, label: "Jitter" ),
	'/grain/playheadRand':( busIndex: 24, type: \fader, label: "Playhead Rand" ),
	'/grain/bufferLen':   ( busIndex: 16, type: \fader, label: "Buffer Length" ),
	'/grain/feedback':    ( busIndex: 46, type: \fader, label: "Feedback" ),

	// ---- Faders (Page 3: Modulation & FX) ----
	'/grain/randomOctave':( busIndex: 18, type: \fader, label: "Random Octave" ),
	'/grain/octaveGroups':( busIndex: 50, type: \fader, label: "Octave Groups" ),
	'/grain/randDetune':  ( busIndex: 26, type: \fader, label: "Rand Detune" ),
	'/grain/freqModAmt':  ( busIndex: 58, type: \fader, label: "Freq Mod Amt" ),
	'/grain/freqModFreq': ( busIndex: 59, type: \fader, label: "Freq Mod Freq" ),
	'/grain/bitDepth':    ( busIndex: 54, type: \fader, label: "Bit Depth" ),
	'/grain/panRand':     ( busIndex: 60, type: \fader, label: "Pan Random" ),
	'/grain/filterFreq':  ( busIndex: 61, type: \fader, label: "Filter Freq" ),
	'/grain/fftFilter':   ( busIndex: 64, type: \fader, label: "FFT Filter" ),
	'/grain/fftMorph':    ( busIndex: 65, type: \fader, label: "FFT Morph" ),
	'/grain/fftFreezeVol': ( busIndex: 66, type: \fader, label: "FFT Freeze Volume" ),

	// ---- Master (persistent across pages) ----
	'/master/volume':     ( busIndex: 11, type: \fader, label: "Master Volume" ),

	// ---- Toggles (Page 4) ----
	'/grain/record':      ( type: \toggle, label: "Record" ),
	'/grain/liveMode':    ( type: \toggle, label: "Live Mode" ),
	'/grain/reverse':     ( type: \toggle, label: "Reverse" ),
	'/grain/fixedPos':    ( type: \toggle, label: "Fixed Position" ),
	'/grain/fftFreeze':   ( type: \toggle, label: "FFT Freeze" ),

	// ---- Momentary (Page 4) ----
	'/grain/octaveDown':  ( type: \momentary, label: "Octave Down" ),
	'/grain/octaveUp':    ( type: \momentary, label: "Octave Up" ),
	'/grain/pitchReset':  ( type: \momentary, label: "Pitch Reset" ),
	'/grain/deleteBuffer':( type: \momentary, label: "Delete Buffer" ),
	'/grain/loadSample':  ( type: \momentary, label: "Load Sample" ),
	'/grain/stopAudio':   ( type: \momentary, label: "Stop Audio" ),

	// ---- Preset commands (Page 1) ----
	'/preset/load':       ( type: \preset, label: "Load Preset" ),
	'/preset/save':       ( type: \preset, label: "Save Preset" ),
	'/preset/delete':     ( type: \preset, label: "Delete Preset" ),
);

// ---- Reverse lookup: bus index → OSC address (for feedback) ----
~busToOsc = IdentityDictionary.new;
~oscMap.keysValuesDo { |addr, spec|
	if (spec[\busIndex].notNil) {
		~busToOsc[spec[\busIndex]] = addr;
	};
};

"OSC mappings loaded.".postln;
