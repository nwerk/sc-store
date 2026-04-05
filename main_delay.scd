(
Server.killAll;
//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/delay_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/delay_instrument.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/master.scd");

s.waitForBoot {
	// Audio bus for delay instrument routed into master
	~delayBus = Bus.audio(s, 2);

	~ccBuses.setAt(~busNames[\master_vol][\index], 0.8);

	// Create the delay instrument synth
	~delaySynth = Synth(\delayInstrument, [
		\out, ~delayBus,
		\inChan, 0,
		\delayTime, 0.01,
		\feedback, 1.2,
		\filterRatio, 1.0,
		\filterRq, 0.1,
		\distortion, 1.0,
		\dryWet, 0.5,
		\microDetune, 0.5,
		\inputGain, 1.0,
		\amp, 1.0
	]);

	// Master output (addToTail ensures it reads from delayBus after synth writes)
	~masterSynth = Synth(\master, [
		\inBus, ~delayBus,
		\ccBus, ~ccBuses
	], addAction: \addToTail);

	// ---- State for multi-touch and lift mode ----
	// 0 = freeze (keep ringing), 1 = silence, 2 = natural decay
	~liftMode = 0;
	// Track which fingers are currently touching (5 slots, 0-indexed internally)
	~activeTouches = Array.fill(5, { false });
	// Store per-finger data: [delayTime, distortion]
	~fingerData = Array.fill(5, { [0.01, 1.0] });
	// Most-recently-moved finger index
	~lastFinger = 0;
	// Stored feedback value from the slider (used to restore after natural decay)
	~sliderFeedback = 1.2;

	// ---- TouchOSC OSC Responders ----

	// ========== Page 1: Performance ==========

	// Multi-XY (5 fingers): X = delay time/pitch, Y = tanh distortion amount
	// Per-finger addresses: /delay/multixy/1 through /delay/multixy/5
	// Each sends two floats: x (0–1), y (0–1)
	5.do { |i|
		var addr = "/delay/multixy/" ++ (i + 1).asString;
		OSCdef(("delayMultiXY" ++ (i + 1)).asSymbol, { |msg|
			var x = msg[1].asFloat;
			var y = msg[2].asFloat;
			// X → delay time (exponential: 0 = 1s low pitch, 1 = 1ms high pitch)
			var dt = x.linexp(0, 1, 1.0, 0.001);
			// Y → tanh distortion drive (0 = gentle 0.5, 1 = heavy 10.0)
			var dist = y.linexp(0, 1, 0.5, 10.0);
			~fingerData[i] = [dt, dist];
			~lastFinger = i;
			~delaySynth.set(\delayTime, dt, \distortion, dist);
		}, addr);
	};

	// Multi-XY touch states: /delay/multixy/z sends 5 floats (z1–z5, 0.0 or 1.0)
	OSCdef(\delayMultiXYz, { |msg|
		5.do { |i|
			var wasActive = ~activeTouches[i];
			var isActive = msg[i + 1].asFloat > 0.5;
			~activeTouches[i] = isActive;

			// Finger just lifted
			if (wasActive and: { isActive.not }) {
				var anyActive = ~activeTouches.any { |t| t };
				// If another finger is still down, switch to its data
				if (anyActive) {
					var idx = ~activeTouches.indexOf(true);
					~delaySynth.set(
						\delayTime, ~fingerData[idx][0],
						\distortion, ~fingerData[idx][1]
					);
					~lastFinger = idx;
				} {
					// All fingers lifted — apply lift mode
					switch(~liftMode,
						0, { /* freeze: do nothing, delay keeps ringing */ },
						1, { ~delaySynth.set(\amp, 0) },  // silence
						2, { ~delaySynth.set(\feedback, 0.95) }  // natural decay
					);
				};
			};

			// Finger just touched down
			if (wasActive.not and: { isActive }) {
				// Restore from lift mode
				~delaySynth.set(\amp, 1.0, \feedback, ~sliderFeedback);
				~delaySynth.set(
					\delayTime, ~fingerData[i][0],
					\distortion, ~fingerData[i][1]
				);
				~lastFinger = i;
			};
		};
	}, '/delay/multixy/z');

	// Normal XY pad: X = filter harmonic ratio (1–16), Y = stereo width (micro-detune)
	OSCdef(\delayXY, { |msg|
		var x = msg[1].asFloat;
		var y = msg[2].asFloat;
		~delaySynth.set(
			\filterRatio, x.linlin(0, 1, 1.0, 16.0),
			\microDetune, y
		);
	}, '/delay/xy');

	// Slider: feedback amount — how far above unity (self-oscillation speed)
	// 0 = no feedback, 1 = well above unity for fast pitch build-up
	OSCdef(\delayFeedback, { |msg|
		var fb = msg[1].asFloat.linlin(0, 1, 0.0, 1.5);
		~sliderFeedback = fb;
		~delaySynth.set(\feedback, fb);
	}, '/delay/feedback');

	// 3-way toggle: finger-lift behavior
	// 0 = freeze (keep ringing at last pitch)
	// 1 = silence (mute immediately)
	// 2 = natural decay (feedback drops below 1)
	OSCdef(\delayLiftMode, { |msg|
		~liftMode = msg[1].asFloat.round.asInteger.clip(0, 2);
	}, '/delay/liftmode');

	// Master volume fader
	OSCdef(\delayMaster, { |msg|
		~ccBuses.setAt(~busNames[\master_vol][\index], msg[1].asFloat);
	}, '/delay/master');

	// ========== Page 2: Normal Delay Mode (feedback < 1) ==========

	// Feedback — capped below unity for standard delay behavior
	OSCdef(\delayP2Feedback, { |msg|
		var fb = msg[1].asFloat.linlin(0, 1, 0.0, 0.99);
		~sliderFeedback = fb;
		~delaySynth.set(\feedback, fb);
	}, '/delay/p2/feedback');

	// Dry/wet mix
	OSCdef(\delayP2DryWet, { |msg|
		~delaySynth.set(\dryWet, msg[1].asFloat);
	}, '/delay/p2/drywet');

	"Self-oscillating delay instrument loaded!".postln;
};
)
