(
"Try Instantiate".postln;
SynthDef(\ape, { |ccBus=0, input_pitch=0, vol=0|
			var sig, pitch, ccVals, badness, wavemix = 1, sine, saw;
			var noiseL, noiseR, volSig, pitchSig, reverbSig;

			volSig = In.kr(vol);
			pitchSig = In.kr(input_pitch);
			ccVals = In.kr(ccBus, 128);
			badness = Select.kr(~busNames[\badness].index, ccVals);
			wavemix = Select.kr(~busNames[\wavemix].index, ccVals);

			noiseL = WhiteNoise.ar(1);
			noiseR = WhiteNoise.ar(1);
			
			// input_pitch = MouseY.kr(100, 3000, 1);
            //vol = MouseX.kr(0, 1);
    		//pitchSig.poll(1, "input_pitch");
    		//volSig.poll(1, "vol");
			badness = badness * 3;
			badness.poll(1, "badness");
			sig = [noiseL, noiseR];
			sig = LPF.ar(sig, 100);
			sig = sig + (LocalIn.ar(2, sig) * -1); // Use 2 channels for LocalIn
			sig = sig * badness;
			pitch = sig * pitchSig * 0.25;
			pitch = pitch + pitchSig;
			sine = [SinOsc.ar(pitch[0], 0, 1), SinOsc.ar(pitch[1], 0, 1)];
			saw = [LFSaw.ar(pitch[0], 0, 1), LFSaw.ar(pitch[1], 0, 1)];
			saw = LPF.ar(saw, 1200);
			sig = wavemix * sine + (1 - wavemix) * saw;
			sig = sig * volSig;
			LocalOut.ar(sig);
			reverbSig = FreeVerb.ar(sig, mix: 0.35, room: 0.9, damp: 0.5);

			Out.ar(\out.kr(0), reverbSig);
		}).add;

"SynthDef \ape is defined and added.".postln;
)