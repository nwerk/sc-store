(
Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/scramble_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/scramble.scd");

s.waitForBoot{
	Synth(\scramble, [\buf, ~buf, \ccBus, ~ccBuses]);
	"Synth \scramble created!".postln;
}
)


