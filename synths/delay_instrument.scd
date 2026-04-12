(
"Try Instantiate".postln;

// Delay instrument with dynamic pitch-tracking filter and Limiter.
// TouchOSC control: /delay/multixy/1-5 (X=pitch, Y=distortion),
//   /delay/xy (filterRatio, stereoWidth), /delay/feedback, /delay/liftmode,
//   /delay/master, /delay/p2/feedback, /delay/p2/drywet
SynthDef(\delayInstrument, {
    |out=0, feedback=0.5, filterRatio=1.0, stereoWidth=0.5,
     master=1.0, drywet=0.5, liftMode=2, p2feedback=0.3, p2drywet=0.3,
     distortion=0.0|

    var sig, sigL, sigR;
    var freq, dynCutoff;
    var filteredL, filteredR;
    var liftSel, fbDecay, p2Decay;
    var delayedL, delayedR;
    var mixedL, mixedR;
    var p2L, p2R;
    var wide;
    var limited;

    sig = SoundIn.ar([0, 1]);
    sigL = sig[0];
    sigR = sig[1];

    // --- Dynamic pitch-tracking filter ---
    // Detect dominant pitch from left channel; smooth to avoid sudden jumps.
    freq = Pitch.kr(sigL, initFreq: 440, minFreq: 60, maxFreq: 4000,
        execFreq: 100, maxBinsPerOctave: 16)[0];
    freq = Lag.kr(freq, 0.1);

    // Inverse mapping: high pitch -> lower cutoff (filter closes).
    // Pitch range 60..4000 Hz maps to cutoff 8000..300 Hz.
    // filterRatio (0..1) provides manual control over how open the filter is.
    dynCutoff = (freq.linexp(60, 4000, 8000, 300) * filterRatio).clip(200, 18000);

    // Apply dynamic low-pass filter before the effects chain and Limiter.
    filteredL = LPF.ar(sigL, dynCutoff);
    filteredR = LPF.ar(sigR, dynCutoff);

    // --- Distortion stage ---
    filteredL = (filteredL * (1 + (distortion * 9))).tanh;
    filteredR = (filteredR * (1 + (distortion * 9))).tanh;

    // --- Primary delay with feedback ---
    // liftMode: 0=freeze (hold buffer, no new input),
    //           1=silence (mute delay input),
    //           2=normal decay
    liftSel  = Select.kr(liftMode.clip(0, 2), [0, 0, 1]);
    fbDecay  = (feedback   * 10).clip(0.01, 20);
    p2Decay  = (p2feedback * 10).clip(0.01, 20);

    delayedL = CombL.ar(filteredL * liftSel, 2.0, 0.3,  fbDecay);
    delayedR = CombL.ar(filteredR * liftSel, 2.0, 0.42, fbDecay); // slightly offset for stereo spread

    // Dry/wet mix
    mixedL = (1 - drywet) * filteredL + (drywet * delayedL);
    mixedR = (1 - drywet) * filteredR + (drywet * delayedR);

    // --- Secondary delay path (p2) ---
    p2L = CombL.ar(mixedL, 2.0, 0.19, p2Decay);
    p2R = CombL.ar(mixedR, 2.0, 0.27, p2Decay);
    mixedL = (1 - p2drywet) * mixedL + (p2drywet * p2L);
    mixedR = (1 - p2drywet) * mixedR + (p2drywet * p2R);

    // --- Stereo width ---
    wide = [
        mixedL + (stereoWidth * (mixedL - mixedR)),
        mixedR + (stereoWidth * (mixedR - mixedL))
    ];

    // --- Limiter ---
    // The dynamic filter above has already attenuated harsh high-frequency
    // content before it reaches here.
    limited = Limiter.ar(wide * master, 0.9, 0.01);

    Out.ar(out, limited);
}).add;

"SynthDef \delayInstrument is defined and added.".postln;
)
