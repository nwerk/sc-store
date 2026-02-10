(
Server.killAll;
//////// IMPOTRTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/granular_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/granular.scd");

s.waitForBoot{
    b = Buffer.readChannel(s, "C:/Users/phi_n/Documents/SuperCollider/Recordings/SC_250113_112227.wav", channels: 1);
	~micBus = Bus.audio(s, 1);
    ~ptrBus = Bus.audio(s, 1);
	s.sync;
    ~micGrp = Group.new;
    ~ptrGrp = Group.after(~micGrp);
    ~recGrp = Group.after(~ptrGrp);
    ~granGrp = Group.after(~recGrp);
	s.sync;
    Synth(\mic, [\in, 0, \out, ~micBus], ~micGrp);
    Synth(\ptr, [\out, ~ptrBus, \buf, b], ~ptrGrp);
    //Synth(\rec, [\ptrIn, ~ptrBus, \micIn, ~micBus, \buf, b, \fb, 0.6], ~recGrp);
    //~ccBuses.postln;
    Synth(\gran, [
		\ccBus, ~ccBuses, // pass the entire map of CC buses
        \amp, 0.05,
		\buf, b,
		\out, 0,
		\atk, 0,
		\rel, 1,
		\gate, 1,
		\sync, 0,
		\dens, 10,
		\baseDur, 0.2,
		\durRand, 0.1,
		\rate, 0.5,
		\rateRand, 1.025,
		\panRand, 1,
		\grainEnv, -1,	
		\ptrBus, ~ptrBus,
		\ptrSampleDelay, 44100 * 2,
		\ptrRandSamples, 44100 * 0.5,
 		\minPtrDelay, 44100,
	    \filterFreq, 15000,
		\octaveJump, 1// ~octaveJump//~ccBuses[\octaveJump].index  // added octaveJump CC bus
    ], ~granGrp);
	"Synth \gran created!".postln;
	s.meter;
	//PlayBuf.ar(1, b, BufRateScale.kr(b), loop: 1).out; // play original buffer for reference
};
)

