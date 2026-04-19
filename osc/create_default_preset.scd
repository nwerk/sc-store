// ============================================================
// Create Default Preset — run ONCE after main_grain.scd boots
// ============================================================
// Writes preset slot 0 with musically useful starting values.
// After running, slot 0 appears lit on the TouchOSC preset page.
// ============================================================
// How to use:
//   1. Boot main_grain.scd so all synths and buses exist
//   2. Select-all this file and evaluate (Ctrl+Enter)
//   3. Done — preset 0 is now on disk and can be loaded any time
// ============================================================

(
// ---- Default fader values (normalized 0.0–1.0, matching ccBuses scale) ----
//
// What each value produces in the synth:
//   busIndex 16  bufferLen     0.5    → 4 seconds buffer
//   busIndex 17  density       0.1    → ~12 grains/sec (moderate texture)
//   busIndex 18  randomOctave  0.0    → no octave randomization (= range 1)
//   busIndex 20  pitch         0.3125 → rate = 1.0 (original pitch)
//   busIndex 21  duration      0.2    → ~200ms grain envelope
//   busIndex 22  jitter        0.0    → no jitter (locked to playhead)
//   busIndex 24  playheadRand  0.0    → no extra playhead randomization
//   busIndex 25  playGroups    0.0    → every grain fires (no thinning)
//   busIndex 26  randDetune    0.0    → no micro-detuning
//   busIndex 46  feedback      0.0    → no recording feedback
//   busIndex 50  octaveGroups  0.0    → octave shift applies every grain
//   busIndex 54  bitDepth      1.0    → NO bit crushing (critical — 0.0 = max crush)
//   busIndex 55  speed         0.3125 → playhead speed = 1.0 (forward, normal)
//   busIndex 58  freqModAmt    0.0    → LFO pitch mod depth off
//   busIndex 59  freqModFreq   0.0    → LFO pitch mod rate off
//   busIndex 60  panRand       0.3    → moderate stereo spread
//   busIndex 62  masterVol     0.8    → 80% output volume

var defaults = Dictionary[
	16 -> 0.5,
	17 -> 0.1,
	18 -> 0.0,
	20 -> 0.3125,  // linlin(0,1, 0.0625,3.0625) → 1.0 at 0.3125
	21 -> 0.2,
	22 -> 0.0,
	24 -> 0.0,
	25 -> 0.0,
	26 -> 0.0,
	46 -> 0.0,
	50 -> 0.0,
	54 -> 1.0,     // must be 1.0 — anything lower activates bit crusher
	55 -> 0.3125,  // linlin(0,1, 0.0625,3.0625) → 1.0 at 0.3125
	58 -> 0.0,
	59 -> 0.0,
	60 -> 0.3,
	62 -> 0.8
];

// Apply to ccBuses
defaults.keysValuesDo { |busIdx, val|
	~ccBuses.setAt(busIdx, val);
};

// Reset toggle states
~recState      = false;
~liveMode      = false;
~reverseState  = false;
~fixedPosState = false;
~fftFreezeState = false;
~currentRate   = 1.0;

// Save as preset slot 0
~savePreset.(0);
"Default preset written to slot 0.".postln;
)
