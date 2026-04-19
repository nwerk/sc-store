SynthDef.new(\fftFreeze, {
	|
	micIn=0,
	granIn=0,
	out=0,
	ccBus=0,
	freeze=0,
	fftFilterAmt=0,
	morphAmt=0
	|
	var ccVals, micSig, granSig, micChain, granChain, morphedChain, sig, wipe;

	ccVals = In.kr(ccBus, 128);
	freeze = Select.kr(~busNames[\fftFreeze].index, ccVals);
	fftFilterAmt = Select.kr(~busNames[\fftFilter].index, ccVals);
	morphAmt = Select.kr(~busNames[\fftMorph].index, ccVals);

	micSig = In.ar(micIn, 1);
	granSig = In.ar(granIn, 1);

	micChain = FFT(LocalBuf(2048), micSig);
	granChain = FFT(LocalBuf(2048), granSig);

	micChain = PV_Freeze(micChain, freeze);
	wipe = fftFilterAmt.linlin(0, 1, 0, -1);
	micChain = PV_BrickWall(micChain, wipe);
	morphedChain = PV_Morph(micChain, granChain, morphAmt);

	sig = IFFT(morphedChain);
	Out.ar(out, sig ! 2);
}).add;

"SynthDef \\fftFreeze added to server.".postln;
