// Pad: an eerie, warm, worn-out analogue pad, played by the polyphonic tracker. Chords on the guitar bloom into
// slow detuned chords that drift in pitch like an old tape.
//
// The pitch modulation is the point of this synth. Four layers, all scaled by the wobble fader:
//   wow      the whole "tape" slows down and speeds up: a sine whose own rate wanders (never a steady vibrato)
//            plus a slow random walk. Shared by all notes, so chords stay in tune with themselves while they sag.
//   flutter  a small, fast (about 7 times the wow rate) irregular shake on top
//   drift    every oscillator wanders a few cents on its own (detune fader), so the beating never repeats
//   scoop    every new note starts flat and slides up into pitch over about 0.4 s
// After the filter the sound runs through a short modulated delay per channel (a second, weaker wow, different
// left and right): that is what makes it wide and seasick rather than just out of tune.
//
// Per note: two band-limited saws detuned against each other (left / right) and a pulse with slow PWM between
// them (wave fader: saws .. pulse). All notes then share one 24 dB lowpass (tone), tape saturation, hiss, level
// warble (age) and the reverb.
//
// Faders (CC slots 110–119, baked in at compile time from ~busNames like \apePoly; all 0..1):
//   volume      output level                    wobble   depth of wow / flutter / scoop (0 = steady pitch)
//   wobbleRate  0.15 .. 6 Hz wow rate           detune   spread of the two saws 2 .. 40 cents + drift
//   tone        lowpass 250 Hz .. 9 kHz         wave     saws .. pulse
//   age         hiss, saturation, level warble, treble loss
//   attack      5 ms .. 3 s                     release  0.1 .. 10 s
//   reverb      reverb mix
//
// It reads the tracker's per-voice buses like \apePoly (block layout: classes/inputtracker.scd): +3 heartbeat,
// +4.. freq, +4+n.. amp, +4+2n.. gate with n = 6 voices. A note sounds while the tracker's gate is open and then
// fades with the release time; unlike \apePoly it does not follow the guitar's level while it sounds (a pad, not
// an envelope follower). Several notes are mixed at equal power, so a chord is as loud as one note.
//   voiceBalance: 0 = all notes equally loud, 1 = follow the relative levels the tracker measures per note.
//   freqLag: pitch smoothing (s). A voice that is re-used while its old note still fades glides to the new pitch.
(
SynthDef(\pad, { |ccBus=0, polyBus=0, out=0, freqLag=0.05, voiceBalance=0.3, ampRangeDb=60|
	var n = 6, header = 4;  // == ~polyTrackerVoices, ~polyTrackerHeader (inputtracker.scd is loaded after this file)
	var cc = { |key| In.kr(ccBus + ~busNames[("pad_" ++ key).asSymbol].index).lag(0.05) };
	var volume = cc.(\volume), wobble = cc.(\wobble), rate = cc.(\wobbleRate).linexp(0, 1, 0.15, 6);
	var detune = cc.(\detune).linexp(0, 1, 2, 40), tone = cc.(\tone).linexp(0, 1, 250, 9000);
	var wave = cc.(\wave), age = cc.(\age), reverb = cc.(\reverb);
	var atk = cc.(\attack).linexp(0, 1, 0.005, 3), rel = cc.(\release).linexp(0, 1, 0.1, 10);
	var alive, vFreq, vAmp, vGate, noteStart, freq, gateEnv, ampHeld, ampMax, weight, level, norm, total;
	var depth, wow, flutter, tape, scoop, voices, sig, cutoff, drive, hiss, warble, chorus;

	// tracker voices; a stopped heartbeat (tracker paused or crashed) closes every gate
	alive = Sweep.kr(Changed.kr(In.kr(polyBus + 3)), 1) < 0.5;
	vFreq = In.kr(polyBus + header, n);
	vAmp  = In.kr(polyBus + header + n, n);
	vGate = In.kr(polyBus + header + (2 * n), n) * alive;
	noteStart = (vGate - Delay1.kr(vGate)) > 0;
	// the tracker reports 0 Hz for a voice that has never played: hold the last real pitch
	freq = Lag.kr(Gate.kr(vFreq, vFreq > 20).max(20), freqLag);
	gateEnv = Lag2UD.kr(vGate, atk, rel);  // atk / rel: after that time the note has arrived / is 60 dB down

	// relative level per note, as in \apePoly
	ampHeld = Gate.kr(vAmp, vGate);
	ampMax = (ampHeld * vGate).reduce(\max);
	weight = ((ampHeld - ampMax) * ampRangeDb * voiceBalance.clip(0, 1)).dbamp.min(1);
	level = gateEnv * weight;
	norm = level.squared.sum.max(1).sqrt.reciprocal;
	total = level.sum.min(1);

	// ---- pitch modulation, in cents ----
	depth = wobble.squared;  // fine control at the subtle end of the fader
	wow = (SinOsc.kr(rate * LFNoise1.kr(0.23).range(0.7, 1.3)) * 0.6) + (LFNoise2.kr(rate * 0.4) * 0.8);
	flutter = LFNoise2.kr(rate * 7) * SinOsc.kr(rate * 2.3).range(0.3, 1);
	tape = ((wow * 45) + (flutter * 7)) * depth;         // up to about ± 60 cents
	scoop = Decay.kr(noteStart, 0.4) * (-35 * depth);  // per voice

	voices = n.collect { |i|
		var f = freq[i] * ((tape + scoop[i]) / 100).midiratio;
		var d = [-0.5, 0.5].collect { |s| ((s * detune) + (LFNoise2.kr(Rand(0.07, 0.25)) * detune * 0.3)) / 100 };
		var saws = Saw.ar(f * d.midiratio);  // left, right
		var pulse = Pulse.ar(f, LFTri.kr(Rand(0.08, 0.2), Rand(0, 4)).range(0.3, 0.7)) * 0.9;
		var mix = (saws * (1 - (wave * 0.8))) + (pulse * wave);
		// low notes a little to the left, high ones to the right, like the cembalo
		Balance2.ar(mix[0], mix[1], (freq[i].cpsmidi.linlin(40, 84, -0.3, 0.3)), level[i])
	};
	sig = voices.sum * norm * 0.35;

	// ---- one filter for all notes: 24 dB, a little resonance, breathing slowly; age takes treble away ----
	cutoff = (tone * (1 - (age * 0.45)) * LFNoise2.kr(0.15).range(0.85, 1.18) * (tape / 300).midiratio).clip(120, 12000);
	sig = LPF.ar(RLPF.ar(sig, cutoff, 0.55), cutoff * 1.4);

	// ---- tape: saturation, hiss that comes and goes with the notes, level warble ----
	drive = 1 + (age * 5);
	sig = (sig * drive).tanh / (drive ** 0.6);
	hiss = LPF.ar(HPF.ar({ PinkNoise.ar } ! 2, 400), 5500) * age.squared * 0.05 * Lag.kr(total, 0.3);
	warble = 1 - (age * 0.35 * LFNoise2.kr(rate * 1.7).range(0, 1) * LFNoise1.kr(0.5).range(0.3, 1));
	sig = (sig + hiss) * warble;

	// ---- modulated delay: a second, weaker wow, different on each side (width; 0 at wobble 0 = plain delay) ----
	chorus = [0.011, 0.014] + ([SinOsc.kr(rate * 0.83, 0), SinOsc.kr(rate * 0.71, 1.9)] * 0.0035 * depth.sqrt)
		+ (LFNoise2.kr(rate * 3 ! 2) * 0.0006 * depth);
	sig = (sig * 0.6) + (DelayC.ar(sig, 0.03, chorus) * 0.6);

	sig = FreeVerb2.ar(sig[0], sig[1], reverb, 0.88, 0.55);
	sig = LeakDC.ar(sig).tanh;  // soft ceiling, no look-ahead latency
	// 0.7: at the default volume (0.7) a chord is as loud (RMS) as the tape synth with its default sound, which
	// is matched to the cembalo; the fader's top is 6 dB above that
	Out.ar(out, sig * volume.squared * 0.7);
}).add;

"SynthDef \\pad is defined and added.".postln;
)
