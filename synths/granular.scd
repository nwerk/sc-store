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
	ccBus=0,
	ptrIn=0,
	micIn=0,
	bufIn=0,
	buf=0,
	recGate=0,
	// crossfade duration in seconds (tweak as needed)
	xfadeTime=1
	|
	var ccVals, ptr, sig, bufSig, frames, xfadeSamples, endIdx, w, startXSig, writeSig, recEnv, fb;
	ccVals = In.kr(ccBus, 128);
	fb = Select.kr(~busNames[\feedback].index, ccVals);
	ptr = In.ar(ptrIn, 1);
	sig = In.ar(micIn, 1);

	// click-free record gate: 10ms fade in/out (matches PD vline~ envelope)
	recEnv = Lag.ar(K2A.ar(recGate), 0.01);
	sig = sig * recEnv;

	bufSig = BufRd.ar(1, buf, ptr, 1, 2);
	// overdub: buffer preserved at fb level, mic always added on top
	// clip~ -1 1 prevents volume buildup (matches PD behavior)
	sig = (sig + (bufSig * fb)).clip(-1, 1);

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
	minPtrDelay=0,
	safeMargin=0.02,   // seconds — grain read window never reaches write head
	filterFreq=1000,
	// --- PD-ported parameters ---
	reverseGrain=0,    // 0/1: reverse grain playback direction
	bitDepth=1,        // 0–1 normalized (1 = clean, 0 = crushed)
	bitVol=1,          // 0–1: bit crusher output volume
	freqModAmt=0,      // 0–50: LFO depth on pitch
	freqModFreq=0,     // 0–5 Hz: LFO rate on pitch
	fixedPos=0,        // 0/1: lock grains to a fixed buffer position
	fixedPosSec=0,     // seconds: fixed position in buffer
	randDetune=0,      // 0–100: random per-grain micro-detune
	randomOctave=1,    // 1–4: range of random octave transposition
	octaveGroups=1,    // 1–50: every Nth grain gets octave-shifted
	fixedPosRand=0,    // 0–1: per-grain scatter radius around fixedPosSec (fraction of buffer duration)
	xyMode=0           // 0: normal CC-bus mode; 1: XY voice mode (bypasses 4 CC reads, overrides candidateCenter)
	|

	var ccVals;
	var sig, env;
	var densCtrl, durCtrl, rateCtrl, panCtrl;
	var ptr, ptrRand, posSec;
	var bufFrames, safeMarginSamples;
	var octaveMultiplier, detuneOffset, freqMod;
	var bitStepSize, bitCrushed, tanhDrive;
	var octaveGate;
	// trajectory-based playhead safety
	var recSpeedSamp, grainRate, durSamp;
	var desiredDelay, candidateCenter;
	var d0, relSpeed, dEnd, dMin, dMax;
	var aCheck, bCheck, kLow, kHigh, isUnsafe;
	var kPrimary, snapFwd, snapBwd, snapDelta, safeCenter;
	var dSpan, spanExceedsBuffer, fallbackCenter;
	// read-pointer freeze modulation
	var readModRate, readModDepth, readDropTrig, readDropEnv, readSpeedGate, heldPosSec;
	// fixed position latch
	var fixedPosTrig, fixedPosRise, fpHasPressed, fpLatchFrame, fpLatchDelay;
	var fpResumeFrame, fpFrozenFrame, normalModePosSec, xyFixedPosSec;

	// ============================================================
	// 1. CC BUS READS
	// ============================================================

	ccVals = In.kr(ccBus, 128);

	// -- Timing --
	// CC 17: density — squared taper → sparse grains at low end
	dens         = Select.kr(~busNames[\density].index, ccVals).squared.linlin(0, 1, 0.001, 1);
	dens         = 1.0 / (dens * 0.8).max(0.005);            // 0–800ms interval → Hz
	// CC 21: grain duration (0–1000ms) — bypassed in XY mode (arg value used directly)
	baseDur      = Select.kr(xyMode, [
		Select.kr(~busNames[\baseDur].index, ccVals).linlin(0, 1, 0.01, 1.0),
		baseDur
	]);

	// -- Pitch --
	// CC 20: grain pitch
	rate         = Select.kr(~busNames[\rate].index, ccVals).linlin(0, 1, 0.0625, 3.0625);
	// CC 18: random octave range (0–4 semitones)
	randomOctave = (Select.kr(~busNames[\randomOctave].index, ccVals) * 4).max(0).round;
	// CC 50: octave groups — every Nth grain gets transposed
	octaveGroups = (Select.kr(~busNames[\octaveGroups].index, ccVals) * 50).max(1).round;
	// CC 26: per-grain random detune (÷1000 of rate) — bypassed in XY mode
	randDetune   = Select.kr(xyMode, [
		Select.kr(~busNames[\randDetune].index, ccVals) * 100,
		randDetune
	]);
	// CC 58/59: LFO frequency modulation
	freqModAmt   = Select.kr(~busNames[\freqModAmt].index, ccVals) * 5;
	freqModFreq  = Select.kr(~busNames[\freqModFreq].index, ccVals) * 5;

	// -- Playhead --
	// CC 22: jitter — bypassed in XY mode (ptrRandSamples arg used directly; LiveMode ON: y*1.5s)
	ptrRandSamples  = Select.kr(xyMode, [
		Select.kr(~busNames[\jitter].index, ccVals) * (3 * SampleRate.ir),
		ptrRandSamples
	]);
	// CC 24: base delay behind the record pointer (PD: ÷127 × 300 ms)
	ptrSampleDelay  = Select.kr(~busNames[\playheadRand].index, ccVals) * (3 * SampleRate.ir) + minPtrDelay;

	// -- Effects --
	// CC 54: bit depth — bypassed in XY mode (arg value used directly; 1.05=clean, 0.1=heavy)
	bitDepth     = Select.kr(xyMode, [
		(1 - Select.kr(~busNames[\bitDepth].index, ccVals)) + 0.05,
		bitDepth
	]);
	// CC 61: filter cutoff — inverted exponential (0=open, 1=closed)
	filterFreq   = (1 - Select.kr(~busNames[\filterFreq].index, ccVals)).linexp(0.0001, 1, 20, 20000);

	// -- Spatial / Grouping --
	// CC 60: stereo panning spread
	panRand      = Select.kr(~busNames[\panRand].index, ccVals);
	// CC 56/57: read-pointer freeze modulation
	readModRate  = Select.kr(~busNames[\speedModRate].index,  ccVals).linlin(0, 1, 0.05, 8.0);
	readModDepth = Select.kr(~busNames[\speedModDepth].index, ccVals);

	// ============================================================
	// 2. ENVELOPE & TRIGGER
	// ============================================================

	env      = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction: 2);
	densCtrl = Select.ar(K2A.ar(sync), [Dust.ar(dens), Impulse.ar(dens)]);

	// ============================================================
	// 3. PITCH CHAIN
	// (octave transposition → random detune → freq mod → rate rand → reverse)
	// ============================================================

	// Octave transposition: LFNoise0 changes at grain-group rate → mapped to 0..randomOctave
	octaveGate       = LFNoise0.kr(dens / octaveGroups.max(1));
	octaveMultiplier = 2.pow((octaveGate.range(0, randomOctave)).round);
	rate             = rate * octaveMultiplier;

	// Per-grain micro-detune
	detuneOffset = LFNoise1.kr(100).bipolar(randDetune / 1000);
	rate         = rate * (1 + detuneOffset);

	// LFO pitch modulation
	freqMod = SinOsc.kr(freqModFreq) * freqModAmt / 50;  // normalised ±1
	rate    = rate * (1 + freqMod);

	// Rate randomization
	rateCtrl = rate * LFNoise1.kr(100).exprange(1 / rateRand, rateRand);

	// Reverse
	rateCtrl = rateCtrl * Select.kr(reverseGrain, [1, -1]);

	// Grain duration with random variation
	durCtrl = baseDur * LFNoise1.ar(100).exprange(1 / durRand.max(0.01), durRand.max(0.01));

	// Panning
	panCtrl = LFNoise1.kr(100).bipolar(panRand);

	// ============================================================
	// 4. PLAYHEAD SAFETY (trajectory-based)
	// ============================================================
	// Test whether the grain's full read path intersects the moving
	// record pointer during the grain's lifetime, then snap away if so.
	//
	// Model (linear):
	//   grainRead(t) = center - 0.5*durSamp*grainRate + t*grainRate
	//   recHead(t)   = recPos + t*recSpeedSamp
	//   d(t)         = d0 + t*relSpeed
	// Unsafe iff any integer k satisfies dMin-margin ≤ k*bufFrames ≤ dMax+margin.
	// ============================================================

	bufFrames        = BufFrames.ir(buf);
	safeMarginSamples = safeMargin * SampleRate.ir;

	ptr          = In.ar(ptrBus, 1);
	recSpeedSamp = BufRateScale.kr(buf);
	grainRate    = rateCtrl;
	durSamp      = durCtrl * SampleRate.ir;

	ptrRand      = LFNoise1.ar(100).bipolar(ptrRandSamples);
	desiredDelay = (ptrSampleDelay + ptrRand).max(minPtrDelay);

	// XY mode: inject fixedPosSec (frames) + ptrRand jitter as candidate; safety still runs.
	// LiveMode OFF (fixedPos=1) discards safeCenter anyway — this path is harmless there.
	candidateCenter = Select.ar(K2A.ar(xyMode), [
		(ptr - desiredDelay).wrap(0, bufFrames),
		(fixedPosSec * SampleRate.ir + ptrRand).wrap(0, bufFrames)
	]);

	d0       = candidateCenter - (0.5 * durSamp * grainRate) - ptr;
	relSpeed = grainRate - recSpeedSamp;
	dEnd     = d0 + (durSamp * relSpeed);
	dMin     = d0.min(dEnd);
	dMax     = d0.max(dEnd);

	// Intersection test
	aCheck   = dMin - safeMarginSamples;
	bCheck   = dMax + safeMarginSamples;
	kLow     = (aCheck / bufFrames).ceil;
	kHigh    = (bCheck / bufFrames).floor;
	isUnsafe = kHigh >= kLow;

	// Snap: shift center by the smaller of forward/backward escape distances
	kPrimary = ((d0 + dEnd) * 0.5 / bufFrames).round;
	snapFwd  = (kPrimary * bufFrames) + safeMarginSamples - dMin;
	snapBwd  = (kPrimary * bufFrames) - safeMarginSamples - dMax;
	snapDelta = Select.ar(snapFwd.abs <= snapBwd.abs, [snapBwd, snapFwd]);

	// Fallback: if grain spans the whole buffer, place at opposite side
	dSpan            = (durSamp * relSpeed).abs;
	spanExceedsBuffer = (dSpan + (2 * safeMarginSamples)) > bufFrames;
	fallbackCenter   = (ptr - (bufFrames * 0.5)).wrap(0, bufFrames);

	safeCenter = Select.ar(isUnsafe,         [candidateCenter, (candidateCenter + snapDelta).wrap(0, bufFrames)]);
	safeCenter = Select.ar(spanExceedsBuffer, [safeCenter,      fallbackCenter]);

	posSec = safeCenter / bufFrames * BufDur.ir(buf);

	// ---- Read-pointer sine modulation (CC 56/57) ----
	// Sine LFO smoothly slows/freezes grain read position each cycle.
	// Gate = (sin + 2 - depth).clip(0,1): depth=0 → always 1 (bypass); depth=1 → dips to 0.
	// Latch fires at the downward zero-crossing (phase 0.5) to capture the live position
	// just as the freeze begins, giving the crossfade a stable reference to blend toward.
	readDropTrig  = Impulse.kr(readModRate, 0.5);
	readSpeedGate = K2A.ar((SinOsc.kr(readModRate) + 2 - readModDepth).clip(0, 1));
	heldPosSec    = Latch.ar(posSec, K2A.ar(readDropTrig));
	posSec        = (posSec * readSpeedGate) + (heldPosSec * (1 - readSpeedGate));

	// ---- Fixed position: latch heard position on press, resume forward on release ----
	// Normal mode (xyMode=0):
	//   fixedPos=1 (press):   grains freeze at the position heard at the moment of press ± scatter
	//   fixedPos=0 (release): grains continue forward from the latched position (not the live write head)
	//   fixedPos=0, pre-press: live posSec unchanged
	// XY mode (xyMode=1): preserves the existing fixedPosSec-arg behaviour unchanged.
	fixedPosTrig  = K2A.ar(fixedPos);
	fixedPosRise  = HPZ1.ar(fixedPosTrig) > 0;                          // one-sample rising edge
	fpHasPressed  = Latch.ar(fixedPosTrig, fixedPosRise);               // stays 1 after first press
	fpLatchFrame  = Latch.ar(posSec * SampleRate.ir, fixedPosRise);     // heard pos in frames at press
	fpLatchDelay  = Latch.ar(ptr - (posSec * SampleRate.ir), fixedPosRise); // write-head offset at press

	fpResumeFrame = (ptr - fpLatchDelay).wrap(0, bufFrames);            // moves forward from latch point
	fpFrozenFrame = (fpLatchFrame + (LFNoise1.ar(100) * fixedPosRand * bufFrames)).clip(0, bufFrames - 1);

	normalModePosSec = Select.ar(fixedPosTrig, [
		Select.ar(fpHasPressed, [posSec, fpResumeFrame / bufFrames * BufDur.ir(buf)]),  // 0: live or resume
		fpFrozenFrame / bufFrames * BufDur.ir(buf)                                      // 1: frozen
	]);

	// XY mode: original fixedPosSec-arg path — XY voices set this from touch X.
	xyFixedPosSec = Select.ar(fixedPosTrig, [
		posSec,
		(fixedPosSec + (LFNoise1.ar(100) * fixedPosRand * BufDur.ir(buf))).clip(0, BufDur.ir(buf))
	]);

	posSec = Select.ar(K2A.ar(xyMode), [normalModePosSec, xyFixedPosSec]);

	// ============================================================
	// 5. GRAIN SYNTHESIS
	// ============================================================

	sig = TGrains.ar(
		numChannels: 2,
		trigger:     densCtrl,
		bufnum:      buf,
		rate:        rateCtrl,
		centerPos:   posSec,
		dur:         durCtrl,
		pan:         panCtrl,
		amp:         1,
		interp:      4,
	);

	sig = sig * env * amp;

	// ============================================================
	// 6. EFFECTS CHAIN (bit crusher → tanh soft-clip → LPF)
	// ============================================================

	// Bit crusher: bitDepth 0.05–1.05 → 2–16 bit quantization
	bitStepSize = 1 / ((2.pow((bitDepth * 14 + 2).round)) - 1);
	bitCrushed  = (sig / bitStepSize).round * bitStepSize * bitVol;

	// Tanh soft-clip smooths quantization edges; drive scales with crush amount
	tanhDrive  = K2A.ar(bitDepth.linlin(0.05, 1.05, 100, 1));
	bitCrushed = tanh(bitCrushed * tanhDrive) / (tanhDrive * 0.85);

	// Crossfade: bypass crusher when bitDepth >= 1.0 (fully clean)
	sig = Select.ar(K2A.ar(bitDepth >= 1.0), [bitCrushed, sig]);

	// Low-pass filter (independent of bit crusher)
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