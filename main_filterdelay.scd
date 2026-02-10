(
Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/filter_delay_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/filter_delay.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");

s.waitForBoot{
	~freqBus = Bus.control(s, 1);
	~ampBus = Bus.control(s, 1);
	Synth(\tartiniTracker_sigmundStyle, [\inChan, 0, \freqBus, ~freqBus, \ampBus, ~ampBus]);
	"Synth \tartiniTracker_sigmundStyle created!".postln;
	Synth(\filterDelay, [\ccBus, ~ccBuses, \feedback, 5, \amp, 0.4, \vol, ~ampBus, \filterFreq, ~freqBus]);
	"Synth filterDelay created!".postln;
}
)



