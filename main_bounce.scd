Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "config/config.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/bouncing_ball.scd");

s.waitForBoot{
    // Define a scale (e.g. C major) and convert to Hz
    var scale = Scale.lydian.degrees;
    var root = 46; // MIDI note number for C3
    var octaves = [0, 12, 24, 36];
    var notes = scale.collect({ |deg| octaves.collect({ |oct| deg + root + oct }) }).flat;
    var freqs = notes.collect({ |n| n.midicps });
    
    Pbind(
        \instrument, \bouncingBallSmooth,
        \height, Pwhite(2, 15.0),           // height in meters (safe: 0.5 to 6)
        \gravity, 9.81,
        \loss, Pwhite(0.3, 0.5),               // loss factor (safe: 0.5 to 0.9)
        \amp, 0.8,
        \stopFreq, Pseq(freqs, inf),         // stop frequency from scale (Hz)
        \fadeTime, Pwhite(0.5, 9.5),         // fade time in seconds
        \pan, Pwhite(-1.0, 1.0),             // stereo pan
        \contactPitch, Pwhite(800, 5000),     // contact pitch from scale (Hz)
        \dur, Pwhite(4, 8)                  // time between triggers
    ).play;
}