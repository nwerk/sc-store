// TapeSignal.scd
// Tape-like delay effect with low added latency (uses a short internal delay for modulation but
// simulates long tape feel via feedback, saturation and filtering rather than huge real-time buffer)
(
SynthDef(\TapeSignal, { |inBus = 0, outBus = 0, ccBus = 0, delayTime = 0.2, maxDelay = 1.0, feedback = 0.3,
	wowRate = 0.2, wowDepth = 0.002, flutterRate = 8.0, flutterDepth = 0.0005,
	saturation = 0.8, headCut = 800, headQ = 1.0|
	
	var ccVals = In.kr(ccBus, 128);
	var mix = Select.kr(~busNames[\mix].index, ccVals);
	// Input
	var inSig = In.ar(inBus, 2);
	var sig = inSig;
	
	// Delay line: keep maxDelay moderate to avoid huge latency. We emulate larger "tape-like" sense with
	// feedback, saturation and head filtering rather than extremely long delays.
	var maxD = maxDelay.max(0.01);
	var baseDelay = delayTime.clip(0.001, maxD);
	
	// Low-rate wow and flutter modulation (small depth to keep latency jitter low)
	var wow = SinOsc.kr(wowRate, 0, wowDepth, 1); // slow pitch-like modulation
	var flutter = LFNoise1.kr(flutterRate).range(-1 * flutterDepth, flutterDepth);
	var modDelay = baseDelay * (1 + wow + flutter);
	
	// Stereo spread: slightly different delays for left/right for a tape-head effect
	var leftDelay = modDelay * 0.9999; // tiny offset
	var rightDelay = modDelay * 1.0001;
	
	// Feedback path with filtering to simulate tape head and loss
	var fb = LocalIn.ar(2);
	var fbMix = fb * feedback;
	var fbSat = (fbMix * (1 + saturation)).tanh;
	var write = sig + fbSat;
	
	// Apply delay to the combined signal
	var outDelL = DelayL.ar(write[0], maxD, leftDelay);
	var outDelR = DelayL.ar(write[1], maxD, rightDelay);
	var outDelayed = [outDelL, outDelR];
	
	// Tape-head filter: gentle lowpass/band shaping
	var headFiltered = RLPF.ar(outDelayed, headCut.max(20), headQ.max(0.1));
	
	// Apply saturation to the final delayed signal
	var satDelayed = (headFiltered * (1 + saturation)).tanh;
	
	// Mix dry/wet
	var out = XFade2.ar(sig, headFiltered, (mix * 2) - 1);
	
	// Write back feedback into LocalIn to create recursive feedback
	LocalOut.ar(satDelayed);
	
	// Output
	Out.ar(outBus, out);
}).add;
)