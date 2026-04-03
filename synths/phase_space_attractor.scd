// Phase-space state: maps fast vs slow amplitude to 2D coordinate
SynthDef(\phaseSpaceState, { |ampBus=1, stateXBus=0, stateYBus=0|
	var amp, stateX, stateY;

	amp = In.kr(ampBus, 1);

	// stateX = fast amplitude (responds quickly to transients)
	stateX = Lag.kr(amp, 0.05).clip(0, 1);

	// stateY = slow amplitude (tracks overall dynamics envelope)
	stateY = Lag.kr(amp, 2.0).clip(0, 1);

	Out.kr(stateXBus, stateX);
	Out.kr(stateYBus, stateY);
}).add;

"SynthDef \\phaseSpaceState added.".postln;

// Polyphonic voice gated by touch, timbre modulated by audio phase-space state
SynthDef(\attractorVoice, { |out=0, gate=0, fingerX=0.5, fingerY=0.5, stateXBus=0, stateYBus=0,
	attack=0.05, release=1.0, amp=0.7, reverbMix=0.4, reverbRoom=0.7|
	var stateX, stateY, env, sig;
	var baseFreq, filtFreq, shimmerRate;

	stateX = In.kr(stateXBus, 1);  // fast amp: responds to transients
	stateY = In.kr(stateYBus, 1);  // slow amp: tracks overall dynamics

	env = EnvGen.kr(Env.asr(attack, 1.0, release), gate, doneAction: 2);

	// fingerY sets base pitch
	baseFreq = fingerY.linexp(0, 1, 80, 2000);

	// Six detuned harmonics; stateX speeds up shimmer on transients
	shimmerRate = stateX.linlin(0, 1, 0.2, 3.0);
	sig = Mix.fill(6, { |i|
		var detune = LFNoise2.kr(shimmerRate * (0.4 + (i * 0.31))).range(0.997, 1.003);
		SinOsc.ar(baseFreq * (i + 1) * detune, 0, 0.3 / (i + 1))
	});

	// stateY (slow dynamics) opens a resonant filter — playing louder = brighter
	filtFreq = stateY.linexp(0.001, 1, baseFreq * 1.2, baseFreq * 10).clip(120, 18000);
	sig = RLPF.ar(sig, filtFreq, 0.4);

	sig = LeakDC.ar(sig);
	sig = sig * env * amp;
	sig = FreeVerb.ar(sig, reverbMix, reverbRoom, 0.5);
	sig = Pan2.ar(sig, fingerX.linlin(0, 1, -1, 1));

	Out.ar(out, sig);
}).add;

"SynthDef \\attractorVoice added.".postln;
