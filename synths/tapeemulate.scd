(
"Try Instantiate".postln;
SynthDef(\ape, {
			var sig, pitch, vol, input_pitch, ccBus = 0;
			var sine, saw;
			var ccVals = In.kr(ccBus, 128);
			var badness = Select.kr(~busNames[\badness].index, ccVals);
			var wavemix = Select.kr(~busNames[\wavemix].index, ccVals);
			// Stereo white noise
			var noiseL = WhiteNoise.ar(1);
			var noiseR = WhiteNoise.ar(1);
			
			input_pitch = MouseY.kr(100, 3000, 1);
            vol = MouseX.kr(0, 1);
			//input_pitch.poll;
			//vol.poll;
			badness = badness * 3;
			
			sig = [noiseL, noiseR];
			sig = LPF.ar(sig, 100);
			sig = sig + (LocalIn.ar(2, sig) * -1); // Use 2 channels for LocalIn
			sig = sig * badness;
			pitch = sig * input_pitch * 0.5;
			pitch = pitch + input_pitch;
			sine = [SinOsc.ar(pitch[0], 0, 1), SinOsc.ar(pitch[1], 0, 1)];
			saw = [LFSaw.ar(pitch[0], 0, 1), LFSaw.ar(pitch[1], 0, 1)];
			sig = wavemix * sine + (1 - wavemix) * saw;
			sig = sig * vol;
			LocalOut.ar(sig);
			Out.ar(\out.kr(0), sig);
		}).add;

"SynthDef \ape is defined and added.".postln;
)