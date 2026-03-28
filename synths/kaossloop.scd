(
// Kaoss Pad loop scrubber — playback voice and loop recorder

SynthDef(\kaossVoice, { |out=0, buf=0, padX=0.5, padY=0.5, gate=1, ccBus=0, amp=0.5|
	var sig, env, phase, readPhase, rate;
	var ccVals = In.kr(ccBus, 128);
	var speed = Select.kr(~busNames[\kaoss_speed].index, ccVals);
	var vol = Select.kr(~busNames[\kaoss_vol].index, ccVals);
	var bufFrames = BufFrames.kr(buf);
	var center = padX * bufFrames;
	var windowFrames = padY.linlin(0, 1, 1000, bufFrames);

	// Expression pedal controls playback speed continuously
	rate = speed.linlin(0, 1, 0.25, 4.0);

	// Phasor sweeps through the window at buffer rate
	phase = Phasor.ar(0, BufRateScale.kr(buf) * rate, 0, windowFrames);

	// Wrap read position around buffer boundaries
	readPhase = (center - (windowFrames * 0.5) + phase).wrap(0, bufFrames);

	sig = BufRd.ar(1, buf, readPhase);

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
