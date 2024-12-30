(
Server.default.options.sampleRate = 48000;
//s.options.device = "ASIO";
//////// IMPOTRTS ///////////////////
thisProcess.interpreter.executeFile("C:/Users/phi_n/Documents/Programming/SuperCollider/NN_Synth_Control/midi/midiconfig.scd");
thisProcess.interpreter.executeFile("C:/Users/phi_n/Documents/Programming/SuperCollider/NN_Synth_Control/synths/scramble.scd");


SystemClock.sched(7, {
    ~buf = Buffer.read(s, "C:/Users/phi_n/Documents/Ableton/Studium Unterricht Sven/Unbenannt Project/Samples/Recorded/3-Audio 0001 [2020-11-30 083155].wav");

    "Buffer loaded".postln;
});

SystemClock.sched(8, {
    Synth(\scramble, [\buf, ~buf, \ccBus, ~ccBuses]);
    "Synth \scramble created!".postln;
//	Synth(\test);
//	"Synth \test created!".postln;
});
)