// Phase-space state normalizer: maps tracker freq/amp to 2D coordinate
SynthDef(\phaseSpaceState, { |freqBus=0, ampBus=1, stateXBus=0, stateYBus=0, freqLo=80, freqHi=2000, ampSmooth=0.1|
	var freq, amp, stateX, stateY;

	freq = In.kr(freqBus, 1);
	amp = In.kr(ampBus, 1);

	// stateX = smoothed amplitude (already 0..1 from tracker)
	stateX = Lag.kr(amp, ampSmooth).clip(0, 1);

	// stateY = frequency mapped to 0..1 range, clipped
	stateY = freq.explin(freqLo, freqHi, 0, 1).clip(0, 1);

	Out.kr(stateXBus, stateX);
	Out.kr(stateYBus, stateY);
}).add;

"SynthDef \\phaseSpaceState added.".postln;

// Polyphonic voice gated by touch, amplitude modulated by proximity to audio state
SynthDef(\attractorVoice, { |out=0, gate=0, fingerX=0.5, fingerY=0.5, stateXBus=0, stateYBus=0,
	proxRadius=0.3, attack=0.01, release=0.5, amp=0.8, reverbMix=0.3, reverbRoom=0.6|
	var stateX, stateY, distance, proxAmplitude, env;
	var baseFreq, source, noise, sig;

	stateX = In.kr(stateXBus, 1);
	stateY = In.kr(stateYBus, 1);

	// Proximity: Euclidean distance in phase space
	distance = hypot(fingerX - stateX, fingerY - stateY);
	proxAmplitude = (1.0 - (distance / proxRadius)).clip(0, 1);

	// Gate envelope with release tail
	env = EnvGen.kr(Env.asr(attack, 1.0, release), gate, doneAction: 2);

	// Sound source: detuned sine harmonics, richness controlled by fingerX
	baseFreq = fingerY.linexp(0, 1, 100, 3000);
	source = Mix.fill(4, { |i|
		SinOsc.ar(
			baseFreq * (i + 1) * LFNoise1.kr(0.3).range(0.998, 1.002),
			0,
			fingerX.linlin(0, 1, 0.05, 0.25) / (i + 1)
		);
	});

	// Gentle filtered noise layer
	noise = LPF.ar(WhiteNoise.ar(0.02 * fingerX), baseFreq * 3);
	source = source + noise;

	// Final signal: source * envelope * proximity * amplitude
	sig = source * env * proxAmplitude * amp;

	// Reverb
	sig = FreeVerb.ar(sig, reverbMix, reverbRoom, 0.4);

	// Stereo pan based on fingerX
	sig = Pan2.ar(sig, fingerX.linlin(0, 1, -1, 1));

	Out.ar(out, sig);
}).add;

"SynthDef \\attractorVoice added.".postln;
