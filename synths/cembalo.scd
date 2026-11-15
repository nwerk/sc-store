// Cembalo: a weird, warm, plucky harpsichord with a lot of string noise, played by the polyphonic tracker.
//
// Every note-on of the tracker plucks one voice. Only the onset matters: the envelope is a one-shot pluck whose
// level, brightness, sustain, pitch "twang" and amount of pick noise are set by the note's velocity; note-offs are
// ignored and the string rings out (re-plucking the same pitch damps the previous string, like on a real cembalo).
//
// Velocity = how hard the string was hit, measured in scsynth from the guitar input: the RMS of the last 10 ms
// (\cembaloVel writes it continuously to a control bus in dBFS), peak-held over the first 8 ms of each voice.
// This follows the pick dynamics far more closely than the tracker's note amplitude.
//
// Per voice (new notes take the current ~cembalo.params; change with ~cembalo.set(\key, value)):
//   bright  0..1  quill brightness          noise   0..1  pick scrape, string rattle, squeaks
//   warmth  0..1  body, saturation, darker  weird   0..1  detune between strings, pitch twang, wobble, squeaks
//   octave  0..1  level of the 4' string   decay   s     ring time of a 220 Hz note (lower notes ring longer)
//   velDbLo / velDbHi  input level (dBFS RMS) mapped to velocity 0 / 1;  velCurve  >1 = softer notes quieter
//   velRange  dB between the softest and the hardest pluck;  amp  voice level
// Output stage (\cembaloOut, one instance): volume, revMix, room.
//
// CPU: a note is two synths in one group. \cembalo is the string (strings, body, rattle); \cembaloAttack is
// everything that is over after 150 ms (pick scrape, squeak, key thump) and frees itself then, instead of
// computing silence for the rest of the note. Both go through the same lowpass, envelope and panning, so their sum
// is the same signal as one synth computing all of it (a lowpass of a sum is the sum of the lowpasses).
// The string frees its group as soon as its output has stayed below -100 dBFS for 50 ms, which is after about half
// of the envelope's length. Measured: a ringing note costs a third less, and lives half as long.
(
SynthDef(\cembaloVel, { |in=0, out=0|
	var x = In.ar(in), n = (0.01 * SampleRate.ir).round;
	var rms = (RunningSum.ar(x.squared, n) / n).max(0).sqrt;
	Out.kr(out, A2K.kr(rms.max(1e-6).ampdb));
}).add;

SynthDef(\cembalo, { |out=0, freq=220, velBus=0, amp=0.5, decay=3.0, bright=0.5, noise=0.7, warmth=0.5,
	weird=0.5, octave=0.25, velDbLo= -50, velDbHi= -12, velCurve=1.2, velRange=30, pan=0, gate=1|
	var vel, velAmp, dec, fr, detune, coef, trig, exc, strings, oct, sig, body, drive;
	var buzz, env, choke;

	// velocity: peak input level over the first 8 ms (the tracker can fire just before the attack's peak), then held
	vel = Gate.kr(RunningMax.kr(In.kr(velBus)), Line.kr(1, -1, 0.008));
	vel = vel.linlin(velDbLo, velDbHi, 0, 1) ** velCurve;
	velAmp = ((vel - 1) * velRange).dbamp;

	// ring time: low strings ring longer, hard plucks a little longer
	dec = decay * ((freq / 220) ** -0.35);

	// pitch: harder plucks start sharp and settle (string tension), a slow drift, two choirs detuned against each other
	fr = freq * ((EnvGen.kr(Env([1, 0], [0.07], -4)) * (2 + (vel * 14 * weird))
		+ LFNoise2.kr(0.3, 4 * weird)) / 100).midiratio;
	detune = Rand(1.5, 3.5) * (0.4 + (1.6 * weird));  // cents

	// quill: a click plus a few ms of noise, brighter when hit harder; the comb at the pluck point makes it nasal
	trig = Impulse.ar(0);
	exc = (WhiteNoise.ar * EnvGen.ar(Env.perc(0.0002, 0.006))) + (trig * 3);
	exc = LPF.ar(exc, (vel.linexp(0, 1, 1800, 12000) * (0.4 + bright)).clip(200, 18000));
	exc = exc - DelayC.ar(exc, 0.05, Rand(0.09, 0.16) / freq);

	// strings: Karplus-Strong with damping in the loop; harder and brighter = less damping
	coef = (0.6 - (vel * 0.3) - (bright * 0.3) + (warmth * 0.25)).clip(0.05, 0.92);
	strings = [-1, 1].collect { |sgn|
		Pluck.ar(exc, trig, 1/30, 1 / (fr * (sgn * detune / 100).midiratio), dec * (0.7 + (0.6 * vel)), coef)
	};
	oct = Pluck.ar(exc, trig, 1/30, 1 / (2 * fr * (detune / 200).midiratio), dec * 0.5, coef * 0.8) * octave;
	sig = strings + oct;  // 8' choirs left / right, 4' in the middle

	// warmth: soundboard resonances, soft saturation, darker top
	body = sig.collect { |c| BPF.ar(c, [170, 410, 1100], [0.7, 0.6, 0.5], [1.0, 0.7, 0.35]).sum };
	sig = sig + (body * warmth * 1.5);
	drive = 1 + (warmth * 3);
	sig = (sig * drive).tanh / drive * 1.6;

	// string noise (all of it goes through the warmth lowpass below, so it stays woody rather than hissy)
	// rattle: band-limited noise riding on the string's own amplitude (squared, so it fades faster than the note):
	// the quill and the strings sizzle while the note is loud
	// (pick scrape, squeak and key thump: \cembaloAttack)
	buzz = sig.collect { |c| BPF.ar(WhiteNoise.ar, Rand(1500, 3200), 1.2) * Lag.ar(c.abs, 0.004).squared } * 12;
	sig = sig + (buzz * noise);
	sig = LPF.ar(sig, warmth.linexp(0, 1, 14000, 3200));

	// one-shot envelope from the onset; gate=0 only chokes the voice (same pitch re-plucked, voice limit).
	// Done.freeGroup: the note's group, i.e. this synth and its \cembaloAttack if that is still there.
	env = EnvGen.kr(Env.perc(0.0005, dec * 2.5, 1, -5), doneAction: Done.freeGroup);
	choke = EnvGen.kr(Env.asr(0, 1, 0.04), gate, doneAction: Done.freeGroup);
	sig = sig * env * choke * velAmp * amp;
	// rung out: below -100 dBFS (far under the noise floor of any converter) long before the envelope ends
	DetectSilence.ar(sig[0].abs + sig[1].abs, 0.00001, 0.05, doneAction: Done.freeGroup);
	Out.ar(out, Balance2.ar(sig[0], sig[1], pan));
}).add;

// The parts of a pluck that are over after 150 ms. Same arguments as \cembalo (not all are used), started in the
// same bundle, so it measures the same velocity and applies the same lowpass, envelope, level and panning.
SynthDef(\cembaloAttack, { |out=0, freq=220, velBus=0, amp=0.5, decay=3.0, bright=0.5, noise=0.7, warmth=0.5,
	weird=0.5, octave=0.25, velDbLo= -50, velDbHi= -12, velCurve=1.2, velRange=30, pan=0, gate=1|
	var vel, velAmp, dec, sig, scrape, squeak, thump, env, choke;

	vel = Gate.kr(RunningMax.kr(In.kr(velBus)), Line.kr(1, -1, 0.008));
	vel = vel.linlin(velDbLo, velDbHi, 0, 1) ** velCurve;
	velAmp = ((vel - 1) * velRange).dbamp;
	dec = decay * ((freq / 220) ** -0.35);

	// pick scrape: a short hiss, louder when hit harder
	scrape = BPF.ar([WhiteNoise.ar, WhiteNoise.ar], Rand(1800, 4200), 0.7)
		* EnvGen.ar(Env.perc(0.001, Rand(0.06, 0.14), 1, -6)) * (0.25 + vel) * 1.25;
	// squeak: a wound-string chirp on some plucks (more often the weirder it is)
	squeak = BPF.ar([PinkNoise.ar, PinkNoise.ar], XLine.kr(Rand(2400, 4200), Rand(600, 1300), Rand(0.05, 0.12)), 0.07)
		* EnvGen.ar(Env.perc(0.004, 0.1)) * 6 * weird * (Rand(0, 1) < (0.25 + (0.5 * weird)));
	// key thump: the jack hitting the felt
	thump = SinOsc.ar(Rand(65, 110)) * EnvGen.ar(Env.perc(0.001, 0.045)) * 0.35 * vel;
	sig = (scrape + squeak + thump) * noise;
	sig = LPF.ar(sig, warmth.linexp(0, 1, 14000, 3200));

	env = EnvGen.kr(Env.perc(0.0005, dec * 2.5, 1, -5));
	choke = EnvGen.kr(Env.asr(0, 1, 0.04), gate, doneAction: Done.freeSelf);
	sig = sig * env * choke * velAmp * amp;
	// the longest of the three lasts 141 ms; 30 ms more for the lowpass to ring out
	Line.kr(0, 0, 0.17, doneAction: Done.freeSelf);
	Out.ar(out, Balance2.ar(sig[0], sig[1], pan));
}).add;

SynthDef(\cembaloOut, { |in=0, out=0, amp=0, revMix=0.22, room=0.55|
	var sig = In.ar(in, 2);
	sig = FreeVerb2.ar(sig[0], sig[1], revMix, room, 0.6);
	sig = LeakDC.ar(sig).tanh;  // soft ceiling, no look-ahead latency
	Out.ar(out, sig * amp.lag(0.1));
}).add;

// ---- language side ----
// ~cembaloNew.(server, tracker, (inBus: micBus, out: 0, target: group))  ->  object with
//   .enable(bool)   fade in/out (and stop/start voice allocation)
//   .set(\key, val) voice params (next notes), or \volume \revMix \room (output stage, immediately)
//   .noteOn(midi, freq)  pluck (called from the tracker's onNoteOn; chained with an existing handler)
//   .quit           remove everything (not .free: Object:free would silently do nothing)
~cembaloNew = { |server, tracker, opts|
	var c = Environment.new(know: true);
	var o = (inBus: 0, out: 0, target: nil, maxVoices: 12, volume: 1.0, enabled: false);
	var prevOnNoteOn;
	opts !? { opts.keysValuesDo { |k, v| o[k] = v } };

	c[\opts] = o;
	c[\enabled] = false;
	c[\params] = (amp: 0.5, decay: 3.0, bright: 0.5, noise: 0.7, warmth: 0.5, weird: 0.5, octave: 0.25,
		velDbLo: -50, velDbHi: -12, velCurve: 1.2, velRange: 30);
	c[\outParams] = (volume: o[\volume], revMix: 0.22, room: 0.55);
	c[\voices] = List.new;          // oldest first
	c[\byMidi] = Dictionary.new;

	c[\velBus] = Bus.control(server, 1);
	c[\outBus] = Bus.audio(server, 2);
	c[\group] = Group(o[\target] ? server.defaultGroup, \addToTail);
	c[\voiceGroup] = Group(c[\group], \addToHead);
	c[\velSynth] = Synth(\cembaloVel, [\in, o[\inBus], \out, c[\velBus]], c[\group], \addToHead);
	c[\outSynth] = Synth(\cembaloOut, [\in, c[\outBus], \out, o[\out], \amp, 0,
		\revMix, c[\outParams][\revMix], \room, c[\outParams][\room]], c[\group], \addToTail);

	c[\noteOn] = { |self, midi, freq|
		var syn, old, args;
		if(self[\enabled]) {
			// re-plucking a sounding pitch damps the old string; too many voices: damp the oldest
			old = self[\byMidi][midi];
			old !? { old.set(\gate, 0); self[\voices].remove(old) };
			while { self[\voices].size >= self[\opts][\maxVoices] } {
				self[\voices].removeAt(0).set(\gate, 0);  // its byMidi entry is cleared when it frees
			};
			// a voice is a group holding the string and its attack (see the top of this file); one bundle, so
			// both start in the same control block
			args = [
				\out, self[\outBus], \freq, freq, \velBus, self[\velBus],
				\pan, (midi.linlin(40, 84, -0.45, 0.45) + 0.15.rand2)
			] ++ self[\params].asKeyValuePairs;
			syn = Group.basicNew(server);
			server.sendBundle(nil,
				syn.newMsg(self[\voiceGroup], \addToHead),
				Synth.basicNew(\cembalo, server).newMsg(syn, args),
				Synth.basicNew(\cembaloAttack, server).newMsg(syn, args));
			syn.onFree {
				self[\voices].remove(syn);
				if(self[\byMidi][midi] === syn) { self[\byMidi].removeAt(midi) };
			};
			self[\voices].add(syn);
			self[\byMidi][midi] = syn;
		};
		self
	};

	c[\set] = { |self, key, val|
		if(self[\outParams].includesKey(key)) {
			self[\outParams][key] = val;
			if(key == \volume) {
				if(self[\enabled]) { self[\outSynth].set(\amp, val) };
			} {
				self[\outSynth].set(key, val);
			};
		} {
			if(self[\params].includesKey(key)) {
				self[\params][key] = val;
			} {
				("cembalo: unknown parameter %; known: %".format(key,
					(self[\params].keys ++ self[\outParams].keys).asArray.sort)).warn;
			};
		};
		self
	};

	c[\enable] = { |self, on = true|
		self[\enabled] = on;
		if(on) {
			self[\group].run(true);
			self[\outSynth].set(\amp, self[\outParams][\volume]);
		} {
			self[\outSynth].set(\amp, 0);
			self[\voices].copy.do { |v| v.set(\gate, 0) };
			// pause the whole chain once faded (no CPU while off)
			AppClock.sched(0.25, { if(self[\enabled].not) { self[\group].run(false) }; nil });
		};
		self
	};

	c[\quit] = { |self|  // not .free: Object:free exists and would silently do nothing
		self[\enabled] = false;
		self[\group].free;
		self[\velBus].free;
		self[\outBus].free;
		if(tracker.notNil) { tracker[\onNoteOn] = prevOnNoteOn };
	};

	// chain into the tracker's note-on callback, keeping any handler that is already there
	if(tracker.notNil) {
		prevOnNoteOn = tracker[\onNoteOn];
		tracker[\onNoteOn] = { |voice, midi, freq, amp|
			prevOnNoteOn.value(voice, midi, freq, amp);
			c.noteOn(midi, freq);
		};
	};

	c.enable(o[\enabled]);
	c
};

"SynthDef \\cembalo is defined and added.".postln;
)
