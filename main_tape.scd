(
Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "config/config.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/tapeemulate.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");

s.waitForBoot{
	~freqBus = Bus.control(s, 1);
	~ampBus = Bus.control(s, 1);
	Synth(\tartiniTracker_sigmundStyle, [\inChan, 0, \freqBus, ~freqBus, \ampBus, ~ampBus]);
	"Synth \tartiniTracker_sigmundStyle created!".postln;
	Synth(\ape, [\ccBus, ~ccBuses, \input_pitch, ~freqBus.index, \vol, ~ampBus.index]);
	"Synth ape created!".postln;
	
}
)



