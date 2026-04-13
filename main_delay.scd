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

	// 5 independent delay synths — one per finger, initially silent
	~delaySynths = Array.fill(5, {
		Synth(\delayInstrument, [
			\out, ~delayBus,
			\inChan, 0,
			\delayTime, 0.5,
			\feedback, 1.2,
			\filterRatio, 1.0,
			\filterRq, 0.1,
			\distortion, 1.0,
			\dryWet, 0.5,
			\microDetune, 0.5,
			\inputGain, 1.0,
			\amp, 0.0
		]);
	});

	// Master output (addToTail ensures it reads from delayBus after synth writes)
	~masterSynth = Synth(\master, [
		\inBus, ~delayBus,
		\ccBus, ~ccBuses
	], addAction: \addToTail);

	// ---- State ----
	// 0 = freeze (keep ringing), 1 = silence, 2 = natural decay
	~liftMode = 0;
	// Stored feedback value from the slider (used to restore after natural decay)
	~sliderFeedback = 1.2;
	// Per-finger inactivity timers — no message for 300 ms = finger lifted
	~fingerTimers = Array.fill(5, { nil });

	// ---- TouchOSC OSC Responders ----

	// ========== Page 1: Performance ==========

	// Multi-XY (5 fingers): X = delay time/pitch, Y = tanh distortion amount
	// Per-finger addresses: /delay/multixy/1 through /delay/multixy/5
	// Each sends two floats: x (0–1), y (0–1) — Trigger: Value
	// Each finger controls its own independent synth — no parameter conflicts
	5.do { |i|
		var addr = "/delay/multixy/" ++ (i + 1).asString;
		OSCdef(("delayMultiXY" ++ (i + 1)).asSymbol, { |msg|
			var x = msg[1].asFloat;
			var y = msg[2].asFloat;
			// X → delay time (exponential: 0 = 1s low pitch, 1 = 1ms high pitch)
			var dt = x.linexp(0, 1, 1.0, 0.001);
			// Y → tanh distortion drive (0 = gentle 0.5, 1 = heavy 10.0)
			var dist = y.linexp(0, 1, 0.5, 100.0);
			// Activate synth and restore from any previous lift mode
			~delaySynths[i].set(\delayTime, dt, \distortion, dist,
				\amp, 1.0, \feedback, ~sliderFeedback);
			// Cancel previous lift timer and schedule a new inactivity check
			~fingerTimers[i].stop;
			~fingerTimers[i] = SystemClock.sched(0.3, {
				switch(~liftMode,
					0, { /* freeze: keep ringing at last pitch */ },
					1, { ~delaySynths[i].set(\amp, 0) },
					2, { ~delaySynths[i].set(\feedback, 0.95) }
				);
				nil;
			});
		}, addr);
	};

	// Normal XY pad: X = filter harmonic ratio (1–16), Y = stereo width (micro-detune)
	OSCdef(\delayXY, { |msg|
		var x = msg[1].asFloat;
		var y = msg[2].asFloat;
		~delaySynths.do { |syn|
			syn.set(
				\filterRatio, x.linlin(0, 1, 1.0, 16.0),
				\microDetune, y.linlin(0, 1, 0, 30.0)
			);
		};
	}, '/delay/xy');

	// Slider: feedback amount — how far above unity (self-oscillation speed)
	// 0 = no feedback, 1 = well above unity for fast pitch build-up
	OSCdef(\delayFeedback, { |msg|
		var fb = msg[1].asFloat.linlin(0, 1, 0.0, 1.5);
		~sliderFeedback = fb;
		~delaySynths.do { |syn| syn.set(\feedback, fb) };
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
		~delaySynths.do { |syn| syn.set(\feedback, fb) };
	}, '/delay/p2/feedback');

	// Dry/wet mix
	OSCdef(\delayP2DryWet, { |msg|
		~delaySynths.do { |syn| syn.set(\dryWet, msg[1].asFloat) };
	}, '/delay/p2/drywet');

	"Self-oscillating delay instrument loaded!".postln;
};
OSCdef.trace(true);
)
