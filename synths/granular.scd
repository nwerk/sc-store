//// Fix Buffer length to 5 s
//b = Buffer.alloc(s, s.sampleRate * 2, 1);
//b = Buffer.readChannel(s, "C:/Users/phi_n/Documents/SuperCollider/Recordings/SC_250113_112227.wav", channels: 1)
//s.options.device = "Focusrite USB ASIO";
//
//s.boot;
//(
//// Allocate explicit buses after boot
//~micBus = ~micBus ? { Bus.audio(s, 1) }.value;   // mono mic bus
//~ptrBus = ~ptrBus ? { Bus.audio(s, 1) }.value;   // audio-rate pointer bus
//)
SynthDef.new(\mic, {
	arg in=0, out=0, amp=1;
	var sig;
	sig = SoundIn.ar(in) * amp;
	Out.ar(out, sig);
}).add;

SynthDef.new(\ptr, {
	arg out=0, buf=0;
	var sig;
	sig = Phasor.ar(0, BufRateScale.kr(buf), 0, BufFrames.kr(buf));
	Out.ar(out, sig);
}).add;

SynthDef.new(\rec, {
	|
	ptrIn=0,
	micIn=0,
	bufIn=0,
	buf=0,
	fb=0.8,
	// crossfade duration in seconds (tweak as needed)
	xfadeTime=1
	|
	var ptr, sig, bufSig, frames, xfadeSamples, endIdx, w, startXSig, writeSig;
	fb = 0.5;
	ptr = In.ar(ptrIn, 1);
	sig = In.ar(micIn, 1);
	bufSig = BufRd.ar(1, buf, ptr, 1, 2);
	sig = 0.5 * (sig + (bufSig * fb));

	// crossfade setup
	frames = BufFrames.kr(buf);
	xfadeSamples = (xfadeTime * SampleRate.ir).max(1); // avoid div by zero
	endIdx = ptr + (frames - xfadeSamples); // partner index from the buffer end
	// ramp 0..1 over first xfadeSamples, clipped outside
	w = Clip.ar(ptr / xfadeSamples, 0, 1);
	// blend: tail -> head over the xfade window
	startXSig = BufRd.ar(1, buf, endIdx, 1, 2) * (1 - w) + sig * w;
	// only apply in head region; elsewhere write the normal signal
	writeSig = Select.ar(ptr < xfadeSamples, [sig, startXSig]);

	BufWr.ar(writeSig, buf, ptr);
}).add;

SynthDef.new(\gran, {
	|
	ccBus=0,
	amp=0.5,
	buf=0,
	out=0,
	atk=1,
	rel=1,
	gate=1,
	sync=1,
	dens=40,
	baseDur=0.05,
	durRand=1,
	rate=1,
	rateRand=1,
	panRand=0,
	grainEnv=(-1),
	ptrBus=0,
	ptrSampleDelay=20000,
	ptrRandSamples=5000,
	minPtrDelay=1000,
	// extra safety margin so the grain read window never reaches the write head
	safeMargin=0.02, // seconds
	filterFreq=1000,
	octaveJump=0 // 0 to 1, maps to octave shifts 0 to 4
	|
	var ccVals, sig, env, densCtrl, durCtrl, rateCtrl, panCtrl,
	ptr, ptrRand, posSec,
	// new helpers
	bufFrames, absRate, safeMarginSamples, userDelay, maxDurFromUserDelay,
	halfSpanSamples, autoDelay, totalDelay, delaySlow, delayFast, isSlow, safeDelayMin,
	octaveMultiplier;
	

	// Local helper: returns center position in seconds for TGrains
    var playheadPosSec = { |ptrBus, buf, rateCtrl, durCtrl, ptrSampleDelay, ptrRandSamples, minPtrDelay, safeMargin|
        var bufFrames = BufFrames.ir(buf);
        var absRate = rateCtrl.abs.max(0.001);
		// alterntaive: max(0.001, abs(rateCtrl))
        var safeMarginSamples = safeMargin * SampleRate.ir;

        var ptrRand = LFNoise1.ar(100).bipolar(ptrRandSamples);
        var userDelay = (ptrSampleDelay - ptrRand).max(minPtrDelay);
		// userDelay = max(ptrSampleDelay - ptrRand, minPtrDelay);

        var halfSpanSamples = 0.5 * durCtrl * absRate * SampleRate.ir;
        var safeDelayMin = halfSpanSamples + safeMarginSamples;

        var isSlow = absRate < 1;
        var delayFast = userDelay.max(safeDelayMin);
		// delayFast = max(userDelay, safeDelayMin);
        var delaySlow = safeDelayMin;
        var totalDelay = Select.ar(isSlow, [delayFast, delaySlow]);

        var ptr = In.ar(ptrBus, 1);     // pointer in samples
        ptr = (ptr - totalDelay) / bufFrames;
        ptr = ptr % 1;                  // wrap 0..1
        posSec = ptr * BufDur.ir(buf);
    };


    ccVals = In.kr(ccBus, 128);
	dens = Select.kr(~busNames[\density].index, ccVals).range(0.1, 200);

	env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction:2);
	densCtrl = Select.ar(sync, [Dust.ar(dens), Impulse.ar(dens)]);
	durCtrl = baseDur * LFNoise1.ar(100).exprange(1/durRand, durRand);

	// map octaveJump (0..1) to integer octave shifts (0..4), then apply 2^octave
	//octaveJump = In.kr(octaveJump, 1);
	//octaveJump = octaveJump * LFNoise1.ar(100).range(0, 1);
	//octaveMultiplier = 2.pow((octaveJump * 4).round);
	octaveJump = LFNoise0.kr(0.5).range(0, octaveJump);
	octaveJump = Lag.kr(octaveJump, 0.3); // 300ms glide time
	octaveMultiplier = 2.pow((octaveJump * 4).round);

	rate = rate * octaveMultiplier;
	rateCtrl = rate * LFNoise1.kr(100).exprange(1/rateRand, rateRand);
	panCtrl = LFNoise1.kr(100).bipolar(panRand);
	rate.poll;

    posSec = playheadPosSec.(
		ptrBus,
		buf,
		rateCtrl,
		durCtrl,
		ptrSampleDelay,
		ptrRandSamples,
		minPtrDelay,
		safeMargin
	);

	// TGrains wraps reads that cross the buffer boundary automatically
	sig = TGrains.ar(
		numChannels: 2,
		trigger: densCtrl,
		bufnum: buf,
		rate: rateCtrl,
		centerPos: posSec,
		dur: durCtrl,
		pan: panCtrl,
		amp: 1,
		interp: 1,
	);

	sig = sig * env * amp;
	sig = LPF.ar(sig, freq: filterFreq);
	Out.ar(out, sig);
}).add;
"SynthDefs for mic, ptr, rec, and gran added to server.".postln;
//(
////b.zero;
//~micGrp = Group.new;
//~ptrGrp = Group.after(~micGrp);
//~recGrp = Group.after(~ptrGrp);
//~granGrp = Group.after(~recGrp);
//
//	Synth(\mic, [\in, 0, \out, ~micBus], ~micGrp);
//	Synth(\ptr, [\out, ~ptrBus, \buf, b], ~ptrGrp);
//	//Synth(\rec, [\ptrIn, ~ptrBus, \micIn, ~micBus, \buf, b, \fb, 0.6], ~recGrp);
//	~g = Synth(\gran, [
//		\amp, 0.3 ,
//		\buf, b,
//		\out, 0,
//		\atk, 0,
//		\rel, 1,
//		\gate, 1,
//		\sync, 0,
//		\dens, 70,
//		\baseDur, 0.5,
//		\durRand, 0.1,
//		\rate, 0.5,
//		\rateRand, 1.01,
//		\panRand, 1,
//		\grainEnv, -1,
//		\ptrBus, ~ptrBus,
//		\ptrSampleDelay, 44100 * 2,
//		\ptrRandSamples, 44100 * 0.5,
// 		\minPtrDelay, 44100,
//	    \filterFreq, 3000,
//		\octaveJump, 0.2//~ccBuses[\octaveJump].index  // added octaveJump CC bus
//	], ~granGrp);
//)
//
//s.meter;
//b.plot;