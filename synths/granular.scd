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
	arg out=0, buf=0, speed=1;
	var sig;
	sig = Phasor.ar(0, BufRateScale.kr(buf) * speed, 0, BufFrames.kr(buf));
	Out.ar(out, sig);
}).add;

SynthDef.new(\rec, {
	|
	ptrIn=0,
	micIn=0,
	bufIn=0,
	buf=0,
	fb=0.8,
	recGate=0,
	// crossfade duration in seconds (tweak as needed)
	xfadeTime=1
	|
	var ptr, sig, bufSig, frames, xfadeSamples, endIdx, w, startXSig, writeSig, recEnv;
	fb = 0.5;
	ptr = In.ar(ptrIn, 1);
	sig = In.ar(micIn, 1);

	// click-free record gate: 10ms fade in/out (matches PD vline~ envelope)
	recEnv = Lag.ar(K2A.ar(recGate), 0.01);
	sig = sig * recEnv;

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
	// --- PD-ported parameters ---
	reverseGrain=0,     // 0/1 toggle: reverse grain playback direction
	bitDepth=1,         // 0–1 normalized (1 = clean, 0 = crushed)
	bitVol=1,           // 0–1 bit crusher output volume
	freqModAmt=0,       // 0–50: LFO depth on pitch
	freqModFreq=0,      // 0–5 Hz: LFO rate on pitch
	playGroups=1,       // 1–50: every Nth grain fires
	fixedPos=0,         // 0/1 toggle: lock grains to a fixed buffer position
	fixedPosSec=0,      // seconds: fixed position in buffer
	randDetune=0,       // 0–100: random per-grain micro-detune
	randomOctave=1,     // 1–4: range of random octave transposition
	octaveGroups=1      // 1–50: every Nth grain gets octave-shifted
	|
	var ccVals, sig, env, densCtrl, durCtrl, rateCtrl, panCtrl,
	ptr, ptrRand, posSec,
	// helpers
	bufFrames, absRate, safeMarginSamples, userDelay,
	halfSpanSamples, totalDelay, delaySlow, delayFast, isSlow, safeDelayMin,
	octaveMultiplier, detuneOffset, freqMod, bitStepSize, bitCrushed,
	octaveGate;

	// ---- CC bus reads (PD CC mapping) ----
	ccVals = In.kr(ccBus, 128);

	// CC 62: master volume (0–1), default to arg value when CC is 0
	amp = Select.kr(~busNames[\masterVol].index, ccVals).max(amp);

	// CC 17: density — PD sends interval in ms (0–800), invert to Hz
	dens = Select.kr(~busNames[\density].index, ccVals).linlin(0, 1, 0.001, 1);
	dens = (1.0 / (dens * 0.8).max(0.005)); // 0–800ms → Hz (min ~1.25 Hz, max ~200 Hz)

	// CC 21: grain duration — PD: 0–1000ms
	baseDur = Select.kr(~busNames[\baseDur].index, ccVals).linlin(0, 1, 0.01, 1.0);

	// CC 20: grain pitch — PD: ÷127 × 3 + 0.0625
	rate = Select.kr(~busNames[\rate].index, ccVals).linlin(0, 1, 0.0625, 3.0625);

	// CC 22: jitter (ptrRandSamples) — PD: ÷127 × 3000 samples
	ptrRandSamples = Select.kr(~busNames[\jitter].index, ccVals) * 3000;

	// CC 55: playback speed — PD: ÷127 × 3 + 0.0625
	// (read here for use in playhead position calculation)
	// This is actually applied to \ptr via main_grain.scd, but we read it for safety calc
	// CC 24: playhead randomize — PD: ÷127 × 300
	ptrSampleDelay = Select.kr(~busNames[\playheadRand].index, ccVals) * 300 + minPtrDelay;

	// CC 60: panning amount (0–1)
	panRand = Select.kr(~busNames[\panRand].index, ccVals);

	// CC 54: bit depth — PD: val + 0.05 (range ~0.05–1.05)
	bitDepth = Select.kr(~busNames[\bitDepth].index, ccVals) + 0.05;

	// CC 58: freq mod amount — PD: ÷127 × 50
	freqModAmt = Select.kr(~busNames[\freqModAmt].index, ccVals) * 50;

	// CC 59: freq mod freq — PD: ÷127 × 5 Hz
	freqModFreq = Select.kr(~busNames[\freqModFreq].index, ccVals) * 5;

	// CC 25: play groups — PD: ÷127 × 50 (int, min 1)
	playGroups = (Select.kr(~busNames[\playGroups].index, ccVals) * 50).max(1).round;

	// CC 26: rand detune — PD: ÷127 × 100
	randDetune = Select.kr(~busNames[\randDetune].index, ccVals) * 100;

	// CC 18: random octave — PD: ÷127 × 4 (int, min 1)
	randomOctave = (Select.kr(~busNames[\randomOctave].index, ccVals) * 4).max(1).round;

	// CC 50: octave groups — PD: ÷127 × 50 (int, min 1)
	octaveGroups = (Select.kr(~busNames[\octaveGroups].index, ccVals) * 50).max(1).round;

	// ---- Local helper: playhead position in seconds ----
	// (identical logic to original, rewritten inline for clarity)
	bufFrames = BufFrames.ir(buf);
	absRate = rate.abs.max(0.001);
	safeMarginSamples = safeMargin * SampleRate.ir;

	ptrRand = LFNoise1.ar(100).bipolar(ptrRandSamples);
	userDelay = (ptrSampleDelay - ptrRand).max(minPtrDelay);

	halfSpanSamples = 0.5 * baseDur * absRate * SampleRate.ir;
	safeDelayMin = halfSpanSamples + safeMarginSamples;

	isSlow = absRate < 1;
	delayFast = userDelay.max(safeDelayMin);
	delaySlow = safeDelayMin;
	totalDelay = Select.ar(K2A.ar(isSlow), [delayFast, K2A.ar(delaySlow)]);

	ptr = In.ar(ptrBus, 1);
	ptr = (ptr - totalDelay) / bufFrames;
	ptr = ptr % 1;
	posSec = ptr * BufDur.ir(buf);

	// ---- Fixed position mode (PD: spigot gates between phasor and static slider) ----
	posSec = Select.ar(K2A.ar(fixedPos), [posSec, DC.ar(fixedPosSec)]);

	// ---- Envelope and trigger ----
	env = EnvGen.kr(Env.asr(atk, 1, rel), gate, doneAction:2);
	densCtrl = Select.ar(K2A.ar(sync), [Dust.ar(dens), Impulse.ar(dens)]);

	// ---- Play groups: thin triggers (PD: counter-based, every Nth grain fires) ----
	densCtrl = PulseDivider.ar(densCtrl, playGroups);

	// ---- Grain duration with random variation ----
	durCtrl = baseDur * LFNoise1.ar(100).exprange(1/durRand.max(0.01), durRand.max(0.01));

	// ---- Octave transposition (PD: counter-based octave groups) ----
	// Every Nth grain gets octave-shifted; range controlled by randomOctave
	// LFNoise0 rate = dens/octaveGroups → one new random value per "group"
	octaveGate = LFNoise0.kr(dens / octaveGroups.max(1));
	// Map to 0..randomOctave range, round to integer, then 2^n
	octaveMultiplier = 2.pow((octaveGate.range(0, randomOctave)).round);

	rate = rate * octaveMultiplier;

	// ---- Random detuning (PD: random ÷ 1000, sign randomized) ----
	detuneOffset = LFNoise1.kr(100).bipolar(randDetune / 1000);
	rate = rate * (1 + detuneOffset);

	// ---- Freq mod LFO (PD: osc~ at freqModFreq, depth × freqModAmt) ----
	freqMod = SinOsc.kr(freqModFreq) * freqModAmt / 50; // normalized ±1 range
	rate = rate * (1 + freqMod);

	// ---- Rate randomization ----
	rateCtrl = rate * LFNoise1.kr(100).exprange(1/rateRand, rateRand);

	// ---- Reverse grain (PD: toggle flips pitch to −1) ----
	rateCtrl = rateCtrl * Select.kr(reverseGrain, [1, -1]);

	// ---- Panning ----
	panCtrl = LFNoise1.kr(100).bipolar(panRand);

	// ---- TGrains ----
	sig = TGrains.ar(
		numChannels: 2,
		trigger: densCtrl,
		bufnum: buf,
		rate: rateCtrl,
		centerPos: posSec,
		dur: durCtrl,
		pan: panCtrl,
		amp: 1,
		interp: 4,
	);

	sig = sig * env * amp;

	// ---- Bit crusher (PD: per-grain, here post-TGrains) ----
	// bitDepth 0.05–1.05 → 2–16 bit quantization
	// step size = 1 / (2^(bitDepth*14+2) - 1)
	bitStepSize = 1 / ((2.pow((bitDepth * 14 + 2).round)) - 1);
	bitCrushed = (sig / bitStepSize).round * bitStepSize * bitVol;
	// Crossfade: when bitDepth >= 1.0 use clean signal, otherwise crushed
	sig = Select.ar(K2A.ar(bitDepth >= 1.0), [bitCrushed, sig]);

	// ---- Filter (independent from bitDepth) ----
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