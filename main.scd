(
Server.default.options.sampleRate = 48000;
//s.options.device = "ASIO";
//////// IMPOTRTS ///////////////////

~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "midi/config.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/scramble.scd");

s.waitForBoot{
	~buf = Buffer.read(
		s,
		"C:/Users/phi_n/Documents/Ableton/Studium Unterricht Sven/Unbenannt Project/Samples/Recorded/3-Audio 0001 [2020-11-30 083155].wav",
		action: {
			"Buffer loaded".postln;
			Synth(\scramble, [\buf, ~buf, \ccBus, ~ccBuses]);
			"Synth \scramble created!".postln;
			//	Synth(\test);
			//	"Synth \test created!".postln;
		}
	);
}
)

