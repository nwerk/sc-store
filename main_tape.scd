(
Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/tape_fx_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/tapeemulate.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");

s.waitForBoot{
	~freqBus = Bus.control(s, 1);
	~ampBus = Bus.control(s, 1);
	~tracker = ~polyTrackerNew.(s, (inChan: 0, freqBus: ~freqBus, ampBus: ~ampBus)).start;
	"Polyphonic tracker started!".postln;
	Synth(\ape, [\ccBus, ~ccBuses, \input_pitch, ~freqBus.index, \vol, ~ampBus.index]);
	"Synth ape created!".postln;
}
)



