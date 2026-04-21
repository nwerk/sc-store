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
	    granChainL, granChainR, morphedChainL, morphedChainR,
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
	// .squared gives exponential taper: finer control at low filter amounts
	wipe     = fftFilterAmt.squared.linlin(0, 1, 0, -1);
	micChain = PV_BrickWall(micChain, wipe);

	// Duplicate frozen mic chain for independent L and R morphing
	micChainCopy = PV_Copy(micChain, LocalBuf(2048));

	// Separate FFT chains for stereo granular
	granChainL = FFT(LocalBuf(2048), granSig[0]);
	granChainR = FFT(LocalBuf(2048), granSig[1]);

	// Stereo morph: frozen mic × granular L and R independently
	morphedChainL = PV_Morph(micChain,     granChainL, morphAmt);
	morphedChainR = PV_Morph(micChainCopy, granChainR, morphAmt);

	// FFT signal with independent volume control
	fftSig = [IFFT(morphedChainL), IFFT(morphedChainR)] * fftVol;

	// Mix FFT effect with dry stereo granular.
	// fftFreezeVol scales the FFT (freeze/morph) layer independently;
	// granular level is managed upstream by masterVol (CC 62) in the gran synth.
	Out.ar(out, fftSig + granSig);
}).add;

"SynthDef \\fftFreeze added to server.".postln;
