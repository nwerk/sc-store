SynthDef(\bouncingBallSmooth, { |out=0, height=2.0, falloff=0.45,  loss=0.7, amp=0.9, stopFreq=800, fadeTime=3.0, pan=0, contactPitch=1000, rateMultiplier=1|
    var stopPeriod, initialInterval, t, interval, freq, mask, impact, dense, env, sig, envTrig, denseFiltered;
    var denseFreq, filterMask, cutoff, freqRate, ampScale, tEff, intervalNoAccel, freqNoAccel, fastMask, norm, gentle;
    var gravity = 9.81;
        stopPeriod = 1.0 / stopFreq;
        initialInterval = 2 * (height / gravity).sqrt.max(0.0001);
        t = Sweep.kr(0, 1);
        // estimate frequency without acceleration to detect when we reach audible pitch (30 Hz)
        intervalNoAccel = initialInterval * (loss ** t);
        freqNoAccel = 1 / intervalNoAccel;
        // fastMask is 1 when the non-accelerated freq reaches >= 30 Hz
        fastMask = (freqNoAccel >= 30).asInteger;
        // choose rate: 1 before 30Hz, rateMultiplier once 30Hz reached
        freqRate = Select.kr(fastMask, [1, rateMultiplier]);
        tEff = t * freqRate;
        interval = initialInterval * (loss ** tEff);
        freq = 1 / interval;
        // mask (sparse vs dense) still based on actual interval vs stopPeriod
        mask = (interval > stopPeriod).asInteger; // 1 or 0
        envTrig = Changed.kr(mask) * (mask <= 0);
        env = EnvGen.kr(
            Env([1, 1, 0], [0, fadeTime]), // attack=0, sustain, release=fadeTime
            envTrig,
            doneAction:2
        );
        // make amplitude scale depend on interval: shorter interval (higher frequency) -> softer impacts
        // map interval in range [stopPeriod, initialInterval] to a normalized 0..1 value, then
        // apply a gentler power curve so amplitude decreases more slowly as interval shortens.
        // use LinLin.kr to map safely on the server and raise to a fractional power (0.6)
        // so the falloff is less steep. Then scale to [0.05, 1.0] and clip.
        norm = LinLin.kr(interval, stopPeriod.min(initialInterval), initialInterval.max(stopPeriod), 0.0, 1.0).clip(0.0, 1.0);
        falloff = falloff.clip(0.0001, 1);
        gentle = norm.pow(falloff); // exponent < 1 => slower falloff
        ampScale = amp * LinLin.kr(gentle, 0.0, 1.0, 0.05, 1.0).clip(0.05, 1.0);
        impact = BPF.ar(Decay2.ar(Impulse.ar(freq), 0.001, 0.05) * ampScale, contactPitch, 0.3);
        dense = Decay2.ar(Impulse.ar(stopFreq), 0.001, 0.02) * (ampScale);
        cutoff = contactPitch.clip(80, 12000); // cutoff tracks contactPitch, safe range
        denseFiltered = LPF.ar(dense, cutoff);
        sig = (mask * impact) + ((1 - mask) * denseFiltered * env);
        Out.ar(out, Pan2.ar(sig, pan));
}).add;

// Example: Randomly trigger bouncingBallSmooth with random height, stop frequency, stereo pan, and contact pitch
s.waitForBoot {
    // Define a scale (e.g. C major) and convert to Hz
    var scale = Scale.lydian.degrees;
    var root = 46; // MIDI note number for C3
    var octaves = [0, 12, 24, 36];
    var notes = scale.collect({ |deg| octaves.collect({ |oct| deg + root + oct }) }).flat;
    var freqs = notes.collect({ |n| n.midicps });
    
    Pbind(
        \instrument, \bouncingBallSmooth,
        \height, Pwhite(2, 10.0),           // height in meters (safe: 0.5 to 6)
        \gravity, 9.81,
        \loss, Pwhite(0.6, 0.9),               // loss factor (safe: 0.5 to 0.9)
        \amp, 0.8,
        \stopFreq, Pseq(freqs, inf),         // stop frequency from scale (Hz)
        \fadeTime, Pwhite(0.5, 9.5),         // fade time in seconds
        \pan, Pwhite(-1.0, 1.0),             // stereo pan
        \contactPitch, (Pseq(freqs, inf)) * 4,     // contact pitch from scale (Hz)
        \dur, Pwhite(2, 4)                  // time between triggers
    ).play;
};