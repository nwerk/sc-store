Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/bouncing_ball_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/bouncing_ball.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");
s.waitForBoot{
    ~freqBus = Bus.control(s, 1);
	~lagAmpBus = Bus.control(s, 1);

    Synth(\tartiniTracker_sigmundStyle, [\inChan, 0, \freqBus, ~freqBus, \lagAmpBus, ~ampBus, \holdLast, 1]);
    
    MIDIdef.cc(\bounceTrigger, { |val, ccNum, chan, src|
    var trigIndex = if(
        ~busNames.notNil and: { ~busNames[\trigger].notNil and: { ~busNames[\trigger][\index].notNil } }
    ) { ~busNames[\trigger][\index] } { 81 };

    if (ccNum == trigIndex and: { val == 127 }) {
        // Read freq once (falls back if not ready)
        var f = if(~freqBus.notNil) { ~freqBus.getSynchronous } { 440 };
        Synth(\bouncingBallSmooth, [
            \height, 1.0.rrand(4.0),
            \loss, 0.3.rrand(0.7),
            \fadeTime, 2.5.rrand(6.5),
            \pan, (-1.0).rrand(1.0),
            \amp, 0.8,
            \stopFreq, f,
            \contactPitch, f,
            \rateMultiplier, 1
        ]);
        "Synth triggered!".postln;
    };
    });
};