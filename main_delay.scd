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
		\feedback, 0.8,
		\filterRatio, 1.0,
		\filterRq, 0.5,
		\dryWet, 0.5,
		\microDetune, 0.5,
		\inputGain, 1.0
	]);

	// Master output (addToTail ensures it reads from delayBus after synth writes)
	~masterSynth = Synth(\master, [
		\inBus, ~delayBus,
		\ccBus, ~ccBuses
	], addAction: \addToTail);

	// ---- TouchOSC OSC Responders ----

	// == Page 1: Performance ==

	// XY pad: X = filter harmonic ratio (1–16), Y = filter bandwidth (bottom=wide, top=narrow)
	OSCdef(\delayFilter, { |msg|
		var x = msg[1].asFloat;
		var y = msg[2].asFloat;
		~delaySynth.set(
			\filterRatio, x.linlin(0, 1, 1.0, 16.0),
			\filterRq, y.linlin(0, 1, 1.0, 0.01)
		);
	}, '/delay/filter');

	// Feedback amount (0 → silent, 1 → self-oscillating via tanh)
	OSCdef(\delayFeedback, { |msg|
		~delaySynth.set(\feedback, msg[1].asFloat.linlin(0, 1, 0.0, 1.5));
	}, '/delay/feedback');

	// Delay time — exponential mapping for musical pitch control
	// Bottom = long delay / low pitch (1s), top = short delay / high pitch (1ms)
	OSCdef(\delayTime, { |msg|
		~delaySynth.set(\delayTime, msg[1].asFloat.linexp(0, 1, 1.0, 0.001));
	}, '/delay/time');

	// Dry/wet mix
	OSCdef(\delayDryWet, { |msg|
		~delaySynth.set(\dryWet, msg[1].asFloat);
	}, '/delay/drywet');

	// == Page 2: Setup ==

	// Micro-detuning amount (stereo width)
	OSCdef(\delayDetune, { |msg|
		~delaySynth.set(\microDetune, msg[1].asFloat);
	}, '/delay/detune');

	// Input gain
	OSCdef(\delayGain, { |msg|
		~delaySynth.set(\inputGain, msg[1].asFloat.linlin(0, 1, 0.0, 2.0));
	}, '/delay/gain');

	// Master volume (writes to CC bus for master synth)
	OSCdef(\delayMaster, { |msg|
		~ccBuses.setAt(~busNames[\master_vol][\index], msg[1].asFloat);
	}, '/delay/master');

	"Self-oscillating delay instrument loaded!".postln;
};
)
