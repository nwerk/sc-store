(
"Try Instantiate".postln;
SynthDef(\ape, { |ccBus=0, input_pitch=0, vol=0|
			var sig, pitch, ccVals, badness, wavemix = 0, waveMap, badnessMap, sine, saw;
			var noiseL, noiseR, volSig, pitchSig, reverbSig;
			var reverb_mix, reverb_room;
			var master_vol = 1;

			volSig = In.kr(vol);
			pitchSig = In.kr(input_pitch);
			ccVals = In.kr(ccBus, 128);

			badness = Select.kr(~busNames[\badness].index, ccVals);
			wavemix = Select.kr(~busNames[\wavemix].index, ccVals);
			waveMap = Select.kr(~busNames[\wavemap].index, ccVals);
			badnessMap = Select.kr(~busNames[\badnessmap].index, ccVals);

			reverb_mix = Select.kr(~busNames[\reverb_mix].index, ccVals);
			reverb_room = Select.kr(~busNames[\reverb_room].index, ccVals);

			master_vol = Select.kr(~busNames[\master].index, ccVals);
			noiseL = WhiteNoise.ar(1);
			noiseR = WhiteNoise.ar(1);
			
			// input_pitch = MouseY.kr(100, 3000, 1);
            //vol = MouseX.kr(0, 1);
    		//pitchSig.poll(1, "input_pitch");
    		//volSig.poll(1, "vol");
			badness = badness * 7;
			badness = badness * volSig; // Scale badness by volume control
			badness = (badness + (badnessMap * volSig)).clip(0,7);
			badness.poll(1, "badness");
			sig = [noiseL, noiseR];
			sig = LPF.ar(sig, 100);
			sig = sig + LeakDC.ar((LocalIn.ar(2, sig) * -1), 0.995); // Use 2 channels for LocalIn
			sig = sig * badness;
			pitch = sig * pitchSig * 0.25;
			pitch = pitch + pitchSig;
			sine = [SinOsc.ar(pitch[0], 0, 1), SinOsc.ar(pitch[1], 0, 1)];
			saw = [LFSaw.ar(pitch[0], 0, 1), LFSaw.ar(pitch[1], 0, 1)];
			saw = LPF.ar(saw, 2500);
			wavemix = (wavemix + (waveMap * volSig)).clip(0,1);
			volSig.poll;
			sig = (wavemix * saw) + ((1 - wavemix) * sine);
			sig = sig * volSig;
			LocalOut.ar(sig);
			reverbSig = FreeVerb.ar(sig, mix: reverb_mix, room: reverb_room, damp: 0.5);
			reverbSig = reverbSig * master_vol;
			Out.ar(\out.kr(0), reverbSig);
		}).add;

"SynthDef \ape is defined and added.".postln;
)