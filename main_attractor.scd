(
Server.killAll;
//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/attractor_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/phase_space_attractor.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/master.scd");

s.waitForBoot {
	// Control buses
	~freqBus = Bus.control(s, 1);
	~ampBus = Bus.control(s, 1);
	~stateXBus = Bus.control(s, 1);
	~stateYBus = Bus.control(s, 1);

	// Audio bus for attractor voices routed into master
	~attractorBus = Bus.audio(s, 2);

	~ccBuses.setAt(~busNames[\master_vol][\index], 0.8);

	// Pitch/amp tracker with transient detection
	Synth(\tartiniTracker_sigmundStyle, [
		\inChan, 0,
		\freqBus, ~freqBus,
		\ampBus, ~ampBus,
		\holdLast, 1,
		\onsetThreshold, 0.5
	]);

	// Phase space state tracker
	Synth(\phaseSpaceState, [
		\ampBus, ~ampBus,
		\stateXBus, ~stateXBus,
		\stateYBus, ~stateYBus
	]);

	// Pre-allocate 5 voice slots (initially nil; created on touch)
	~voices = Array.fill(5, { nil });
	~voiceXY = Array.fill(5, { [0.5, 0.5] });  // stores raw [x, y] per voice slot
	~quantise = 0;  // 0 = free pitch, 1 = harmonic minor quantise

	// Map raw x (0.0–1.0) to frequency, with optional C harmonic minor snap
	~xToFreq = { |x|
		var rawFreq = x.linexp(0, 1, 80, 2000);
		if (~quantise == 1) {
			var scale = [0, 2, 3, 5, 7, 8, 11];  // C harmonic minor semitone offsets
			var midi = rawFreq.cpsmidi;
			var octaveBase = midi.floor - (midi.floor % 12);
			var pc = midi % 12;
			var nearest = scale.minIndex({ |s| (pc - s).abs.min(12 - (pc - s).abs) });
			(octaveBase + scale[nearest]).midicps
		} {
			rawFreq
		}
	};

	// Master output (addToTail ensures it reads from attractorBus after voices write)
	~masterSynth = Synth(\master, [\inBus, ~attractorBus, \ccBus, ~ccBuses], addAction: \addToTail);

	// ---- TouchOSC OSC Responders ----

	// Per-touch gate: /attractor/touch  touchIndex(int)  x(float)  y(float)  gate(int 0|1)
	OSCdef(\attractorTouch, { |msg, time, addr|
		var idx = msg[1].asInteger.clip(0, 4);
		var x = msg[2].asFloat;
		var y = msg[3].asFloat;
		var gate = msg[4].asInteger;

		if (gate == 1) {
			~voiceXY[idx] = [x, y];
			if (~voices[idx].notNil) {
				// Voice already exists — just update position (handles repeated gate=1 from TouchOSC)
				~voices[idx].set(\freq, ~xToFreq.(x), \fingerY, y);
			} {
				// New touch — create a voice
				~voices[idx] = Synth(\attractorVoice, [
					\out, ~attractorBus,
					\gate, 1,
					\freq, ~xToFreq.(x),
					\fingerY, y,
					\amp, 0.5
				], target: ~masterSynth, addAction: \addBefore);
			};
		} {
			// Release the voice envelope
			if (~voices[idx].notNil) {
				~voices[idx].set(\gate, 0);
				~voices[idx] = nil;
			};
		};
	}, '/attractor/touch');

	// Global parameter OSC responders (from TouchOSC faders)
	OSCdef(\attractorAttack, { |msg|
		~voices.do { |v| if(v.notNil) { v.set(\attack, msg[1].asFloat.linlin(0, 1, 0.001, 2.0)) } };
	}, '/attractor/attack');

	OSCdef(\attractorRelease, { |msg|
		~voices.do { |v| if(v.notNil) { v.set(\release, msg[1].asFloat.linlin(0, 1, 0.01, 5.0)) } };
	}, '/attractor/release');

	OSCdef(\attractorReverb, { |msg|
		~voices.do { |v| if(v.notNil) { v.set(\reverbMix, msg[1].asFloat) } };
	}, '/attractor/reverb');

	OSCdef(\attractorRoom, { |msg|
		~voices.do { |v| if(v.notNil) { v.set(\reverbRoom, msg[1].asFloat) } };
	}, '/attractor/room');

	OSCdef(\attractorQuantise, { |msg|
		~quantise = msg[1].asInteger.clip(0, 1);
		~voices.doWithIndex { |v, i|
			if (v.notNil) { v.set(\freq, ~xToFreq.(~voiceXY[i][0])) }
		};
	}, '/attractor/quantise');

	"Phase-Space Attractor patch loaded!".postln;
};
)
