// Tartini tracker tuned like sigmund~ behaviour
(
SynthDef(\tartiniTracker_sigmundStyle, { |inChan=0, freqBus=0, ampBus=1, lagAmpBus=2, ampAvgWindowSec=10,
    inGain=2.0, hpFreq=5, lpFreq=2000, execFreq=60, 
    ampMapMax=0.08, lagTime=0.03, gateThreshold=0.03, holdLast=0|  // 0 = original behaviour; 1 = hold last valid frequency when invalid
    var sig, pre, ampRMS, ampMapped;
    var t, freqRaw, mag;
    var valid, trigValid, freqLatched;
    var freqSm_base, freqSm_hold, freqOut, ampSm;
    var nSamp, lagAmpSm;

    sig = SoundIn.ar(inChan) * inGain;
    pre = HPF.ar(sig, hpFreq);              // remove subsonic noise
    pre = LPF.ar(sig, lpFreq);              // remove subsonic noise
    ampRMS = Amplitude.kr(pre, 0.01, 0.01); // robust RMS measure
    ampMapped = ampRMS.linlin(0.0, ampMapMax, 0.0, 1.0).clip(0,1);

    // Tartini returns [freq, magnitude]; use default analysis settings
    t = Tartini.kr(pre);
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
    // 10s moving average (boxcar) at control rate
    // N = ampAvgWindowSec * ControlRate; average = RunningSum/N
    nSamp = (ampAvgWindowSec.max(0.001) * ControlRate.ir);
    lagAmpSm = (RunningSum.kr(ampMapped, nSamp) / nSamp).clip(0, 1);


    Out.kr(freqBus, freqOut);
    Out.kr(ampBus,  ampSm);
    Out.kr(lagAmpBus,  lagAmpSm);

    //freqSm_hold.poll(1, "tartini_freqHz");
    //ampSm.poll(1, "tartini_amp");
    lagAmpSm.poll(1, "tartini_window_amp");
}).add;
)
