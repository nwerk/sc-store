(
SynthDef(\scramble, {
			var sig, chain, size=512, chain2, sig2, del, ccBus = 0;
			var ccVals = In.kr(ccBus, 128);
			var vol = Select.kr(~busNames[\scramble_vol].index, ccVals);
			var dist = Select.kr(~busNames[\scramble_dist].index, ccVals);
			vol.poll;

			sig = SoundIn.ar(0);
			//sig = PlayBuf.ar(1, \buf.kr(0), BufRateScale.ir(\buf.kr(0)), loop:1);
			chain = FFT(LocalBuf(size), sig);
			chain2 = PV_BinScramble(
				buffer: chain,
				wipe: dist.linlin(0, 1, 0, 0.6),
				width: dist.linlin(0, 1, 0.02, 0.2), //MouseY.kr(0, 0.5).poll,
				trig: \trig.tr()
			);
			chain = PV_BinScramble(
				buffer: chain,
				wipe: dist.linlin(0, 1, 0, 0.6),
				width: dist.linlin(0, 1, 0, 0.2), //MouseY.kr(0, f0.5).poll,
				trig: \trig.tr()
			);

			sig = IFFT(chain) * vol;
			sig2 = IFFT(chain2) * vol;

			sig = [sig, sig2];
			//sig = sig.blend(del, 0.4);
			Out.ar(\out.kr(0), sig);
		}).add;


"SynthDef \scramble is defined and added.".postln;

SynthDef(\test, {
	var sig = SoundIn.ar(0);
	Out.ar(\out.kr(0), sig);
}).add;


"SynthDef \test is defined and added.".postln;
)