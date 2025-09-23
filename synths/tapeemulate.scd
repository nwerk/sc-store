(
"Try Instantiate".postln;
SynthDef(\ape, {
			var sig, pitch, vol;
			var ccVals = In.kr(ccBus, 128);
			var badness = Select.kr(~busNames[\badness].index, ccVals);

			pitch = MouseY.kr(100, 1000, 1);
            vol = MouseX.kr(0, 1);
            badness.poll;
            sig = WhiteNoise.ar(1);
            sig = LPF.ar(sig, 100);
            sig = sig + (LocalIn.ar(1, sig) * -1); // Provide 'sig' as default input to LocalIn
            sig = sig * badness;
            pitch = sig * pitch * 0.5;
            sig = SinOsc.ar(pitch, 0, 0.1);
            sig = sig * vol;
            sig = sig * vol;
            LocalOut.ar(sig);
			Out.ar(\out.kr(0), sig);
		}).add;


"SynthDef \ape is defined and added.".postln;
)