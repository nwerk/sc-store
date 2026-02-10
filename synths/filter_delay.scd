
// Alternative: Self-contained synth with internal sound source for testing
SynthDef(\filterDelay, { |out=0, delayTime=0.3, feedback=1.2, filterFreq=1200, filterRes=0.1, trigRate=0.5, amp=0.5, chaosBus=0, vol=0, volCtrlBus=0|
    var trig, source, delayed, filtered, feedbackSig, limited, output;
    var chaosCtrl, chaosTime, normalTime, chaosSig, dustrate;
    var volCtrl, volSig, frozenVol, master;

    // Read chaos control from bus (0 = normal, 1 = chaotic)
	filterFreq = In.kr(filterFreq);
    volSig = In.kr(vol);
    ccVals = In.kr(ccBus, 128);

    chaosCtrl = Select.kr(~busNames[\chaosBus].index, ccVals);
    volCtrl = Select.kr(~busNames[\volCtrlBus].index, ccVals);
    master = Select.kr(~busNames[\master].index, ccVals);
    frozenVol = Latch.kr(volSig, volCtrl); // Freeze value when volCtrl goes high

    // Trigger impulses to feed the delay
    trig = Impulse.ar(trigRate);
    source = Decay2.ar(trig, 0.001, 0.1) * PinkNoise.ar(0.3);
	
    filterFreq = filterFreq.cpsmidi.round(Pseq([0, 2, 4, 7, 9], inf).asStream).midicps;
	filterFreq.poll;

    // Original delay time
    normalTime = SinOsc.kr(0.1).range(0.0025, 0.005);

    // Chaotic delay time: random jumps with smooth glide, then hold
    dustrate = TRand.kr(0.2, 1.5, Dust.ar(1.5)); // New random target on each trigger
    chaosSig = Dust.kr(dustrate); // Random triggers ~1.5 per second (adjust rate as needed)
    chaosTime = TRand.kr(0.001, 2, chaosSig).exprange(0.001, 2); // New random target on each trigger
    chaosTime = Lag.kr(chaosTime, 1).exprange(0.001, 2); // Glide to target over 0.3s, then hold

    // Select between normal and chaotic based on bus value
    delayTime = Select.kr(chaosCtrl, [normalTime, chaosTime]);
    delayTime = [delayTime, delayTime + 0.005]; // Create a stereo delay with slightly different times
	// Local feedback loop
    feedbackSig = LocalIn.ar(2);

    // Delay with feedback
	delayed = DelayC.ar(source + feedbackSig, 2.0, delayTime.clip(0.001, 2.0));//, DelayC.ar(source + feedbackSig, 2.0, delayTime.clip(0.001, 2.0) + 0.001)];
    // Resonant lowpass filter - key for taming feedback
    filtered = RLPF.ar(delayed, filterFreq.clip(20, 20000), filterRes.clip(0.01, 1.0));

    // Soft clip and limit the feedback signal
    limited = filtered * feedback.clip(0, 2.0);
    limited = (limited * 0.5).tanh * 2; // Soft saturation
    limited = Limiter.ar(limited, 0.9, 0.01);

    // Send back to feedback loop
    LocalOut.ar(limited);

    // Output with final limiter as safety
    amp = Select.kr(volCtrl, [volSig, frozenVol]); // 0 = live, 1 = frozen
    output = Limiter.ar(limited * amp, 0.95, 0.01);
    output = output * master; 
    Out.ar(out, output); // Stereo output
}).add;
