(
Server.killAll;
//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/kaoss_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/kaossloop.scd");
thisProcess.interpreter.executeFile(~basePath ++ "osc/oscconfig.scd");

s.waitForBoot {
	// Allocate loop buffer: 8 seconds mono at server sample rate
	~loopBuf = Buffer.alloc(s, s.sampleRate * 8, 1);
	"Loop buffer allocated (8 seconds).".postln;

	// Start the recorder synth (listens to footswitch CC 80 latch via ccBus)
	~recSynth = Synth(\kaossRec, [\buf, ~loopBuf, \ccBus, ~ccBuses]);
	"Recorder synth started (press FS-1-WL footswitch 1 to record).".postln;

	// Buffer clear handler: when footswitch 2 (CC 81) latches on, zero the buffer
	MIDIdef.cc(\kaossClear, { |val, ccNum, chan, src|
		if (ccNum == ~busNames[\kaoss_clear][\index] and: { val == 127 }) {
			~loopBuf.zero;
			"Loop buffer cleared!".postln;
		};
	});

	"Kaoss Pad patch ready. Touch the pad to play loops.".postln;
};
)
