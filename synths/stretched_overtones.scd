(
SynthDef(\dynamicAdditiveSynth, { |ccBus=0, out=0, envBus=0, freqBus=0, envAmp=0, freq=220, env=0.2, amp=0.5, maxDetune=20, minFreq=50, maxFreq=1000, minLPF=500, maxLPF=5000, reverbMix=0.3|
    var input, pitchTrack, oscSum, lpfFreq, reverbed;
    var nOvertones = 8;  // hardcoded overtone count
    var ccVals = In.kr(ccBus, 128);
    var stretch = ccVals[1].linlin(0, 127, 1, 2); // MIDI CC 1 controls stretch (0-1)
    var detuneFactor = stretch * envAmp * maxDetune;
    var envAmpVal = In.kr(envBus, 1);
    var pitchFreq = In.kr(freqBus, 1);

    envAmpVal = EnvGen.kr(Env.perc(0.01, 3.0), doneAction: 2) * envAmp;
    pitchFreq = freq;
    stretch = MouseX.kr(1, 2);
    maxDetune = MouseY.kr(0, 50); // Max detune controlled by mouse Y position
    oscSum = Mix.fill(nOvertones, { |i|
        var overtone = i + 1;
        var stretchFactor = overtone * stretch;
        var detune = envAmpVal * (maxDetune ** overtone);
        var freq = (pitchFreq * overtone) + detune;
        SinOsc.ar(freq) * (1 / nOvertones) * (1 / overtone);
    });

    lpfFreq = envAmpVal.linexp(0, 1, minLPF, maxLPF);
    oscSum = LPF.ar(oscSum, lpfFreq);

    reverbed = FreeVerb.ar(oscSum, mix: reverbMix, room: 0.94, damp: 0.5);
    Out.ar(out, reverbed * envAmpVal * amp ! 2);
}).add;
)