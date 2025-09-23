// Tartini tracker tuned like sigmund~ behaviour
(
SynthDef(\tartiniTracker_sigmundStyle, { |inChan=0, freqBus=0, ampBus=1,
    inGain=2.0, hpFreq=50, execFreq=60, minFreq=30, maxFreq=2000,
    ampMapMax=0.08, lagTime=0.03, gateThreshold=0.0003, clarityThreshold=0.01|
    var sig, pre, ampRMS, ampMapped;
    var t, freqRaw, mag, clarity, freqOut, freqSm, ampSm;

    sig = SoundIn.ar(inChan) * inGain;
    pre = HPF.ar(sig, hpFreq);              // remove subsonic noise
    ampRMS = Amplitude.kr(pre, 0.01, 0.01); // robust RMS measure
    ampMapped = ampRMS.linlin(0.0, ampMapMax, 0.0, 1.0).clip(0,1);

    // Tartini returns [freq, magnitude, clarity]
    t = Tartini.kr(pre, execFreq, minFreq, maxFreq);
    freqRaw = t[0] ?? 0;
    mag     = t[1] ?? 0;
    clarity = t[2] ?? 0;
    // gate + require clarity
    freqOut = Gate.kr(freqRaw, (ampMapped > gateThreshold) * (clarity > clarityThreshold));

    // smoothing
    freqSm = Lag.kr(freqRaw, lagTime);
    ampSm  = Lag.kr(ampMapped, lagTime);

    Out.kr(freqBus, freqSm);
    Out.kr(ampBus,  ampSm);

    //freqSm.poll(1, "tartini_freqHz");
    //ampSm.poll(1, "tartini_amp");
    //clarity.poll(1, "tartini_clarity");
}).add;
)
