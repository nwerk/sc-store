(
"Try Instantiate".postln;
SynthDef(\ape, {
			var sig, pitch, vol, input_pitch, ccBus = 0;
			var ccVals = In.kr(ccBus, 128);
			var badness = Select.kr(~busNames[\badness].index, ccVals);

			input_pitch = MouseY.kr(100, 3000, 1);
            vol = MouseX.kr(0, 1);
			input_pitch.poll;
			vol.poll;
            sig = WhiteNoise.ar(1);
            sig = LPF.ar(sig, 100);
            sig = sig + (LocalIn.ar(1, sig) * -1); // Provide 'sig' as default input to LocalIn
            sig = sig * badness;
            pitch = sig * input_pitch * 0.5;
			pitch = pitch + input_pitch;
			sig = SinOsc.ar(pitch, 0, 0.1);
            sig = sig * vol;
            LocalOut.ar(sig);
			Out.ar(\out.kr(0), sig ! 2);
		}).add;


"SynthDef \ape is defined and added.".postln;
)