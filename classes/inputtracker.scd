// Tartini tracker tuned like sigmund~ behaviour
(
SynthDef(\tartiniTracker_sigmundStyle, { |inChan=0, freqBus=0, ampBus=1,
    inGain=2.0, hpFreq=50, execFreq=60, minFreq=30, maxFreq=2000,
    ampMapMax=0.08, lagTime=0.03, gateThreshold=0.0003, holdLast=0|  // 0 = original behaviour; 1 = hold last valid frequency when invalid
    var sig, pre, ampRMS, ampMapped;
    var t, freqRaw, mag;
    var valid, trigValid, freqLatched;
    var freqSm_base, freqSm_hold, freqOut, ampSm;

    sig = SoundIn.ar(inChan) * inGain;
    pre = HPF.ar(sig, hpFreq);              // remove subsonic noise
    ampRMS = Amplitude.kr(pre, 0.01, 0.01); // robust RMS measure
    ampMapped = ampRMS.linlin(0.0, ampMapMax, 0.0, 1.0).clip(0,1);

    // Tartini returns [freq, magnitude]
    t = Tartini.kr(pre, execFreq, minFreq, maxFreq);
    freqRaw = t[0] ?? 0;
    mag     = t[1] ?? 0;

    // validity (recognized pitch + above amplitude threshold)
    valid = (ampMapped > gateThreshold);

    // Hold-last path: latch the most recent valid frequency at exec rate
    trigValid   = Impulse.kr(execFreq) * valid;   // triggers only while valid
    freqLatched = Latch.kr(freqRaw, trigValid);   // holds last valid value when invalid

    // smoothing
    freqSm_base = Lag.kr(freqRaw,     lagTime);   // original behaviour (no hold)
    freqSm_hold = Lag.kr(freqLatched, lagTime);   // hold-last behaviour
    freqOut     = Select.kr(holdLast.clip(0,1), [freqSm_base, freqSm_hold]);

    ampSm  = Lag.kr(ampMapped, lagTime);

    Out.kr(freqBus, freqOut);
    Out.kr(ampBus,  ampSm);

    freqSm_hold.poll(1, "tartini_freqHz");
    //ampSm.poll(1, "tartini_amp");
}).add;
)
