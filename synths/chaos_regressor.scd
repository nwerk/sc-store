// Chaotic feedback synth controlled by FluCoMa MLP Regressor.
// XY position is mapped to 10 synthesis parameters via a trained neural network.
//
// Requires: FluCoMa (https://www.flucoma.org/download/)
// Install via: Quarks.install("FluCoMa")
//
// Exposes the following environment variables after load:
//   ~xybuf      - Buffer(2)  : current XY input (set from OSC/MIDI)
//   ~paramsbuf  - Buffer(10) : current parameter values (read by synth + sent to TouchOSC)
//   ~xydata     - FluidDataSet : training XY points
//   ~paramsdata - FluidDataSet : training parameter points
//   ~mlp        - FluidMLPRegressor : trained model
//   ~chaosCounter - Int : current number of training points stored
//
// SynthDef \chaosRegressor args:
//   predicting (0/1) : whether the MLP is actively mapping XY -> params

(
~xybuf     = Buffer.alloc(s, 2);
~paramsbuf = Buffer.alloc(s, 10);

~xydata     = FluidDataSet(s);
~paramsdata = FluidDataSet(s);

~chaosCounter = 0;

~mlp = FluidMLPRegressor(s,
	[7],
	activation: FluidMLPRegressor.sigmoid,
	outputActivation: FluidMLPRegressor.sigmoid,
	maxIter: 1000,
	learnRate: 0.1,
	batchSize: 1,
	validation: 0
);

SynthDef(\chaosRegressor, {
	arg predicting = 0;
	var osc1, osc2, feed1, feed2, base1 = 69, base2 = 69, base3 = 130, loud1, loud2;
	var val, xy, trig;

	xy   = FluidBufToKr.kr(~xybuf);
	trig = Mix(Changed.kr(xy));
	~mlp.kr(trig * predicting, ~xybuf, ~paramsbuf);
	val  = FluidBufToKr.kr(~paramsbuf);
	SendReply.kr(Mix(Changed.kr(val)), "/paramsChanged", val);

	#feed2, feed1 = LocalIn.ar(2);

	loud1 = FluidLoudness.kr(feed1, [\loudness], 1, 0, hopSize: 64);
	loud2 = FluidLoudness.kr(feed2, [\loudness], 1, 0, hopSize: 64);

	osc1 = SinOsc.ar(
		(((feed1 * val[0]) + val[1]) * base1).midicps,
		mul: (val[2] * 50).dbamp
	).atan;
	osc1 = MoogFF.ar(
		osc1,
		(base3 - (val[3] * (loud2.clip(-120, 0) + 120))).lag(128 / 44100).midicps,
		val[4] * 3.5
	);

	osc2 = SinOsc.ar(
		(((feed2 * val[5]) + val[6]) * base2).midicps,
		mul: (val[7] * 50).dbamp
	).atan;
	osc2 = MoogFF.ar(
		osc2,
		(base3 - (val[8] * (loud1.clip(-120, 0) + 120))).lag(128 / 44100).midicps,
		val[9] * 3.5
	);

	Out.ar(0, LeakDC.ar([osc1, osc2], mul: 0.1));
	LocalOut.ar([osc1, osc2]);
}).add;

"chaos_regressor.scd loaded.".postln;
)
