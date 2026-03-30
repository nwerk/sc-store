(
// Kaoss Pad loop scrubber — playback voice and loop recorder

SynthDef(\kaossVoice, { |out=0, buf=0, padX=0.5, padY=0.5, gate=1, ccBus=0, amp=0.5|
	var sig, sigOld, sigNew, env, phase, readPhaseOld, readPhaseNew, rate, crossfade, xLag, xLagOld, xLagNew, centerOld, centerNew;
	var ccVals = In.kr(ccBus, 128);
	var windowParam = Select.kr(~busNames[\kaoss_window].index, ccVals);
	var vol = Select.kr(~busNames[\kaoss_vol].index, ccVals);
	var bufFrames = BufFrames.kr(buf);
	var windowFrames = windowParam.linlin(0, 1, 1000, bufFrames);

	// Y axis controls playback speed per voice
	// If quantized mode is enabled, snap to harmonic minor scale
	var quantRates, quantIdx, quantizedRate, useQuant;
	quantRates = [0.25, 0.297, 0.354, 0.397, 0.472, 0.53, 0.63, 0.75]; // Harmonic minor intervals mapped to rate domain
	useQuant = (('kaossQuantizedMode'.asSymbol).envirGet ? false).asBoolean;
	quantIdx = (padY * (quantRates.size - 1)).round.clip(0, quantRates.size - 1);
	quantizedRate = Select.kr(quantIdx, quantRates);
	rate = Select.kr(useQuant, [padY.linlin(0, 1, 0.25, 4.0), quantizedRate]);

	// Crossfade between old and new X positions
	// Use two lagged versions of padX for crossfade
	xLagOld = Lag.kr(padX, 0.08); // slower lag (old position)
	xLagNew = Lag.kr(padX, 0.01); // fast lag (new position)
	crossfade = (padX - xLagOld).abs.linlin(0, 0.05, 0, 1).clip(0, 1); // crossfade amount

	centerOld = xLagOld * bufFrames;
	centerNew = xLagNew * bufFrames;

	phase = Phasor.ar(0, BufRateScale.kr(buf) * rate, 0, windowFrames);

	readPhaseOld = (centerOld - (windowFrames * 0.5) + phase).wrap(0, bufFrames);
	readPhaseNew = (centerNew - (windowFrames * 0.5) + phase).wrap(0, bufFrames);

	sigOld = BufRd.ar(1, buf, readPhaseOld);
	sigNew = BufRd.ar(1, buf, readPhaseNew);

	sig = XFade2.ar(sigOld, sigNew, (crossfade * 2) - 1); // -1 = old, +1 = new

	// Gate envelope: quick fade in/out, voice frees itself on release
	env = EnvGen.kr(Env.asr(0.01, 1, 0.05), gate, doneAction: 2);

	sig = LeakDC.ar(sig);

	// Mono to stereo
	sig = sig ! 2;

	Out.ar(out, sig * env * amp * vol);
}).add;

SynthDef(\kaossRec, { |buf=0, ccBus=0|
	var sig, rec, ccVals;

	ccVals = In.kr(ccBus, 128);

	// Read record latch state from CC bus index 80
	rec = Select.kr(~busNames[\kaoss_rec].index, ccVals);

	sig = SoundIn.ar(0);

	// Record into buffer — single pass, non-looping
	RecordBuf.ar(sig, buf, run: rec, loop: 0);
}).add;

"SynthDefs \\kaossVoice and \\kaossRec are defined and added.".postln;
)
