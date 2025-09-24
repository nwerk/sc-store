(
SynthDef(\dynamicAdditiveSynth, { |inBus=0, out=0, amp=0.5, maxDetune=20, minFreq=50, maxFreq=1000, minLPF=500, maxLPF=5000, reverbMix=0.3|
    var input, envAmp, pitchTrack, pitchFreq, oscSum, lpfFreq, reverbed;
    var nOvertones = 8;  // hardcoded overtone count

    input = SoundIn.ar(inBus);
    envAmp = Amplitude.kr(input, 0.01, 0.05);

    pitchTrack = Pitch.kr(input, ampThreshold: 0.02, median: 7);
    pitchFreq = pitchTrack[0].clip(minFreq, maxFreq);

    oscSum = Mix.fill(nOvertones, { |i|
        var overtone = i + 1;
        var detune = envAmp * overtone * maxDetune;
        var freq = (pitchFreq * overtone) + detune;
        SinOsc.ar(freq) * (1 / nOvertones)
    });

    lpfFreq = envAmp.linexp(0, 1, minLPF, maxLPF);
    oscSum = LPF.ar(oscSum, lpfFreq);

    reverbed = FreeVerb.ar(oscSum, mix: reverbMix, room: 0.8, damp: 0.5);
    Out.ar(out, reverbed * envAmp * amp ! 2);
}).add;
)


// Example usage
(
x = Synth(\dynamicAdditiveSynth, [
    \inBus, 0,
    \amp, 0.5,
    \maxDetune, 30,
    \minFreq, 50,
    \maxFreq, 1000,
    \minLPF, 500,
    \maxLPF, 5000,
    \reverbMix, 0.4
]);
)



// Example usage
(
x = Synth(\dynamicAdditiveSynth, [
    \inBus, 0,
    \nOvertones, 12,
    \amp, 0.5,
    \maxDetune, 30,
    \minFreq, 50,
    \maxFreq, 1000,
    \minLPF, 500,
    \maxLPF, 5000,
    \reverbMix, 0.4
]);
)


// Example usage
Server.killAll;
(
s.waitForBoot{
	// Use microphone input (bus 0) to drive the synth
	x = Synth(\dynamicAdditiveSynth, [
		\inBus, 0,
		\nOvertones, 12,
		\amp, 0.5,
		\maxDetune, 30,
		\minFreq, 50,
		\maxFreq, 1000,
		\minLPF, 500,
		\maxLPF, 5000,
		\reverbMix, 0.4
	]);
};
)
(SinOsc