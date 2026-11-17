(
Server.killAll;

//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;

// Platform-specific audio server config
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");

// Unified OSC mappings: ~busNames (grain 11–83 + tape remapped 90–96) + ~oscMap
thisProcess.interpreter.executeFile(~basePath ++ "osc/osc_mappings_multi.scd");

// MIDI: Boss FS-1-WL footswitch only (CC 11 pedal + CC 80/81/82 stubs)
// Also initialises ~ccBuses before server boot.
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig_multi.scd");

// SynthDef files — ORDER MATTERS: ~busNames must be set before any SynthDef
// that references ~busNames[...].index at compile time.
// granular.scd uses ~busNames[\density] etc. (grain indices, unchanged)
thisProcess.interpreter.executeFile(~basePath ++ "synths/granular.scd");
// fft_prism.scd: \fftPrism, the spectral feedback effect after the grains. Core UGens only (no sc3-plugins).
// It replaces \fftFreeze (synths/fft_freeze.scd, still used by main_grain.scd).
thisProcess.interpreter.executeFile(~basePath ++ "synths/fft_prism.scd");
// tapeemulate.scd uses ~busNames[\badness] etc. — now baked as 90–96
thisProcess.interpreter.executeFile(~basePath ++ "synths/tapeemulate.scd");
// inputtracker.scd: ~polyTrackerNew (polyphonic ML tracker) + \polyTracker SynthDef (no ~busNames refs)
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");
// master.scd: \master SynthDef uses ~busNames[\masterVol].index = 11 (grain master)
thisProcess.interpreter.executeFile(~basePath ++ "classes/master.scd");
// cembalo.scd: \cembalo voices + ~cembaloNew (plucked by the tracker's note-ons; no ~busNames refs)
thisProcess.interpreter.executeFile(~basePath ++ "synths/cembalo.scd");
// pad.scd: \pad, the wobbly tape pad; uses ~busNames[\pad_volume] etc. (67–76)
thisProcess.interpreter.executeFile(~basePath ++ "synths/pad.scd");

// ---- Grain input mixer ----
// Whatever this writes is what \rec puts into the grain buffer (and what the FFT effect's source fader blends in).
// guitar / cembalo / tape / pad are 0..1 gains (the /grain/src* toggles); any combination can be on.
// The stereo synths are summed to mono at -3 dB.
// The sum is limited to 0.9 (10 ms look-ahead; only the recording is delayed, nothing you hear directly):
// \rec hard-clips at ±1, and the tape synth alone peaks around 1.4.
SynthDef(\grainSource, { |out=0, guitarIn=0, cembaloIn=0, tapeIn=0, padIn=0, guitar=1, cembalo=0, tape=0, pad=0|
	var sig = (In.ar(guitarIn, 1) * guitar.lag(0.05))
		+ (In.ar(cembaloIn, 2).sum * 0.7071 * cembalo.lag(0.05))
		+ (In.ar(tapeIn, 2).sum * 0.7071 * tape.lag(0.05))
		+ (In.ar(padIn, 2).sum * 0.7071 * pad.lag(0.05));
	sig = Limiter.ar(Sanitize.ar(sig), 0.9, 0.005);
	Out.ar(out, sig);
}).add;

// ---- Output safety stage (last node on the server) ----
// Whatever happens upstream (grain overlaps adding up, a synth blowing up, NaN / inf), the hardware outputs never
// get more than `ceiling` (≈ -0.5 dBFS): bad values become silence, DC is removed, peaks are limited.
// Everything you hear passes through here, so the limiter's delay is latency of the whole instrument: it delays by
// twice its look-ahead (measured), 2 ms look-ahead = 4 ms. It was 5 ms = 10 ms; a longer look-ahead limits more
// smoothly (less distortion on bass while it is limiting), a shorter one answers faster to the guitar.
SynthDef(\outputSafety, { |ceiling=0.95|
	var sig = Sanitize.ar(In.ar(0, 2));
	sig = LeakDC.ar(sig);
	sig = Limiter.ar(sig, ceiling, 0.002);
	ReplaceOut.ar(0, Sanitize.ar(sig).clip(-1, 1));
}).add;

// ---- Tape / cembalo / pad output stage SynthDef (inline — cannot use \master, which hardcodes CC 11) ----
// \ape already applies its own master_vol from CC 96 internally, the cembalo its own volume.
// \tapeOutput is purely a mute/enable gate controlled via ~tapeMaster / ~cembaloMaster / ~padMaster .set(\amp, ...).
SynthDef(\tapeOutput, { |out=0, inBus=0, amp=0.0|
	var sig = In.ar(inBus, 2);
	sig = sig * amp.lag(0.1);
	Out.ar(out, sig);
}).add;

s.waitForBoot {
	// ---- System state ----
	~synthEnabled = ( grain: true, tape: false, cembalo: false, pad: false );  // audible on the outputs
	~grainSrc     = ( guitar: true, cembalo: false, tape: false, pad: false );  // fed into the grain buffer
	~focusedSynth = \grain;

	// ---- CC slots: FIRST control buses after the boot (see midi/midiconfig_multi.scd) ----
	~ccBuses = Bus.control(s, 128);
	~ccBuses.setn(Array.fill(128, 0.0));

	// ---- Tape synth starting sound (CC 90–97), so it plays without the tablet (footswitch) ----
	// A soft, slightly wobbly sine/saw pad under the cembalo. master 0.1 puts its level (RMS) about level with the
	// cembalo's (measured with a strummed test signal; at 0.35 the tape was 14 dB louder and covered the plucks).
	// A preset that contains tape values replaces these.
	~tapeDefaults = (
		badness: 0.12, wavemix: 0.35, wavemap: 0.15, badnessmap: 0.1,
		reverb_mix: 0.35, reverb_room: 0.75, master: 0.1,
		pluck: 0  // picking position amount: off until the fader is moved (or a preset sets it)
	);
	~tapeDefaults.keysValuesDo { |k, v| ~ccBuses.setAt(~busNames[k].index, v) };
	// ---- FFT effect: neutral until its faders are moved (osc_mappings_multi.scd) ----
	~fftDefaults.keysValuesDo { |k, v| ~ccBuses.setAt(~busNames[k].index, v) };

	// ---- Pad starting sound (CC 67–76, normalised fader values; see synths/pad.scd) ----
	// A dark, slowly blooming pad with a clearly audible tape wow. Presets saved before the pad existed have no
	// values for it and leave these as they are.
	~padDefaults = (
		volume: 0.7, wobble: 0.55, wobbleRate: 0.35, detune: 0.5, tone: 0.42, wave: 0.25,
		age: 0.45, attack: 0.6, release: 0.65, reverb: 0.4
	);
	~padDefaults.keysValuesDo { |k, v| ~ccBuses.setAt(~busNames[("pad_" ++ k).asSymbol].index, v) };

	// ---- Audio buses ----
	~micBus      = Bus.audio(s, 1);   // mono microphone input
	~grainSrcBus = Bus.audio(s, 1);   // selected sources (guitar / cembalo / tape / pad) → \rec + FFT effect
	~cembaloOutBus = Bus.audio(s, 2); // cembalo output → cembalo output stage + grain input mixer
	~ptrBus      = Bus.audio(s, 1);   // record pointer
	~fftInBus    = Bus.audio(s, 2);   // grain → FFT stage input
	~grainOutBus = Bus.audio(s, 2);   // FFT stage output → grain master
	~tapeOutBus  = Bus.audio(s, 2);   // \ape output → tape output stage
	~padOutBus   = Bus.audio(s, 2);   // pad output → its output stage + grain input mixer
	~freqBus     = Bus.control(s, 1); // tracker mono pitch output
	~ampBus      = Bus.control(s, 1); // tracker amplitude output
	s.sync;

	// ---- Groups (ordered for signal flow) ----
	// The tape synth, the cembalo and the pad run before the recorder, so they can be fed into the grain buffer.
	~micGrp     = Group.new;
	~tartiniGrp = Group.after(~micGrp);
	~tapeGrp    = Group.after(~tartiniGrp);
	~cembaloGrp = Group.after(~tapeGrp);
	~padGrp     = Group.after(~cembaloGrp);
	~srcGrp     = Group.after(~padGrp);
	~ptrGrp     = Group.after(~srcGrp);
	~recGrp     = Group.after(~ptrGrp);
	~granGrp    = Group.after(~recGrp);
	~fftGrp     = Group.after(~granGrp);
	~masterGrp  = Group.after(~fftGrp);
	s.sync;
	~outputSafety = Synth(\outputSafety, [], s, \addToTail);  // stays the last node: groups go before it

	// ---- Buffer setup ----
	~bufferDurSec = 4.0;
	b = Buffer.alloc(s, s.sampleRate * ~bufferDurSec, 1);
	s.sync; // wait for buffer allocation before any UGen accesses it

	// ---- Granular chain ----
	~mic = Synth(\mic, [\in, 0, \out, ~micBus], ~micGrp);
	~grainSrcMix = Synth(\grainSource, [
		\out,       ~grainSrcBus,
		\guitarIn,  ~micBus,
		\cembaloIn, ~cembaloOutBus,
		\tapeIn,    ~tapeOutBus,
		\padIn,     ~padOutBus,
		\guitar,    ~grainSrc[\guitar].asInteger,
		\cembalo,   ~grainSrc[\cembalo].asInteger,
		\tape,      ~grainSrc[\tape].asInteger,
		\pad,       ~grainSrc[\pad].asInteger,
	], ~srcGrp);
	~ptr = Synth(\ptr, [\out, ~ptrBus, \buf, b], ~ptrGrp);
	~rec = Synth(\rec, [
		\ccBus,     ~ccBuses,
		\ptrIn,     ~ptrBus,
		\micIn,     ~grainSrcBus,
		\buf,       b,
		\recGate,   0,
		\xfadeTime, 0.05
	], ~recGrp);

	~g = Synth(\gran, [
		\ccBus,           ~ccBuses,
		\amp,             1.0,
		\buf,             b,
		\out,             ~fftInBus,
		\atk,             0,
		\rel,             1,
		\gate,            1,
		\sync,            1,
		\dens,            40,
		\baseDur,         0.1,
		\durRand,         1,
		\rate,            1.0,
		\rateRand,        1.0,
		\panRand,         0,
		\grainEnv,        -1,
		\ptrBus,          ~ptrBus,
		\ptrSampleDelay,  20000,
		\ptrRandSamples,  5000,
		\minPtrDelay,     1000,
		\safeMargin,      0.02,
		\filterFreq,      15000,
		\reverseGrain,    0,
		\bitDepth,        1,
		\bitVol,          1,
		\freqModAmt,      0,
		\freqModFreq,     0,
		\fixedPos,        0,
		\fixedPosSec,     0,
		\randDetune,      0,
		\randomOctave,    1,
		\octaveGroups,    1,
		\densFromDurMode, 0,
		\timeStretch,     1.0,
		\pitchTrackMode,  0,
		\freqTrackBus,    ~freqBus.index,
		\ampTrackBus,     ~ampBus.index,
		\ptRateScale,     0.0,
		\ptDensOverlap,   2.0,
	], ~granGrp);

	// Spectral feedback effect (synths/fft_prism.scd); all its controls are CC slots (page "fft" on the tablet).
	// Tweak: ~fftFx.set(\loopLevel, 0.15)  level endless feedback settles at (0.15 = about -16 dB)
	~fftFx = Synth(\fftPrism, [
		\micIn,  ~grainSrcBus,
		\granIn, ~fftInBus,
		\ccBus,  ~ccBuses,
		\out,    ~grainOutBus,
	], ~fftGrp);

	// ---- Polyphonic pitch tracker (shared; used by \apePoly, the cembalo and \pad) ----
	// ~tartini keeps its old name. It only runs while the tape synth, the cembalo or the pad is in use (~updateChains).
	~tartini = ~polyTrackerNew.(s, (
		inChan: 0, freqBus: ~freqBus, ampBus: ~ampBus,
		target: ~tartiniGrp, addAction: \addToHead
	)).start;

	// ---- Tape chain ----
	// \apePoly = \ape with one oscillator per tracked note (up to 6), so chords are played as chords.
	// It reads badness/wavemix/etc. from CC slots 90–96 (baked in at compile time), like \ape, and the pluck amount
	// (picking position, classes/pluckpos.scd) from slot 97.
	// Tweak: ~ape.set(\voiceBalance, 0)  all notes equally loud (1 = follow the guitar's note levels)
	//        ~ape.set(\rel, 0.5)          longer note release (s);  \atk attack (s);  \freqLag pitch smoothing (s)
	~ape = Synth(\apePoly, [
		\ccBus,   ~ccBuses,
		\polyBus, ~tartini[\block].index,
		\vol,     ~ampBus.index,
		\in,      ~micBus,            // guitar: picking position (the /tape/pluck fader)
		\out,     ~tapeOutBus,
	], ~tapeGrp);

	// ---- Cembalo chain ----
	// Plucked by the tracker's note-ons; its velocity follows the guitar input (~micBus).
	// Its output goes to ~cembaloOutBus: heard via ~cembaloMaster, fed to the grains via ~grainSrcMix.
	// Parameters come from the /cembalo/* faders (normalised 0..1, stored in CC slots 100–109).
	~cembaloSpecs = (
		volume: ControlSpec(0, 1),           bright: ControlSpec(0, 1),
		noise:  ControlSpec(0, 1),           warmth: ControlSpec(0, 1),
		weird:  ControlSpec(0, 1),           octave: ControlSpec(0, 1),
		decay:  ControlSpec(0.5, 10, \exp),  // ring time of a 220 Hz note (s)
		revMix: ControlSpec(0, 1),           room:   ControlSpec(0, 1),
		pluck:  ControlSpec(0, 1),           // how much the picking position shapes each note (0 = off)
	);
	// defaults in real units
	// (blended with ~tapeDefaults: the cembalo plays the attacks, the tape synth the sustained bed)
	~cembaloDefaults = (volume: 1.0, bright: 0.2, noise: 0.55, warmth: 0.8, weird: 0.35, octave: 0.3,
		decay: 3.5, revMix: 0.25, room: 0.8, pluck: 0);
	~cembaloNorm = ();  // current normalised fader values (language-side mirror of CC 100–109)

	~cembalo = ~cembaloNew.(s, ~tartini, (
		inBus: ~micBus, out: ~cembaloOutBus, target: ~cembaloGrp, maxVoices: 12
	));

	// Set one cembalo parameter from a normalised 0..1 value: cembalo + CC slot (presets) + TouchOSC feedback.
	~setCembaloParam = { |key, norm|
		var spec = ~cembaloSpecs[key];
		if(spec.notNil) {
			norm = norm.clip(0.0, 1.0);
			~cembaloNorm[key] = norm;
			~ccBuses.setAt(~busNames[("cembalo_" ++ key).asSymbol].index, norm);
			~cembalo.set(key, spec.map(norm));
			~sendToTouchOSC !? { ~sendToTouchOSC.("/cembalo/" ++ key, norm) };
		} {
			("cembalo: no fader for %".format(key)).warn;
		};
	};
	~cembaloDefaults.keysValuesDo { |k, v| ~setCembaloParam.(k, ~cembaloSpecs[k].unmap(v)) };

	// Preset load hook (osc/presets.scd): apply the stored cembalo faders to the cembalo.
	// Presets from before the pluck faders existed have no value for them: they load with pluck off, as saved.
	~onPresetFaders = { |faders|
		~cembaloSpecs.keysDo { |k|
			var v = faders[~busNames[("cembalo_" ++ k).asSymbol].index];
			if(v.isNil and: { k == \pluck }) { v = 0 };
			v !? { ~setCembaloParam.(k, v) };
		};
		if(faders[~busNames[\tape_pluck].index].isNil) { ~ccBuses.setAt(~busNames[\tape_pluck].index, 0) };
		// Presets from before the FFT effect: its new controls load neutral (the level fader is stored, as before)
		~fftDefaults.keysValuesDo { |k, v|
			var idx = ~busNames[k].index;
			if(faders[idx].isNil) { ~ccBuses.setAt(idx, v); faders[idx] = v };
		};
	};

	// Picking position calibration, the same for the tape synth and the cembalo (classes/pluckpos.scd).
	// Switch the cembalo on, ~cembalo.monitor(true), pick single notes in the usual place: ref = the typical
	// "as a 220 Hz note" value. Then pick at the bridge and at the neck: span = octaves between those and ref.
	//   ~setPluckCal.(ref: 1200);   ~setPluckCal.(span: 0.5);
	~setPluckCal = { |ref, span, track|
		[[\pluckRef, ref], [\pluckSpan, span], [\pluckTrack, track]].do { |kv|
			kv[1] !? { ~cembalo.set(kv[0], kv[1]); ~ape.set(kv[0], kv[1]) };
		};
	};

	// ---- Pad chain ----
	// \pad (synths/pad.scd): one pad voice per tracked note. It reads its faders from CC slots 67–76
	// (/pad/*), its own volume included, so presets and the generic fader handler work without extra code.
	// Tweak: ~pad.set(\voiceBalance, 1)  follow the guitar's note levels (0 = all notes equally loud)
	//        ~pad.set(\freqLag, 0.2)     slower glide between pitches (s)
	~pad = Synth(\pad, [
		\ccBus,   ~ccBuses,
		\polyBus, ~tartini[\block].index,
		\out,     ~padOutBus,
	], ~padGrp);

	// ---- Master synths ----
	// Grain master: reads CC 11 (masterVol) via \master SynthDef; starts enabled.
	~grainMaster = Synth(\master, [
		\inBus, ~grainOutBus,
		\ccBus, ~ccBuses,
		\out,   0,
		\amp,   1.0,
	], ~masterGrp);

	// Tape output stage: pure amp gate; \ape handles its own vol via CC 96.
	// Starts disabled (amp 0.0) — enable with ~tapeMaster.set(\amp, 1.0).
	~tapeMaster = Synth(\tapeOutput, [
		\inBus, ~tapeOutBus,
		\out,   0,
		\amp,   0.0,
	], ~masterGrp);

	// Cembalo output stage: same gate; the cembalo's own volume is the /cembalo/volume fader.
	~cembaloMaster = Synth(\tapeOutput, [
		\inBus, ~cembaloOutBus,
		\out,   0,
		\amp,   0.0,
	], ~masterGrp);

	// Pad output stage: same gate; the pad's own volume is the /pad/volume fader.
	~padMaster = Synth(\tapeOutput, [
		\inBus, ~padOutBus,
		\out,   0,
		\amp,   0.0,
	], ~masterGrp);

	// ---- Which chains run ----
	// tape synth: runs while audible (~synthEnabled[\tape]) or fed to the grains (~grainSrc[\tape]); same for the cembalo
	// and the pad.
	// The pitch tracker runs while either of them runs. Everything else is paused (no CPU).
	// Call ~updateChains.() after changing ~synthEnabled or ~grainSrc.
	~chainNeeds = {
		var ape  = ~synthEnabled[\tape]    or: { ~grainSrc[\tape] };
		var cemb = ~synthEnabled[\cembalo] or: { ~grainSrc[\cembalo] };
		var pad  = ~synthEnabled[\pad]     or: { ~grainSrc[\pad] };
		(ape: ape, cembalo: cemb, pad: pad, tracker: ape or: { cemb } or: { pad })
	};

	~pauseUnusedChains = {
		var need = ~chainNeeds.();
		if(need[\ape].not) { ~ape.run(false) };
		if(need[\cembalo].not and: { ~cembalo[\enabled] }) { ~cembalo.enable(false) };
		if(need[\pad].not) { ~pad.run(false) };
		if(need[\tracker].not) { ~tartini.run(false) };
		if(~synthEnabled[\tape].not)    { ~tapeMaster.run(false) };
		if(~synthEnabled[\cembalo].not) { ~cembaloMaster.run(false) };
		if(~synthEnabled[\pad].not)     { ~padMaster.run(false) };
	};

	~updateChains = {
		var need = ~chainNeeds.();
		// start what is needed now
		if(need[\tracker]) { ~tartini.run(true) };
		if(need[\ape]) { ~ape.run(true) };
		if(need[\cembalo] and: { ~cembalo[\enabled].not }) { ~cembalo.enable(true) };
		if(need[\pad]) { ~pad.run(true) };
		if(~synthEnabled[\tape])    { ~tapeMaster.run(true) };
		if(~synthEnabled[\cembalo]) { ~cembaloMaster.run(true) };
		if(~synthEnabled[\pad])     { ~padMaster.run(true) };
		// gains (all lagged, so switching is click-free)
		~tapeMaster.set(\amp, ~synthEnabled[\tape].asInteger);
		~cembaloMaster.set(\amp, ~synthEnabled[\cembalo].asInteger);
		~padMaster.set(\amp, ~synthEnabled[\pad].asInteger);
		~grainSrcMix.set(
			\guitar,  ~grainSrc[\guitar].asInteger,
			\cembalo, ~grainSrc[\cembalo].asInteger,
			\tape,    ~grainSrc[\tape].asInteger,
			\pad,     ~grainSrc[\pad].asInteger
		);
		// pause the rest once faded out (re-checked then, in case it was switched back on meanwhile)
		AppClock.sched(0.25, { ~pauseUnusedChains.(); nil });
	};

	~pauseUnusedChains.();  // boot: only the grain chain (guitar in) runs

	// ---- Master volume helper (grain chain) ----
	// Single point of control: sets CC 11 bus + sends /master/volume to TouchOSC.
	~setMasterVol = { |val|
		val = val.clip(0.0, 1.0);
		~ccBuses.setAt(~busNames[\masterVol].index, val);
		~touchOSC !? { ~touchOSC.sendMsg('/master/volume', val.asFloat) };
	};

	~setMasterVol.(1.0);

	// ---- State variables for grain toggles ----
	~reverseState   = false;
	~fixedPosState  = false;
	~fftFreezeState = false;
	~currentRate    = 1.0;
	~xyMode           = false;
	~densFromDurState = false;
	~pitchTrackMode   = false;
	~ptRateScale      = 0.0;
	~ptFixedPosSec    = 0.0;

	// ---- MultiXY voice state (5 pads = 5 fingers, 5 voices) ----
	// A pad is not tied to a voice: with HOLD, a voice keeps sounding after its finger has left, and the next
	// touch starts another one (see "MultiXY" below).
	~xyVoices      = Array.newClear(5);   // the \gran synths
	~xyVoiceState  = Array.newClear(5);   // per voice: (rec:, x:, y:, speed:, lastTime:, born:, task:)
	~xyPadVoice    = Array.newClear(5);   // pad index -> voice index while the pad is touched
	~xyMaxGrainsHz = 80;
	~xyMap         = \classic;            // which mapping the pads use (~xyMaps)
	~xyHold        = false;

	~updateXYDensCap = {
		var count = ~xyVoices.select(_.notNil).size.max(1);
		var capHz  = ~xyMaxGrainsHz / count;
		~xyVoices.do { |v| v !? { v.set(\maxDensHz, capHz) } };
	};

	// ============================================================
	// Grain buffer: LIVE mode, samples
	// ============================================================
	// The buffer is a loop of ~bufferDurSec seconds; the write head runs through it all the time.
	//   LIVE on:  the grain input is written into the loop. Overdub: the Feedback fader sets how much of the old
	//             content stays. Grains and XY voices follow just behind the head.
	//   LIVE off: nothing is written, the loop keeps playing. XY voices play fixed positions.
	// LIVE (/grain/liveMode) is the loop's one switch. CLEAR empties the loop. The four SAMPLE slots on the preset
	// page put a sample into it (the first four files of samples/, alphabetically) and switch LIVE off, so the
	// sample is not overwritten right away.
	// The status line (/grain/recStatus) says what the loop holds: LIVE / LOOP / sample name / EMPTY.
	~liveMode      = false;
	~bufferContent = \empty;   // \empty | \recorded | \sample (status line only)
	~sampleName    = nil;
	~samplePath    = nil;      // the file in the buffer (stored in presets), nil = no sample
	~samplesDir    = ~basePath ++ "samples/";
	~sampleExtensions = #["wav", "aif", "aiff", "flac", "ogg", "mp3"];  // mp3: needs libsndfile 1.1 or newer
	~sampleSlotCount  = 4;
	~sampleSlotNames  = #["A", "B", "C", "D"];

	~sendBufferStatus = {
		var len = ~bufferDurSec.round(0.1).asString ++ " s";
		var text = case
			{ ~liveMode } { "LIVE  " ++ len }
			{ ~bufferContent == \sample } { (~sampleName ? "sample").keep(16) ++ "  " ++ len }
			{ ~bufferContent == \recorded } { "LOOP  " ++ len }
			{ "EMPTY  " ++ len };
		~touchOSC !? {
			~touchOSC.sendMsg('/grain/liveMode', ~liveMode.asInteger.asFloat);
			~touchOSC.sendMsg('/grain/recStatus', text);
		};
	};

	// Sound files of samples/, alphabetically (name them "1 rain.wav", "2 voice.wav", ... to order the slots)
	~sampleFiles = {
		if (File.exists(~samplesDir)) {
			PathName(~samplesDir).files.select { |f| ~sampleExtensions.includesEqual(f.extension.toLower) }
				.sort { |f1, f2| f1.fileName < f2.fileName }
		} { [] };
	};

	// Preset page: /preset/sample/N (lit = this sample is in the buffer), label /preset/sampleLabel/N
	~sendSampleSlots = {
		var files = ~sampleFiles.();
		~touchOSC !? {
			~sampleSlotCount.do { |i|
				var f = files[i];
				~touchOSC.sendMsg("/preset/sampleLabel/" ++ i,
					~sampleSlotNames[i] ++ "   " ++ if (f.notNil) { f.fileNameWithoutExtension.keep(18) } { "-" });
				~touchOSC.sendMsg("/preset/sample/" ++ i,
					(f.notNil and: { f.fullPath == ~samplePath }).asInteger.asFloat);
			};
		};
	};

	~setLiveMode = { |on|
		~liveMode = on;
		~rec.set(\recGate, on.asInteger);
		if (on) {
			~bufferContent = \recorded;
			~sampleName = nil;
			~samplePath = nil;
			~sendSampleSlots.();
		};
		~sendBufferStatus.();
		("Live mode: " ++ if (on, "ON", "OFF (holding the loop)")).postln;
	};

	// Point every reader / writer at a new buffer, then free the old one
	~switchBuffer = { |buf|
		var old = b;
		b = buf;
		~ptr.set(\buf, buf);
		~rec.set(\buf, buf);
		~g.set(\buf, buf);
		~xyVoices.do { |v| v !? { v.set(\buf, buf) } };
		if (old.notNil and: { old != buf }) { s.sendBundle(0.2, old.freeMsg) };  // after the readers moved
		~bufferDurSec = buf.duration;
	};

	~deleteBuffer = {
		b.zero;
		~bufferContent = if (~liveMode) { \recorded } { \empty };
		~sampleName = nil;
		~samplePath = nil;
		~sendBufferStatus.();
		~sendSampleSlots.();
		"Buffer cleared.".postln;
	};

	// The BufferLen fader (0.1 .. 8 s) follows the buffer's length, e.g. a loaded sample's; the label shows the
	// exact length (a sample longer than 8 s puts the fader at the top). Stored in presets like any fader.
	~showBufferLen = { |durSec|
		var val = durSec.linlin(0.1, 8.0, 0.0, 1.0);
		~ccBuses.setAt(~busNames[\bufferLen].index, val);
		~sendToTouchOSC !? { ~sendToTouchOSC.('/grain/bufferLen', val) };
		~sendBufferLenLabel !? { ~sendBufferLenLabel.(durSec) };
	};

	// path: a sound file. Only the first channel of a stereo file is used.
	~loadBuffer = { |path|
		path !? {
			~setLiveMode.(false);
			Buffer.readChannel(s, path, channels: [0], action: { |buf|
				if (buf.numFrames.isNil or: { buf.numFrames < 64 }) {
					// unreadable or empty file: keep the loop as it is
					buf.free;
					~touchOSC !? { ~touchOSC.sendMsg('/grain/recStatus', "cannot read " ++ PathName(path).fileName.keep(14)) };
					("Sample could not be read: " ++ path).warn;
				} {
					~switchBuffer.(buf);
					~bufferContent = \sample;
					~samplePath = path;
					~sampleName = PathName(path).fileNameWithoutExtension;
					~showBufferLen.(~bufferDurSec);
					~sendBufferStatus.();
					~sendSampleSlots.();
					("Sample loaded: % (% s)".format(path, ~bufferDurSec.round(0.01))).postln;
				};
			});
		};
	};

	// Preset page sample slot i (0..3): the i-th sound file of samples/
	~loadSampleSlot = { |i|
		var f = ~sampleFiles.()[i];
		if (f.isNil) {
			("Sample slot %: no file (samples/ has fewer than % sound files)".format(~sampleSlotNames[i], i + 1)).warn;
			~sendSampleSlots.();
		} {
			~loadBuffer.(f.fullPath);
		};
	};

	// New, empty buffer of durSec seconds; LIVE stays as it is
	~allocBuffer = { |durSec|
		durSec = durSec ? ~bufferDurSec;
		fork {
			var buf = Buffer.alloc(s, (s.sampleRate * durSec).round.asInteger, 1);
			s.sync;
			~switchBuffer.(buf);
			~bufferContent = if (~liveMode) { \recorded } { \empty };
			~sampleName = nil;
			~samplePath = nil;
			~sendBufferLenLabel !? { ~sendBufferLenLabel.(durSec) };  // the label; the fader keeps its 0..1 value
			~sendBufferStatus.();
			~sendSampleSlots.();
			("Buffer allocated: " ++ durSec.round(0.01) ++ " s (" ++ buf.numFrames ++ " frames)").postln;
		};
	};

	// ============================================================
	// Output recorder: what the instrument plays, into a file
	// ============================================================
	// REC (right column, /record/disk) records hardware outputs 1-2 after the output safety stage, i.e. exactly what
	// you hear, into recordings/ (or $REC_DIR) as 24-bit WAV, one file per take: multi_2026-11-17_20-15-03.wav.
	// The button's label shows the running time (/record/status). Stopping closes the file and flushes it to the
	// card (sync). A take that is still running when the power goes is cut off and may need repairing.
	// From code: ~startOutputRecording.()  /  ~stopOutputRecording.()
	~outRecDir = "REC_DIR".getenv;
	if (~outRecDir.isNil or: { ~outRecDir.isEmpty }) { ~outRecDir = ~basePath ++ "recordings/" };
	~outRecDir = ~outRecDir.standardizePath.withTrailingSlash;
	~outRecState = false;
	~outRecStart = 0;
	~outRecPath  = nil;
	~outRecTask  = nil;

	~outRecTime = { |sec|
		sec = sec.asInteger;
		(sec div: 60).asString ++ ":" ++ (sec % 60).asString.padLeft(2, "0")
	};

	~sendOutRecStatus = {
		~touchOSC !? {
			~touchOSC.sendMsg('/record/disk', ~outRecState.asInteger.asFloat);
			~touchOSC.sendMsg('/record/status',
				if (~outRecState) { "● REC  " ++ ~outRecTime.(Main.elapsedTime - ~outRecStart) } { "REC" });
		};
	};

	~startOutputRecording = {
		if (~outRecState.not) {
			File.mkdir(~outRecDir);
			~outRecPath = ~outRecDir ++ "multi_" ++ Date.getDate.format("%Y-%m-%d_%H-%M-%S") ++ ".wav";
			s.recorder.recHeaderFormat = "wav";
			s.recorder.recSampleFormat = "int24";
			s.recorder.record(~outRecPath, 0, 2);
			~outRecState = true;
			~outRecStart = Main.elapsedTime;
			// running time on the tablet; notices when the recorder stopped by itself (server gone, disk error)
			~outRecTask = Routine({
				loop {
					~sendOutRecStatus.();
					1.wait;
					if ((Main.elapsedTime - ~outRecStart > 3) and: { s.recorder.isRecording.not }) {
						"Output recording stopped by itself (server gone or the file could not be written).".warn;
						~outRecTask = nil;
						~stopOutputRecording.();
						nil.alwaysYield;
					};
				};
			}).play(AppClock);
			("Output recording STARTED: " ++ ~outRecPath).postln;
		};
		~sendOutRecStatus.();
	};

	~stopOutputRecording = {
		if (~outRecState) {
			~outRecState = false;
			~outRecTask !? { ~outRecTask.stop; ~outRecTask = nil };
			if (s.recorder.isRecording) { s.recorder.stopRecording };
			("Output recording STOPPED after %: %".format(~outRecTime.(Main.elapsedTime - ~outRecStart), ~outRecPath)).postln;
			// the server closes the file asynchronously: flush it to the card a moment later
			if (thisProcess.platform.name != \windows) {
				AppClock.sched(1.0, { ("sync -- " ++ ~outRecDir.shellQuote).unixCmd(postOutput: false); nil });
			};
		};
		~sendOutRecStatus.();
	};

	// ============================================================
	// MultiXY: what a finger on the pad does
	// ============================================================
	// Every touch is one \gran voice. A mapping turns the finger (x, y: 0..1, and how fast it moves) into what
	// that voice plays. The buttons under the pad choose the mapping (/grain/xyMap/<name>):
	//   classic  X = place in the loop      Y = longer grains, more detune, crush and scatter (the original mapping)
	//   harp     X = place in the loop      Y = pitch, in steps of a pentatonic scale (middle = as recorded)
	//   bow      X = scrub through the loop Y = brightness. Silent while the finger rests: moving it plays the loop
	//            at the finger's speed and in its direction, like pulling tape past a head. With HOLD, a finger
	//            that leaves while moving keeps its speed: flick it and the note stays
	//   pulse    X = place in the loop      Y = pulse rate in steps (1 .. 32 per second): fingers make polyrhythms
	// A mapping returns: pos (0..1), dur (s), detune, crush (bitDepth: 1.05 clean .. 0.05), scatter (0..1),
	// and optionally rate, amp, pan, dens (grains / s, 0 = the density fader), cutoff (Hz), sync (1 = even, 0 = random).
	// st is the voice's state: st[\speed] = finger speed in loop lengths per second (signed), st[\slot] = 0..4.
	// HOLD (/grain/xyHold): a voice keeps playing when its finger leaves; the next touch adds another voice (up to
	// 5, then the oldest is replaced). HOLD off releases all voices without a finger.
	~xyHarpSteps  = #[-12, -10, -8, -5, -3, 0, 2, 4, 7, 9, 12];   // semitones, one per grid line of the pad
	~xyPulseSteps = #[1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32];     // pulses per second
	~xySlotPan    = #[0, -0.6, 0.6, -0.3, 0.3];
	~xyMaps = (
		classic: (
			hint: "X place in loop   ·   Y grain length + detune + crush + scatter",
			map: { |x, y, st| (
				pos: x, dur: y.linlin(0, 1, 0.01, 1.5), detune: y.linlin(0, 1, 0, 30),
				crush: y.linlin(0, 1, 1.05, 0.7), scatter: y
			) }
		),
		harp: (
			hint: "X place in loop   ·   Y pitch in scale steps (middle = as recorded)",
			map: { |x, y, st| (
				pos: x, dur: 0.3, detune: 2, crush: 1.05, scatter: 0.03,
				rate: ~xyHarpSteps[(y * (~xyHarpSteps.size - 1)).round.asInteger].midiratio,
				dens: 12, pan: x.linlin(0, 1, -0.7, 0.7)
			) }
		),
		bow: (
			hint: "X scrub: move to play, speed = pitch, direction = forwards / backwards   ·   Y brightness",
			moving: true,
			map: { |x, y, st|
				var speed = st[\speed] * ~bufferDurSec;   // loop seconds per second = playback speed
				(
					pos: x, dur: y.linlin(0, 1, 0.14, 0.04), detune: 0, crush: 1.05, scatter: 0,
					rate: speed.abs.clip(0.05, 4) * if (speed < 0) { -1 } { 1 },
					amp: (speed.abs / 0.4).clip(0, 1).sqrt,
					dens: 40, cutoff: y.linexp(0, 1, 400, 18000), pan: ~xySlotPan[st[\slot]] * 0.5
				)
			}
		),
		pulse: (
			hint: "X place in loop   ·   Y pulse rate in steps (1 .. 32 per second)",
			map: { |x, y, st|
				var hz = ~xyPulseSteps[(y * (~xyPulseSteps.size - 1)).round.asInteger];
				(
					pos: x, dur: (0.6 / hz).clip(0.02, 0.25), detune: 0, crush: 1.05, scatter: 0,
					dens: hz, sync: 1, pan: ~xySlotPan[st[\slot]]
				)
			}
		),
	);
	~xyMapOrder = [\classic, \harp, \bow, \pulse];

	// Mapping result -> \gran arguments (the ones that follow the finger)
	~xyVoiceArgs = { |m, st|
		[
			\fixedPosSec,    m[\pos] * ~bufferDurSec,
			\baseDur,        m[\dur],
			\randDetune,     m[\detune],
			\bitDepth,       m[\crush],
			// while recording the voice follows the write head (scatter in time), otherwise it sits on its place
			\ptrRandSamples, if (st[\rec]) { m[\scatter] * 1.5 * s.sampleRate } { 0 },
			\fixedPosRand,   if (st[\rec]) { 0 } { m[\scatter] * 0.2 },
			\xyRate,         m[\rate] ? 1,
			\xyAmp,          m[\amp] ? 1,
			\xyPan,          m[\pan] ? 0,
			\xyDens,         m[\dens] ? 0,
			\xyCutoff,       m[\cutoff] ? 20000,
			\sync,           m[\sync] ? 1,
		]
	};

	// Start or move the voice `slot`
	~playXYVoice = { |slot, x, y|
		var map = ~xyMaps[~xyMap];
		var st  = ~xyVoiceState[slot];
		var now = Main.elapsedTime;
		var dt, pendingCount;
		if (~xyVoices[slot].isNil) {
			st = (slot: slot, rec: ~liveMode, x: x, y: y, speed: 0.0, lastTime: now, born: now);
			~xyVoiceState[slot] = st;
			pendingCount = (~xyVoices.select(_.notNil).size + 1).max(1);
			~xyVoices[slot] = Synth(\gran, [
				\ccBus,       ~ccBuses,
				\amp,         1.0,
				\buf,         b,
				\out,         ~fftInBus,
				\atk,         0.01,
				\rel,         0.15,
				\gate,        1,
				\xyMode,      1,
				\minPtrDelay, 0,
				\maxDensHz,   ~xyMaxGrainsHz / pendingCount,
				\fixedPos,    if (st[\rec]) { 0 } { 1 },
				\safeMargin,  if (st[\rec]) { 0.02 } { 0.0 },
			] ++ ~xyVoiceArgs.(map[\map].(x, y, st), st), ~granGrp);
			// mappings that react to movement: let the speed die away once the finger rests (no messages then).
			// A held voice (finger gone) keeps the speed it was left with.
			if (map[\moving] == true) {
				st[\task] = Routine({
					loop {
						0.03.wait;
						if ((Main.elapsedTime - st[\lastTime] > 0.05) and: { ~xyPadVoice.includes(slot) }) {
							st[\speed] = st[\speed] * 0.6;
							~xyVoices[slot] !? { |v| v.set(*~xyVoiceArgs.(map[\map].(st[\x], st[\y], st), st)) };
						};
					};
				}).play(AppClock);
			};
			~updateXYDensCap.();
		} {
			// finger speed in loop lengths per second, smoothed (the tablet sends up to ~60 positions per second)
			dt = (now - st[\lastTime]).max(0.004);
			st[\speed] = (st[\speed] * 0.6) + ((x - st[\x]) / dt * 0.4);
			st[\x] = x; st[\y] = y; st[\lastTime] = now;
			~xyVoices[slot].set(*~xyVoiceArgs.(map[\map].(x, y, st), st));
		};
	};

	~releaseXYVoice = { |slot|
		~xyVoiceState[slot] !? { |st| st[\task] !? { st[\task].stop } };
		~xyVoiceState[slot] = nil;
		~xyPadVoice.do { |v, pad| if (v == slot) { ~xyPadVoice[pad] = nil } };
		if (~xyVoices[slot].notNil) {
			~xyVoices[slot].set(\gate, 0);
			~xyVoices[slot] = nil;
			~updateXYDensCap.();
		};
	};

	// A pad reports a finger: z > 0 down / moving, z <= 0 lifted
	~xyTouch = { |pad, x, y, z|
		var slot = ~xyPadVoice[pad];
		if (z <= 0) {
			if (slot.notNil) {
				~xyPadVoice[pad] = nil;
				if (~xyHold.not) { ~releaseXYVoice.(slot) };
			};
		} {
			if (~xyMode) {
				if (slot.isNil) {
					// new touch: a free voice, else (HOLD) the oldest voice no finger is on
					slot = (0..4).detect { |i| ~xyVoices[i].isNil };
					slot = slot ?? {
						var held = (0..4).reject { |i| ~xyPadVoice.includes(i) };
						held = held.sort { |i, j| ~xyVoiceState[i][\born] < ~xyVoiceState[j][\born] };
						held.first !? { |i| ~releaseXYVoice.(i); i }
					};
					~xyPadVoice[pad] = slot;
				};
				slot !? { ~playXYVoice.(slot, x, y) };
			};
		};
	};

	~releaseAllXYVoices = { 5.do { |i| ~releaseXYVoice.(i) } };

	~setXYMap = { |name|
		if (~xyMaps.includesKey(name)) {
			if (name != ~xyMap) { ~releaseAllXYVoices.() };  // the voices were set up for the other mapping
			~xyMap = name;
			~sendXYState !? { ~sendXYState.() };
			("XY mapping: " ++ name).postln;
		};
	};

	~setXYHold = { |on|
		~xyHold = on;
		if (on.not) { 5.do { |i| if (~xyPadVoice.includes(i).not) { ~releaseXYVoice.(i) } } };
		~sendXYState !? { ~sendXYState.() };
		("XY hold: " ++ if (on, "ON", "OFF")).postln;
	};

	// ---- OSC control layer ----
	thisProcess.interpreter.executeFile(~basePath ++ "osc/oscconfig_multi.scd");
	thisProcess.interpreter.executeFile(~basePath ++ "osc/presets.scd");
	// Tablet layout version check (needs every OSCdef registered, so after presets.scd)
	thisProcess.interpreter.executeFile(~basePath ++ "osc/ui_version.scd");

	// ---- Boot sync: send state to TouchOSC ----
	AppClock.sched(0.5, {
		if (s.serverRunning) {
			if (~loadPreset.(0).not) { ~sendAllState.() };  // missing or damaged preset 0: plain state
		};
		nil;
	});
	AppClock.sched(3.0, {
		if (s.serverRunning) {
			if (~loadPreset.(0).not) { ~sendAllState.() };  // missing or damaged preset 0: plain state
		};
		nil;
	});

	"Multi-synth patch booted (grain ON, tape OFF, cembalo OFF, pad OFF; grain input: guitar).".postln;
	// Level meters: only where somebody can see them. On the headless Pi (Qt offscreen, see run-sc-main_multi.sh)
	// they would cost a metering synth and 20 window updates per second in sclang for nothing.
	if("QT_QPA_PLATFORM".getenv != "offscreen") { s.meter };
};
)
