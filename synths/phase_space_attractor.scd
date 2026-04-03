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

SynthDef(\attractorVoice, { |out=0, gate=0, fingerX=0.5, fingerY=0.5,
	attack=0.05, release=1.0, amp=0.7, reverbMix=0.4, reverbRoom=0.7,
	quantise=0|
	var env, sig, baseFreq;

	env = EnvGen.kr(Env.asr(attack, 1.0, release), gate, doneAction: 2);

	// fingerX sets base pitch, fingerY sets stereo pan
	baseFreq = fingerX.linexp(0, 1, 80, 2000);

	// Chromatic quantise: snap to nearest semitone when quantise=1
	baseFreq = Select.kr(quantise, [baseFreq, baseFreq.cpsmidi.round(1).midicps]);

	// Six harmonics with gentle static detune
	sig = Mix.fill(6, { |i|
		var detune = LFNoise2.kr(0.3 + (i * 0.17)).range(0.998, 1.002);
		SinOsc.ar(baseFreq * (i + 1) * detune, 0, 0.28 / (i + 1))
	});

	sig = LPF.ar(sig, (baseFreq * 6).clip(200, 18000));
	sig = LeakDC.ar(sig);
	sig = sig * env * amp;
	sig = FreeVerb.ar(sig, reverbMix, reverbRoom, 0.5);
	sig = Pan2.ar(sig, fingerY.linlin(0, 1, -1, 1));

	Out.ar(out, sig);
}).add;

"SynthDef \\attractorVoice added.".postln;
