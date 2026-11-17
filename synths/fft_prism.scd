// ============================================================
// \fftPrism — spectral feedback effect of the grain chain (main_multi.scd)
// ============================================================
// Replaces \fftFreeze in main_multi.scd (synths/fft_freeze.scd stays for main_grain.scd).
// Core UGens only: no sc3-plugins needed.
//
//   source ─ FFT ─ freeze ─┐
//                          ├─ add ─ smear ─ sieve ─ filter ─ blur ─ IFFT ─┬─► wet × level  (+ dry grains)
//   loop ─── FFT ──────────┘                                              │
//     ▲                                                                   │
//     └─ level control ◄─ × feedback ◄─ warp ◄─ frequency shift ◄─ delay ◄┘
//
// What enters the effect is heard once, sculpted by smear / sieve / filter / blur, and then goes round the loop.
// Every round it is shifted by a few Hz (pad X), transposed (warp) and delayed (time): echoes that climb or sink,
// spread into inharmonic stacks, or (tiny shifts, short time) into an endless barber-pole sweep.
// FREEZE holds the spectrum of the moment as a standing wash. It keeps feeding the loop, so a frozen chord can be
// stacked and spiralled with the pad while the guitar and the grains carry on.
//
// Controls (CC slots, see osc/osc_mappings_multi.scd; all 0..1):
//   fftFreeze     hold the current spectrum (toggle)
//   fftFreezeVol  level of the effect (0 = dry grains only)
//   fftSource     what feeds it: 0 = the grains, 1 = the grain input (guitar / cembalo / tape, the IN buttons)
//   fftSpiral     pad X: frequency shift per round, 0.5 = none, ±600 Hz at the edges (fine around the centre)
//   fftFeedback   pad Y: loop gain; the top ~15 % sustain for ever (the loop's level control keeps it bounded)
//   fftTime       extra loop delay 0..1.5 s (0 = one FFT frame, about 45 ms)
//   fftWarp       transposition per round in semitones, 0.5 = none, ± one octave (7 = stacked fifths, ...)
//   fftSmear      blurs neighbouring partials into noise bands
//   fftSieve      removes a random part of the partials (different left and right)
//   fftFlicker    how often the sieve picks new partials (0 = never: a fixed comb)
//   fftBlur       scrambles the phases: 0 = off, low = smeared attacks, 1 = a wash without attacks
//   fftTilt       brick-wall filter inside the loop: 0.5 = open, below = low-pass, above = high-pass
// ============================================================

SynthDef(\fftPrism, { |micIn=0, granIn=0, out=0, ccBus=0, fftSize=2048, loopLevel=0.15|
	var cc = In.kr(ccBus, 128);
	var ctl = { |key| cc[~busNames[key].index] };
	var bipolar = { |v, dead=0.06| var d = (v - 0.5) * 2; d.sign * ((d.abs - dead).max(0) / (1 - dead)) };

	var freeze   = ctl.(\fftFreeze) > 0.5;
	var level    = ctl.(\fftFreezeVol).lag(0.05);
	var source   = ctl.(\fftSource).lag(0.05);
	var shiftHz  = (bipolar.(ctl.(\fftSpiral)) ** 3 * 600).lag(0.1);
	var feedback = ctl.(\fftFeedback).lincurve(0, 1, 0, 1.05, -2.5).lag(0.05);
	var time     = (ctl.(\fftTime).squared * 1.5).lag(0.3);
	var warpSemi = (bipolar.(ctl.(\fftWarp)) * 12).round;
	var smear    = (ctl.(\fftSmear).squared * 40).round;
	var sieve    = ctl.(\fftSieve).lincurve(0, 1, 0, 0.97, -2);
	var flicker  = ctl.(\fftFlicker);
	var blur     = ctl.(\fftBlur);
	var wall     = bipolar.(ctl.(\fftTilt), 0.04);

	var gran = In.ar(granIn, 2);
	var src  = (gran * (1 - source)) + (In.ar(micIn, 1) * source);
	var loop = LocalIn.ar(2);

	// low-pass: wipe -1..0 (cutoff falls as the fader goes down), high-pass: 0..1. Curved, so the musically
	// useful low end of the spectrum takes most of the fader's travel.
	// (cutoff: low-pass 24 kHz .. 100 Hz, high-pass 0 .. 6 kHz, both exponential in the fader)
	var wipe = Select.kr(wall > 0, [(0.004 ** wall.abs) - 1, ((125 ** wall) - 1) * 0.002]);
	var sieveTrig = Impulse.kr(flicker.linexp(0, 1, 0.2, 25)) * (flicker > 0.02);
	var blurRate  = blur.linexp(0, 1, 0.5, 60);  // above the frame rate (47 Hz): new phases for every frame

	var wet = 2.collect { |ch|
		var live, held, in, fb, sum, blurred, frame;
		// input: live, or the held spectrum with new random phases for every frame (a wash without attacks)
		live  = FFT(LocalBuf(fftSize), src[ch]);
		frame = live > -1;  // 1 in the control period a new frame arrives
		held  = PV_Diffuser(PV_MagFreeze(PV_Copy(live, LocalBuf(fftSize)), freeze), frame);
		in    = Select.kr(freeze, [live, held]);
		fb    = FFT(LocalBuf(fftSize), loop[ch]);
		sum   = PV_Add(fb, in);
		sum   = PV_MagSmear(sum, smear);
		sum   = PV_RandComb(sum, sieve, sieveTrig);
		sum   = PV_BrickWall(sum, wipe);
		blurred = PV_Diffuser(PV_Copy(sum, LocalBuf(fftSize)), Impulse.kr(blurRate));
		sum   = Select.kr(blur > 0.02, [sum, blurred]);
		// the sieve leaves few partials: make up for part of the loss
		IFFT(sum) * (1 - sieve).max(0.03).reciprocal.sqrt.lag(0.1);
	};

	// loop: delay -> frequency shift -> transposition -> feedback gain -> level control (keeps endless feedback
	// at loopLevel, about the level of the playing, instead of letting it grow into the limiter)
	var back = DelayC.ar(wet, 1.6, time);
	var gain;
	back = FreqShift.ar(back, shiftHz);
	back = XFade2.ar(back, PitchShift.ar(back, 0.09, warpSemi.midiratio, 0, 0.004), (warpSemi.abs > 0).lag(0.05) * 2 - 1);
	back = LeakDC.ar(back) * feedback;
	gain = (loopLevel / Amplitude.kr(back, 0.01, 0.4).reduce(\max).max(loopLevel)).lag(0.02);
	back = (back * gain).tanh;
	LocalOut.ar(Sanitize.ar(back));

	Out.ar(out, gran + (Sanitize.ar(wet) * level));
}).add;

"SynthDef \\fftPrism added to server.".postln;
