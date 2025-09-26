
(
Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serverssetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "config/config.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/TapeSignal.scd");

s.waitForBoot{
    ~tapeBus = Bus.audio(s, 2);
	Synth(\TapeSignal, [\inBus, ~tapeBus, \ccBus, ~ccBuses]);
	"Synth \TapeSignal created!".postln;
}
)