(
Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serverssetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/stretched_overtones.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/stretched_overtones.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/inputToBus.scd");

s.waitForBoot {
	~freqBus = Bus.control(s, 1);
	~ampBus = Bus.control(s, 1);

    Synth(\tartiniTracker_sigmundStyle, [\inChan, 0, \freqBus, ~freqBus, \ampBus, ~ampBus, \holdLast, 1]);
	// Create the main synth, using the input bus
	Synth(\dynamicAdditiveSynth, [
		\inBus, ~ampBus,
		\freqBus, ~freqBus,
		\envBus, ~ampBus,
		\amp, 0.5,
		\maxDetune, 30,
		\minFreq, 50,
		\maxFreq, 1000,
		\minLPF, 500,
		\maxLPF, 5000,
		\reverbMix, 0.4
	]);

	    
    // Pbind(
	// 	\instrument, \dynamicAdditiveSynth,
	// 	\freq, Pseq([220, 246, 277, 329, 370, 415, 466, 523, 587, 659, 698, 784, 880, 987, 1046, 1175, 1318, 1397, 1568, 1760], inf).stutter(Pwhite(1, 4, inf)), // Chromatic scale, random repeats
	// 	\envAmp, Pwhite(0.5, 0.8), // Random amplitude between 0.5 and 0.8
	// 	\amp, 0.5,
	// 	\minFreq, 50,
	// 	\maxFreq, 1000,
	// 	\minLPF, 500,
	// 	\maxLPF, 5000,
	// 	\reverbMix, 0.65,     // contact pitch from scale (Hz)
    //     \dur, 0.4    
	// ).play;


	"Synth \dynamicAdditiveSynth created!".postln;
}
)


