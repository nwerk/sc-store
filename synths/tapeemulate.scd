(
"Try Instantiate".postln;
SynthDef(\ape, { |ccBus=0, input_pitch=0, vol=0|
			var sig, pitch, ccVals, badness, wavemix = 0, waveMap, badnessMap, sine, saw;
			var noiseL, noiseR, volSig, pitchSig, reverbSig;
			var reverb_mix, reverb_room;
			var master_vol = 1;

			volSig = In.kr(vol);
			pitchSig = In.kr(input_pitch);
			ccVals = In.kr(ccBus, 128);

			badness = Select.kr(~busNames[\badness].index, ccVals);
			wavemix = Select.kr(~busNames[\wavemix].index, ccVals);
			waveMap = Select.kr(~busNames[\wavemap].index, ccVals);
			badnessMap = Select.kr(~busNames[\badnessmap].index, ccVals);

			reverb_mix = Select.kr(~busNames[\reverb_mix].index, ccVals);
			reverb_room = Select.kr(~busNames[\reverb_room].index, ccVals);

			master_vol = Select.kr(~busNames[\master].index, ccVals);
			noiseL = WhiteNoise.ar(1);
			noiseR = WhiteNoise.ar(1);
			
			// input_pitch = MouseY.kr(100, 3000, 1);
            //vol = MouseX.kr(0, 1);
    		//pitchSig.poll(1, "input_pitch");
    		//volSig.poll(1, "vol");
			badness = badness * 7;
			badness = badness * volSig; // Scale badness by volume control
			badness = (badness + (badnessMap * volSig)).clip(0,7);
			//badness.poll(1, "badness");
			sig = [noiseL, noiseR];
			sig = LPF.ar(sig, 100);
			sig = sig + LeakDC.ar((LocalIn.ar(2, sig) * -1), 0.995); // Use 2 channels for LocalIn
			sig = sig * badness;
			pitch = sig * pitchSig * 0.25;
			pitch = pitch + pitchSig;
			sine = [SinOsc.ar(pitch[0], 0, 1), SinOsc.ar(pitch[1], 0, 1)];
			saw = [LFSaw.ar(pitch[0], 0, 1), LFSaw.ar(pitch[1], 0, 1)];
			saw = LPF.ar(saw, 2500);
			wavemix = (wavemix + (waveMap * volSig)).clip(0,1);
			//volSig.poll;
			sig = (wavemix * saw) + ((1 - wavemix) * sine);
			sig = sig * volSig;
			LocalOut.ar(sig);
			reverbSig = FreeVerb.ar(sig, mix: reverb_mix, room: reverb_room, damp: 0.5);
			reverbSig = reverbSig * master_vol;
			Out.ar(\out.kr(0), reverbSig);
		}).add;

"SynthDef \ape is defined and added.".postln;

// ---- \apePoly: \ape with one oscillator per note of the polyphonic tracker ----
// Same sound as \ape (noise/feedback pitch wobble, sine/saw mix, reverb, same CC slots 90-96), but it reads the
// tracker's per-voice frequency / amplitude / gate buses instead of the single mono pitch, so chords sound as chords.
// Each voice has its own noise source and feedback path, so the voices wobble independently.
//   polyBus: first bus of the tracker block (~tracker.block.index); vol: the tracker's ampBus (overall input level)
// Loudness: a single note gets exactly \ape's level (osc * vol). Several notes are mixed at equal power, so a chord is
// as loud as a single note. voiceBalance: 0 = all notes equally loud, 1 = follow the relative level the tracker
// measures per note (a note 12 dB quieter in the guitar is 12 dB quieter here).
// Block layout (see classes/inputtracker.scd): +3 heartbeat, +4.. freq, +4+n.. amp, +4+2n.. gate with n = 6 voices.
// Picking position (classes/pluckpos.scd; in: the guitar signal, pluckRef / pluckTrack / pluckSpan: calibration):
// each note keeps the position it was picked at. Near the bridge it gets more saw and a brighter saw, towards the
// neck more sine and a duller saw. The amount is the pluck fader (CC slot 97); at 0 nothing changes.
~pluckBrightness ?? {
	thisProcess.interpreter.executeFile(PathName(thisProcess.nowExecutingPath).pathOnly +/+ "../classes/pluckpos.scd")
};
SynthDef(\apePoly, { |ccBus=0, polyBus=0, vol=0, atk=0.005, rel=0.25, freqLag=0.02, voiceBalance=0.5, ampRangeDb=60,
	in=0, pluckRef=800, pluckTrack=0.5, pluckSpan=0.75|
	var n = 6, header = 4;  // == ~polyTrackerVoices, ~polyTrackerHeader (inputtracker.scd is loaded after this file)
	var ccVals, badness, wavemix, waveMap, badnessMap, reverb_mix, reverb_room, master_vol, pluck;
	var volSig, alive, vFreq, vAmp, vGate, noteStart, freq, gateEnv, ampHeld, ampMax, weight, level, norm;
	var pos, voiceMix, sawCutoff, fb, voices, sig;

	volSig = In.kr(vol);
	ccVals = In.kr(ccBus, 128);
	badness = Select.kr(~busNames[\badness].index, ccVals);
	wavemix = Select.kr(~busNames[\wavemix].index, ccVals);
	waveMap = Select.kr(~busNames[\wavemap].index, ccVals);
	badnessMap = Select.kr(~busNames[\badnessmap].index, ccVals);
	reverb_mix = Select.kr(~busNames[\reverb_mix].index, ccVals);
	reverb_room = Select.kr(~busNames[\reverb_room].index, ccVals);
	master_vol = Select.kr(~busNames[\master].index, ccVals);
	pluck = Select.kr((~busNames[\pluck] ? (index: 97)).index, ccVals);  // not in the mappings of the mono patches

	// identical to \ape: both scale with the overall input level
	badness = ((badness * 7 * volSig) + (badnessMap * volSig)).clip(0, 7);
	wavemix = (wavemix + (waveMap * volSig)).clip(0, 1);

	// tracker voices; a stopped heartbeat (tracker paused or crashed) closes every gate
	alive = Sweep.kr(Changed.kr(In.kr(polyBus + 3)), 1) < 0.5;
	vFreq = In.kr(polyBus + header, n);
	vAmp  = In.kr(polyBus + header + n, n);
	vGate = In.kr(polyBus + header + (2 * n), n) * alive;

	// a new note jumps to its pitch; while it sounds, smooth the tracker's ~5 ms update steps (bends, vibrato)
	noteStart = (vGate - Delay1.kr(vGate)) > 0;
	freq = Lag.kr(vFreq, freqLag * (1 - noteStart));
	gateEnv = Lag2UD.kr(vGate, atk, rel);  // release keeps the note's last frequency (the tracker holds it)

	// relative level per note: the tracker's amplitude, held through the release, against the loudest sounding note
	ampHeld = Gate.kr(vAmp, vGate);
	ampMax = (ampHeld * vGate).reduce(\max);
	weight = ((ampHeld - ampMax) * ampRangeDb * voiceBalance.clip(0, 1)).dbamp.min(1);
	level = gateEnv * weight;
	norm = level.squared.sum.max(1).sqrt.reciprocal;  // equal-power mix; no change while at most one note sounds

	// picking position per note: followed for the first 20 ms of the note (the pick's attack; a low string needs
	// more than one period of 12 ms before its brightness can be read), then kept
	pos = ~pluckPosition.(~pluckBrightness.(In.ar(in)), vFreq, pluckRef, pluckTrack, pluckSpan);
	pos = Gate.kr(pos, Trig1.kr(noteStart, 0.02)) * pluck;
	voiceMix = (wavemix + (pos * 0.5)).clip(0, 1);
	sawCutoff = 2500 * (2 ** (pos * 1.5));  // 880 Hz .. 7 kHz

	fb = LocalIn.ar(2 * n).clump(2);
	voices = n.collect { |i|
		var x, p, sine, saw;
		x = LPF.ar([WhiteNoise.ar(1), WhiteNoise.ar(1)], 100);
		x = x + LeakDC.ar(fb[i] * -1, 0.995);
		x = x * badness;
		p = (x * freq[i] * 0.25) + freq[i];
		sine = SinOsc.ar(p, 0, 1);
		saw = LPF.ar(LFSaw.ar(p, 0, 1), sawCutoff[i]);
		((voiceMix[i] * saw) + ((1 - voiceMix[i]) * sine)) * (volSig * level[i])
	};
	LocalOut.ar(voices.flatten);

	sig = voices.sum * norm;
	sig = FreeVerb.ar(sig, mix: reverb_mix, room: reverb_room, damp: 0.5);
	Out.ar(\out.kr(0), sig * master_vol);
}).add;
// ---- \apePoly split into voices that sleep while silent (what main_multi.scd plays) ----
// \apePoly computes all 6 voices all the time, also the ones that are silent (no note, released). Here the same
// computation is split in three kinds of synth, in one group (~apePolyNew below):
//   \apePolyCtl    everything that concerns all voices: CC faders, tracker buses, envelopes, the weighting of the
//                  voices against each other, the picking position. Writes per-voice values to a block of control
//                  buses, and pauses every voice whose level is below sleepDb while its gate is closed.
//   \apePolyVoice  one voice (noise wobble, feedback, sine / saw), x 6, in a ParGroup (several cores with supernova)
//   \apePolyPost   sum of the voices, equal-power normalisation, reverb, master volume
// The control synth runs first and the voices read its buses in the same control block, so nothing is delayed;
// a voice is woken in the block in which its gate opens. A paused voice keeps its state (oscillator phases,
// noise filters) and costs nothing; its output was below -100 dB when it was paused.
// Same sound as \apePoly: with sleep = 0 (voices never paused) and no noise wobble the output is the same sample
// for sample (checked offline); the wobble noise is random in both.
~apePolyVoices = 6;
~apePolyCtlSize = 1 + (4 * ~apePolyVoices) + 4;  // badness, freq x n, voiceMix x n, sawCutoff x n, amp x n, norm, reverb mix, room, master

SynthDef(\apePolyCtl, { |ccBus=0, polyBus=0, vol=0, atk=0.005, rel=0.25, freqLag=0.02, voiceBalance=0.5, ampRangeDb=60,
	in=0, pluckRef=800, pluckTrack=0.5, pluckSpan=0.75, ctl=0, voiceIds=#[-1, -1, -1, -1, -1, -1], sleep=1, sleepDb= -100|
	var n = ~apePolyVoices, header = 4;
	var ccVals, badness, wavemix, waveMap, badnessMap, reverb_mix, reverb_room, master_vol, pluck;
	var volSig, alive, vFreq, vAmp, vGate, noteStart, freq, gateEnv, ampHeld, ampMax, weight, level, norm;
	var pos, voiceMix, sawCutoff;

	volSig = In.kr(vol);
	ccVals = In.kr(ccBus, 128);
	badness = Select.kr(~busNames[\badness].index, ccVals);
	wavemix = Select.kr(~busNames[\wavemix].index, ccVals);
	waveMap = Select.kr(~busNames[\wavemap].index, ccVals);
	badnessMap = Select.kr(~busNames[\badnessmap].index, ccVals);
	reverb_mix = Select.kr(~busNames[\reverb_mix].index, ccVals);
	reverb_room = Select.kr(~busNames[\reverb_room].index, ccVals);
	master_vol = Select.kr(~busNames[\master].index, ccVals);
	pluck = Select.kr((~busNames[\pluck] ? (index: 97)).index, ccVals);

	badness = ((badness * 7 * volSig) + (badnessMap * volSig)).clip(0, 7);
	wavemix = (wavemix + (waveMap * volSig)).clip(0, 1);

	alive = Sweep.kr(Changed.kr(In.kr(polyBus + 3)), 1) < 0.5;
	vFreq = In.kr(polyBus + header, n);
	vAmp  = In.kr(polyBus + header + n, n);
	vGate = In.kr(polyBus + header + (2 * n), n) * alive;

	noteStart = (vGate - Delay1.kr(vGate)) > 0;
	freq = Lag.kr(vFreq, freqLag * (1 - noteStart));
	gateEnv = Lag2UD.kr(vGate, atk, rel);

	ampHeld = Gate.kr(vAmp, vGate);
	ampMax = (ampHeld * vGate).reduce(\max);
	weight = ((ampHeld - ampMax) * ampRangeDb * voiceBalance.clip(0, 1)).dbamp.min(1);
	level = gateEnv * weight;
	norm = level.squared.sum.max(1).sqrt.reciprocal;

	pos = ~pluckPosition.(~pluckBrightness.(In.ar(in)), vFreq, pluckRef, pluckTrack, pluckSpan);
	pos = Gate.kr(pos, Trig1.kr(noteStart, 0.02)) * pluck;
	voiceMix = (wavemix + (pos * 0.5)).clip(0, 1);
	sawCutoff = 2500 * (2 ** (pos * 1.5));

	Out.kr(ctl, [badness] ++ freq ++ voiceMix ++ sawCutoff ++ (volSig * level) ++ [norm, reverb_mix, reverb_room, master_vol]);
	// asleep: gate closed and the level under sleepDb (sleep = 0: never)
	n.do { |i| Pause.kr(((vGate[i] > 0) + (level[i] > sleepDb.dbamp) + (1 - sleep)) > 0, voiceIds[i]) };
}).add;

SynthDef(\apePolyVoice, { |ctl=0, index=0, sum=0|
	var n = ~apePolyVoices;
	var rid = RandID.ir(index + 1);  // its own random generator (see \padVoice)
	var badness = In.kr(ctl), freq = In.kr(ctl + 1 + index), voiceMix = In.kr(ctl + 1 + n + index);
	var sawCutoff = In.kr(ctl + 1 + (2 * n) + index), amp = In.kr(ctl + 1 + (3 * n) + index);
	var fb, x, p, sine, saw, sig;
	fb = LocalIn.ar(2);
	x = LPF.ar([WhiteNoise.ar(1), WhiteNoise.ar(1)], 100);
	x = x + LeakDC.ar(fb * -1, 0.995);
	x = x * badness;
	p = (x * freq * 0.25) + freq;
	sine = SinOsc.ar(p, 0, 1);
	saw = LPF.ar(LFSaw.ar(p, 0, 1), sawCutoff);
	sig = ((voiceMix * saw) + ((1 - voiceMix) * sine)) * amp;
	LocalOut.ar(sig);
	Out.ar(sum, sig);
}).add;

SynthDef(\apePolyPost, { |ctl=0, sum=0, out=0|
	var base = 1 + (4 * ~apePolyVoices);
	var norm = In.kr(ctl + base), reverb_mix = In.kr(ctl + base + 1), reverb_room = In.kr(ctl + base + 2);
	var master_vol = In.kr(ctl + base + 3);
	var sig = In.ar(sum, 2) * norm;
	sig = FreeVerb.ar(sig, mix: reverb_mix, room: reverb_room, damp: 0.5);
	Out.ar(out, sig * master_vol);
}).add;

// ~apePolyNew.(server, args, target, addAction) -> a Group playing \apePoly with sleeping voices. args as for
// \apePoly (ccBus, polyBus, vol, in, out, atk, rel, ...). .set(key, value) and .run(bool) work as on the synth.
~apePolyNew = { |server, args, target, addAction = \addToTail|
	var a = (), g, vg, voices, ctlBus, sumBus;
	args.pairsDo { |k, v| a[k] = v };
	ctlBus = Bus.control(server, ~apePolyCtlSize);
	sumBus = Bus.audio(server, 2);
	g = Group(target, addAction);
	vg = ParGroup(g);
	voices = ~apePolyVoices.collect { |i| Synth(\apePolyVoice, [\ctl, ctlBus, \index, i, \sum, sumBus], vg, \addToTail) };
	Synth(\apePolyCtl, args ++ [\ctl, ctlBus, \voiceIds, voices.collect(_.nodeID)], g, \addToHead);
	Synth(\apePolyPost, [\ctl, ctlBus, \sum, sumBus, \out, a[\out] ? 0], g, \addToTail);
	g
};

"SynthDef \apePoly is defined and added.".postln;
)
