// Standalone cembalo: guitar in -> polyphonic pitch tracker -> plucked cembalo voices out.
// No tablet, OSC or MIDI needed: it plays as soon as the server has booted.
//
//   sclang main_cembalo.scd          (or ./run-sc-main_cembalo.sh on the Pi)
//
// Change the sound in SETTINGS below. While it runs, the interpreter also takes e.g.
//   ~cembalo.set(\noise, 1);   ~cembalo.set(\volume, 0.6);   ~dry.set(\amp, 0.3)
(
//////// SETTINGS ///////////////////
~settings = (
	inChan: 0,            // guitar input (0 = first input of the audio interface)
	volume: 0.9,          // cembalo output level
	dry: 0.0,             // dry guitar mixed to the outputs (0 = cembalo only)
	revMix: 0.22, room: 0.89,
	// sound (0..1 unless noted), see synths/cembalo.scd
	bright: 0.1, noise: 0.7, warmth: 0.9, weird: 0.5, octave: 0.25,
	decay: 3.0,           // ring time of a 220 Hz note in seconds (lower notes ring longer)
	// touch: guitar input level (dBFS RMS over 10 ms) that counts as the softest / hardest pick
	velDbLo: -50, velDbHi: -12, velCurve: 1.2, velRange: 30,
	maxVoices: 12,
	statsEvery: 0         // seconds between tracker load reports in the post window (0 = off)
);

Server.killAll;
//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/cembalo.scd");

// guitar input onto a bus (velocity follower) and, optionally, dry to the outputs
SynthDef(\cembaloGuitarIn, { |in=0, out=0, dryOut=0, amp=0|
	var sig = SoundIn.ar(in);
	Out.ar(out, sig);
	Out.ar(dryOut, (sig * amp.lag(0.1)) ! 2);
}).add;

s.waitForBoot {
	var st = ~settings;
	~micBus = Bus.audio(s, 1);
	s.sync;

	~dry = Synth(\cembaloGuitarIn, [\in, st[\inChan], \out, ~micBus, \dryOut, 0, \amp, st[\dry]], s.defaultGroup, \addToHead);

	~tracker = ~polyTrackerNew.(s, (inChan: st[\inChan])).start;

	~cembalo = ~cembaloNew.(s, ~tracker, (inBus: ~micBus, out: 0, maxVoices: st[\maxVoices], volume: st[\volume]));
	[\revMix, \room, \bright, \noise, \warmth, \weird, \octave, \decay, \velDbLo, \velDbHi, \velCurve, \velRange].do { |k|
		~cembalo.set(k, st[k]);
	};
	~cembalo.enable(true);

	if(st[\statsEvery] > 0) {
		~statsRoutine = Routine {
			loop {
				st[\statsEvery].wait;
				"cembalo: % voices ringing, tracker load % %".format(~cembalo.voices.size, (~tracker[\load] * 100).round(0.1), "%").postln;
			};
		}.play(AppClock);
	};

	"Cembalo booted: play the guitar.".postln;
};
)
