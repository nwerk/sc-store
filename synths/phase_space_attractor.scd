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

// Polyphonic voice — freq computed and quantised in lang before sending to server
SynthDef(\attractorVoice, { |out=0, gate=0, freq=440, fingerY=0.5,
	attack=0.05, release=1.0, amp=0.5, reverbMix=0.4, reverbRoom=0.7|
	var env, sig;

	env = EnvGen.kr(Env.asr(attack, 1.0, release), gate, doneAction: 2);

	// Three harmonics with Rand.ir static detune — unique per Synth instance, no inter-voice beating
	sig = Mix.fill(3, { |i|
		var detune = 1 + Rand.ir(-0.003, 0.003);
		SinOsc.ar(freq * (i + 1) * detune, 0, 0.25 / (i + 1))
	});

	sig = LPF.ar(sig, (freq * 6).clip(200, 18000));
	sig = LeakDC.ar(sig);
	sig = sig * env * amp;
	sig = FreeVerb.ar(sig, reverbMix, reverbRoom, 0.5);
	sig = Pan2.ar(sig, fingerY.linlin(0, 1, -1, 1));

	Out.ar(out, sig);
}).add;

"SynthDef \\attractorVoice added.".postln;
