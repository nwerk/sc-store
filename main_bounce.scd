Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "config/config.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/bouncing_ball.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");
s.waitForBoot{
    // Define a scale (e.g. C major) and convert to Hz
    var scale = Scale.harmonicMinor.degrees;
    var root = 46; // MIDI note number for C3
    var octaves = [0, 12, 24];
    var notes = scale.collect({ |deg| octaves.collect({ |oct| deg + root + oct }) }).flat;
    var freqs = notes.collect({ |n| n.midicps });
    ~freqBus = Bus.control(s, 1);
	~lagAmpBus = Bus.control(s, 1);

    Synth(\tartiniTracker_sigmundStyle, [\inChan, 0, \freqBus, ~freqBus, \lagAmpBus, ~ampBus, \holdLast, 1]);
    
    Pbind(
        \instrument, \bouncingBallSmooth,
        \height, Pwhite(1, 4.0),           // height in meters (safe: 0.5 to 6)
        \gravity, 9.81,
        \loss, Pwhite(0.3, 0.7),               // loss factor (safe: 0.5 to 0.9)
        \amp, 0.8,
    // snapshot the bus once per event (no continuous modulation)
    \stopFreq, Pfunc { ~freqBus.getSynchronous },         // stop frequency from scale (Hz)
        \fadeTime, Pwhite(2.5, 6.5),         // fade time in seconds
        \pan, Pwhite(-1.0, 1.0),             // stereo pan
    \contactPitch, Pfunc { ~freqBus.getSynchronous },     // contact pitch from scale (Hz)
        \dur, Pfunc {
            var v = ~lagAmpBus.getSynchronous.clip(0, 1);  // 0..1 avg amplitude
            v.clip(0.001, 1).explin(0.001, 1, 8.0, 0.5);
        }
    ).play;
}