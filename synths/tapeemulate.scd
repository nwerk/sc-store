(
"Try Instantiate".postln;
SynthDef(\ape, {
			var sig, pitch, vol;
			var ccVals = In.kr(ccBus, 128);
			var badness = Select.kr(~busNames[\badness].index, ccVals);

            badness.poll;
            sig = WhiteNoise.ar(1);
            sig = LPF.ar(sig, 100);
            sig = sig + (LocalIn.ar(1, sig) * -1); // Provide 'sig' as default input to LocalIn
            sig = sig * badness;
            transformed_pitch = sig * pitch * 0.5;
			transformed_pitch = transformed_pitch + pitch;
			sig = SinOsc.ar(transformed_pitch, 0, 0.1);
            sig = sig * vol;
            LocalOut.ar(sig);
			Out.ar(\out.kr(0), sig);
		}).add;


"SynthDef \ape is defined and added.".postln;
)

(
s.waitForBoot{
	Synth(\ape);
	"Synth ape created!".postln;
}
)
