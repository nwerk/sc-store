// Self-oscillating delay instrument with bandpass filter in feedback path
// BPF selects harmonics of the delay pitch; tanh provides variable distortion
// Micro-detuned stereo delay times for spatial width
(
SynthDef(\delayInstrument, { |out=0, inChan=0,
	delayTime=0.01, feedback=0.8, filterRatio=1.0, filterRq=0.1,
	distortion=1.0, dryWet=0.5, microDetune=0.5, inputGain=1.0, amp=1.0|

	var input, fb, delSigL, delSigR, delSig;
	var dtL, dtR, detuneAmt;
	var delayPitch, bpfFreq;
	var drive, sig;

	// Mono input from line-in
	input = SoundIn.ar(inChan) * inputGain;

	// Read feedback from previous cycle
	fb = LocalIn.ar(2);

	// Micro-detuned stereo: slightly different L/R delay times for width
	detuneAmt = microDetune * 0.003;
	dtL = Lag.kr((delayTime * (1 - detuneAmt)).clip(0.0001, 2.0), 0.05);
	dtR = Lag.kr((delayTime * (1 + detuneAmt)).clip(0.0001, 2.0), 0.05);

	// Stereo delay lines: input mixed with feedback
	delSigL = DelayL.ar(input + fb[0], maxdelaytime: 2.0, delaytime: dtL);
	delSigR = DelayL.ar(input + fb[1], maxdelaytime: 2.0, delaytime: dtR);
	delSig = [delSigL, delSigR];

	// Bandpass filter in feedback path — selects harmonics of delay pitch
	delayPitch = 1.0 / delayTime.max(0.0001);
	bpfFreq = Lag.kr((delayPitch * filterRatio).clip(20, 20000), 0.02);
	delSig = BPF.ar(delSig, bpfFreq, filterRq.clip(0.01, 1.0));

	// Feedback amount and tanh distortion (separated for independent control)
	// distortion controls tanh drive: 1.0 = gentle, higher = harder clipping
	drive = Lag.kr(distortion, 0.05);
	delSig = (delSig * Lag.kr(feedback, 0.05) * drive).tanh;

	// Write feedback for next cycle
	LocalOut.ar(delSig);

	// Dry/wet mix
	sig = (input.dup * (1 - dryWet)) + (delSig * dryWet);

	// Per-voice amplitude (used for lift-mode silence)
	sig = sig * Lag.kr(amp, 0.05);

	// Safety limiter + DC removal
	sig = LeakDC.ar(sig);
	sig = Limiter.ar(sig, 0.95, 0.01);

	Out.ar(out, sig);
}).add;

"SynthDef \\delayInstrument added.".postln;
)
