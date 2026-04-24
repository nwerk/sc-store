SynthDef.new(\fftFreeze, {
	|
	micIn=0,
	granIn=0,
	out=0,
	ccBus=0,
	freeze=0,
	fftFilterAmt=0,
	morphAmt=0,
	fftVol=0
	|
	var ccVals, micSig, granSig, micChain, micChainCopy,
	    granChainL, granChainR, granCopyL, dryFrozenL, dryFrozenR,
	    morphedChainL, morphedChainR,
	    fftSig, wipe;

	ccVals = In.kr(ccBus, 128);
	freeze       = Select.kr(~busNames[\fftFreeze].index,    ccVals);
	fftFilterAmt = Select.kr(~busNames[\fftFilter].index,    ccVals);
	morphAmt     = Select.kr(~busNames[\fftMorph].index,     ccVals);
	fftVol       = Select.kr(~busNames[\fftFreezeVol].index, ccVals);

	micSig  = In.ar(micIn,  1);
	granSig = In.ar(granIn, 2);  // stereo granular

	// Frozen + filtered mic chain (shared source for both stereo paths)
	micChain = FFT(LocalBuf(2048), micSig);
	micChain = PV_Freeze(micChain, freeze);
	// lincurve with negative curve (concave): filter reaches lower bins at mid-range
	// slider values, giving perceptually distributed control over the frequency spectrum.
	wipe     = fftFilterAmt.lincurve(0, 1, 0, -1, -3);
	micChain = PV_BrickWall(micChain, wipe);

	// Duplicate frozen mic chain for independent L and R morphing
	micChainCopy = PV_Copy(micChain, LocalBuf(2048));

	// Separate FFT chains for stereo granular
	granChainL = FFT(LocalBuf(2048), granSig[0]);
	granChainR = FFT(LocalBuf(2048), granSig[1]);

	// Save dry frozen references for crossfading before destructive processing
	dryFrozenL = PV_Copy(micChain,     LocalBuf(2048));
	dryFrozenR = PV_Copy(micChainCopy, LocalBuf(2048));
	granCopyL  = PV_Copy(granChainL,   LocalBuf(2048)); // MagDiv needs a copy since CopyPhase consumes granChainL

	// L: phase substitution (frozen mags + grain phases) → spectral division
	//    bins that are loud in the grain get attenuated in the frozen spectrum (inverse vocoder)
	PV_CopyPhase(micChain, granChainL);
	PV_MagDiv(micChain, granCopyL, 0.001);

	// R: smear frozen bins (amount scales with morphAmt) → inject grain phases
	//    produces a diffuse, pitch-smeared spectral blur driven by grain movement
	PV_MagSmear(micChainCopy, (morphAmt * 20).round.max(0));
	PV_CopyPhase(micChainCopy, granChainR);

	// Crossfade: morphAmt 0 = dry frozen, 1 = full weird (L: inverse-vocoder, R: smeared+phased)
	morphedChainL = PV_Morph(dryFrozenL, micChain,     morphAmt);
	morphedChainR = PV_Morph(dryFrozenR, micChainCopy, morphAmt);

	// FFT signal: gated by freeze state (smooth 15ms fade), then scaled by fftVol
	fftSig = [IFFT(morphedChainL), IFFT(morphedChainR)] * Lag.kr(freeze, 0.015) * fftVol;

	// Mix FFT effect with dry stereo granular.
	// fftFreezeVol scales the FFT (freeze/morph) layer independently;
	// granular level is managed upstream by masterVol (CC 62) in the gran synth.
	Out.ar(out, fftSig + granSig);
}).add;

"SynthDef \\fftFreeze added to server.".postln;
