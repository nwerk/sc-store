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
// fft_freeze.scd uses ~busNames[\fftFreeze] etc. (grain indices, unchanged)
// fft_freeze.scd needs PV_Freeze / PV_Morph from sc3-plugins. Without them the whole file fails to compile, \fftFreeze
// never exists, and the grain output (it is routed through that synth) never reaches the master = silence.
// Fall back to a dry pass-through so the patch still sounds; freeze / filter / morph do nothing until it is installed.
if(\PV_Freeze.asClass.notNil and: { \PV_Morph.asClass.notNil }) {
	thisProcess.interpreter.executeFile(~basePath ++ "synths/fft_freeze.scd");
} {
	"sc3-plugins is not installed (PV_Freeze / PV_Morph missing): FFT freeze/morph DISABLED, grain output passes through dry. Install it with: sudo apt install sc3-plugins".warn;
	SynthDef(\fftFreeze, { |micIn=0, granIn=0, out=0, ccBus=0, freeze=0, fftFilterAmt=0, morphAmt=0, fftVol=0|
		Out.ar(out, In.ar(granIn, 2));
	}).add;
};
// tapeemulate.scd uses ~busNames[\badness] etc. — now baked as 90–96
thisProcess.interpreter.executeFile(~basePath ++ "synths/tapeemulate.scd");
// inputtracker.scd: ~polyTrackerNew (polyphonic ML tracker) + \polyTracker SynthDef (no ~busNames refs)
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");
// master.scd: \master SynthDef uses ~busNames[\masterVol].index = 11 (grain master)
thisProcess.interpreter.executeFile(~basePath ++ "classes/master.scd");
// cembalo.scd: \cembalo voices + ~cembaloNew (plucked by the tracker's note-ons; no ~busNames refs)
thisProcess.interpreter.executeFile(~basePath ++ "synths/cembalo.scd");

// ---- Grain input mixer ----
// Whatever this writes is what \rec puts into the grain buffer (and what the FFT freeze freezes).
// guitar / cembalo / tape are 0..1 gains (the /grain/src* toggles); any combination can be on.
// The stereo synths are summed to mono at -3 dB.
// The sum is limited to 0.9 (10 ms look-ahead; only the recording is delayed, nothing you hear directly):
// \rec hard-clips at ±1, and the tape synth alone peaks around 1.4.
SynthDef(\grainSource, { |out=0, guitarIn=0, cembaloIn=0, tapeIn=0, guitar=1, cembalo=0, tape=0|
	var sig = (In.ar(guitarIn, 1) * guitar.lag(0.05))
		+ (In.ar(cembaloIn, 2).sum * 0.7071 * cembalo.lag(0.05))
		+ (In.ar(tapeIn, 2).sum * 0.7071 * tape.lag(0.05));
	sig = Limiter.ar(Sanitize.ar(sig), 0.9, 0.005);
	Out.ar(out, sig);
}).add;

// ---- Output safety stage (last node on the server) ----
// Whatever happens upstream (grain overlaps adding up, a synth blowing up, NaN / inf), the hardware outputs never
// get more than `ceiling` (≈ -0.5 dBFS): bad values become silence, DC is removed, peaks are limited
// (5 ms look-ahead = 10 ms latency).
SynthDef(\outputSafety, { |ceiling=0.95|
	var sig = Sanitize.ar(In.ar(0, 2));
	sig = LeakDC.ar(sig);
	sig = Limiter.ar(sig, ceiling, 0.005);
	ReplaceOut.ar(0, Sanitize.ar(sig).clip(-1, 1));
}).add;

// ---- Tape / cembalo output stage SynthDef (inline — cannot use \master, which hardcodes CC 11) ----
// \ape already applies its own master_vol from CC 96 internally, the cembalo its own volume.
// \tapeOutput is purely a mute/enable gate controlled via ~tapeMaster / ~cembaloMaster .set(\amp, ...).
SynthDef(\tapeOutput, { |out=0, inBus=0, amp=0.0|
	var sig = In.ar(inBus, 2);
	sig = sig * amp.lag(0.1);
	Out.ar(out, sig);
}).add;

s.waitForBoot {
	// ---- System state ----
	~synthEnabled = ( grain: true, tape: false, cembalo: false );  // audible on the outputs
	~grainSrc     = ( guitar: true, cembalo: false, tape: false );  // fed into the grain buffer
	~focusedSynth = \grain;

	// ---- CC slots: FIRST control buses after the boot (see midi/midiconfig_multi.scd) ----
	~ccBuses = Bus.control(s, 128);
	~ccBuses.setn(Array.fill(128, 0.0));

	// ---- Tape synth starting sound (CC 90–96), so it plays without the tablet (footswitch) ----
	// A soft, slightly wobbly sine/saw pad under the cembalo. master 0.1 puts its level (RMS) about level with the
	// cembalo's (measured with a strummed test signal; at 0.35 the tape was 14 dB louder and covered the plucks).
	// A preset that contains tape values replaces these.
	~tapeDefaults = (
		badness: 0.12, wavemix: 0.35, wavemap: 0.15, badnessmap: 0.1,
		reverb_mix: 0.35, reverb_room: 0.75, master: 0.1
	);
	~tapeDefaults.keysValuesDo { |k, v| ~ccBuses.setAt(~busNames[k].index, v) };

	// ---- Audio buses ----
	~micBus      = Bus.audio(s, 1);   // mono microphone input
	~grainSrcBus = Bus.audio(s, 1);   // selected sources (guitar / cembalo / tape) → \rec + FFT freeze
	~cembaloOutBus = Bus.audio(s, 2); // cembalo output → cembalo output stage + grain input mixer
	~ptrBus      = Bus.audio(s, 1);   // record pointer
	~fftInBus    = Bus.audio(s, 2);   // grain → FFT stage input
	~grainOutBus = Bus.audio(s, 2);   // FFT stage output → grain master
	~tapeOutBus  = Bus.audio(s, 2);   // \ape output → tape output stage
	~freqBus     = Bus.control(s, 1); // tracker mono pitch output
	~ampBus      = Bus.control(s, 1); // tracker amplitude output
	s.sync;

	// ---- Groups (ordered for signal flow) ----
	// The tape synth and the cembalo run before the recorder, so they can be fed into the grain buffer.
	~micGrp     = Group.new;
	~tartiniGrp = Group.after(~micGrp);
	~tapeGrp    = Group.after(~tartiniGrp);
	~cembaloGrp = Group.after(~tapeGrp);
	~srcGrp     = Group.after(~cembaloGrp);
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
		\guitar,    ~grainSrc[\guitar].asInteger,
		\cembalo,   ~grainSrc[\cembalo].asInteger,
		\tape,      ~grainSrc[\tape].asInteger,
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
	], ~granGrp);

	~fftFx = Synth(\fftFreeze, [
		\micIn,       ~grainSrcBus,
		\granIn,      ~fftInBus,
		\ccBus,       ~ccBuses,
		\out,         ~grainOutBus,
		\freeze,      0,
		\fftFilterAmt,0,
		\morphAmt,    0,
	], ~fftGrp);

	// ---- Polyphonic pitch tracker (shared; used by \apePoly and the cembalo) ----
	// ~tartini keeps its old name. It only runs while the tape synth or the cembalo is in use (~updateChains).
	~tartini = ~polyTrackerNew.(s, (
		inChan: 0, freqBus: ~freqBus, ampBus: ~ampBus,
		target: ~tartiniGrp, addAction: \addToHead
	)).start;

	// ---- Tape chain ----
	// \apePoly = \ape with one oscillator per tracked note (up to 6), so chords are played as chords.
	// It reads badness/wavemix/etc. from CC slots 90–96 (baked in at compile time), like \ape.
	// Tweak: ~ape.set(\voiceBalance, 0)  all notes equally loud (1 = follow the guitar's note levels)
	//        ~ape.set(\rel, 0.5)          longer note release (s);  \atk attack (s);  \freqLag pitch smoothing (s)
	~ape = Synth(\apePoly, [
		\ccBus,   ~ccBuses,
		\polyBus, ~tartini[\block].index,
		\vol,     ~ampBus.index,
		\out,     ~tapeOutBus,
	], ~tapeGrp);

	// ---- Cembalo chain ----
	// Plucked by the tracker's note-ons; its velocity follows the guitar input (~micBus).
	// Its output goes to ~cembaloOutBus: heard via ~cembaloMaster, fed to the grains via ~grainSrcMix.
	// Parameters come from the /cembalo/* faders (normalised 0..1, stored in CC slots 100–108).
	~cembaloSpecs = (
		volume: ControlSpec(0, 1),           bright: ControlSpec(0, 1),
		noise:  ControlSpec(0, 1),           warmth: ControlSpec(0, 1),
		weird:  ControlSpec(0, 1),           octave: ControlSpec(0, 1),
		decay:  ControlSpec(0.5, 10, \exp),  // ring time of a 220 Hz note (s)
		revMix: ControlSpec(0, 1),           room:   ControlSpec(0, 1),
	);
	// defaults in real units
	// (blended with ~tapeDefaults: the cembalo plays the attacks, the tape synth the sustained bed)
	~cembaloDefaults = (volume: 1.0, bright: 0.2, noise: 0.55, warmth: 0.8, weird: 0.35, octave: 0.3,
		decay: 3.5, revMix: 0.25, room: 0.8);
	~cembaloNorm = ();  // current normalised fader values (language-side mirror of CC 100–108)

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
	~onPresetFaders = { |faders|
		~cembaloSpecs.keysDo { |k|
			var v = faders[~busNames[("cembalo_" ++ k).asSymbol].index];
			v !? { ~setCembaloParam.(k, v) };
		};
	};

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

	// ---- Which chains run ----
	// tape synth: runs while audible (~synthEnabled[\tape]) or fed to the grains (~grainSrc[\tape]); same for the cembalo.
	// The pitch tracker runs while either of them runs. Everything else is paused (no CPU).
	// Call ~updateChains.() after changing ~synthEnabled or ~grainSrc.
	~chainNeeds = {
		var ape  = ~synthEnabled[\tape]    or: { ~grainSrc[\tape] };
		var cemb = ~synthEnabled[\cembalo] or: { ~grainSrc[\cembalo] };
		(ape: ape, cembalo: cemb, tracker: ape or: { cemb })
	};

	~pauseUnusedChains = {
		var need = ~chainNeeds.();
		if(need[\ape].not) { ~ape.run(false) };
		if(need[\cembalo].not and: { ~cembalo[\enabled] }) { ~cembalo.enable(false) };
		if(need[\tracker].not) { ~tartini.run(false) };
		if(~synthEnabled[\tape].not)    { ~tapeMaster.run(false) };
		if(~synthEnabled[\cembalo].not) { ~cembaloMaster.run(false) };
	};

	~updateChains = {
		var need = ~chainNeeds.();
		// start what is needed now
		if(need[\tracker]) { ~tartini.run(true) };
		if(need[\ape]) { ~ape.run(true) };
		if(need[\cembalo] and: { ~cembalo[\enabled].not }) { ~cembalo.enable(true) };
		if(~synthEnabled[\tape])    { ~tapeMaster.run(true) };
		if(~synthEnabled[\cembalo]) { ~cembaloMaster.run(true) };
		// gains (all lagged, so switching is click-free)
		~tapeMaster.set(\amp, ~synthEnabled[\tape].asInteger);
		~cembaloMaster.set(\amp, ~synthEnabled[\cembalo].asInteger);
		~grainSrcMix.set(
			\guitar,  ~grainSrc[\guitar].asInteger,
			\cembalo, ~grainSrc[\cembalo].asInteger,
			\tape,    ~grainSrc[\tape].asInteger
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
	~recState       = false;
	~liveMode       = false;
	~liveRoutine    = nil;
	~reverseState   = false;
	~fixedPosState  = false;
	~fftFreezeState = false;
	~currentRate    = 1.0;
	~xyMode         = false;
	~densFromDurState = false;

	// ---- MultiXY voice state (5 touch slots) ----
	~xyVoices      = Array.newClear(5);
	~xyTimeouts    = Array.newClear(5);
	~xyMaxGrainsHz = 80;

	~updateXYDensCap = {
		var count = ~xyVoices.select(_.notNil).size.max(1);
		var capHz  = ~xyMaxGrainsHz / count;
		~xyVoices.do { |v| v !? { v.set(\maxDensHz, capHz) } };
	};

	// ---- Buffer management functions ----

	~loadBuffer = { |path|
		if (path.notNil) {
			b.free;
			b = Buffer.readChannel(s, path, channels: [0], action: { |buf|
				("Buffer loaded: " ++ path ++ " (" ++ buf.numFrames ++ " frames)").postln;
				~ptr.set(\buf, buf);
				~rec.set(\buf, buf);
				~g.set(\buf, buf);
			});
		} {
			Dialog.openPanel({ |path| ~loadBuffer.(path); });
		};
	};

	~deleteBuffer = {
		b.zero;
		"Buffer cleared.".postln;
	};

	~allocBuffer = { |durSec|
		var wasRecording = ~recState, wasLiveMode = ~liveMode;
		durSec = durSec ? ~bufferDurSec;
		~bufferDurSec = durSec;
		~rec.set(\recGate, 0);
		b.free;
		b = Buffer.alloc(s, s.sampleRate * durSec, 1, completionMessage: { |buf|
			~ptr.set(\buf, buf);
			~rec.set(\buf, buf);
			~g.set(\buf, buf);
			if (wasRecording || wasLiveMode) { ~rec.set(\recGate, 1) };
			("Buffer allocated: " ++ durSec ++ "s (" ++ buf.numFrames ++ " frames)").postln;
			~sendBufferLenLabel !? { ~sendBufferLenLabel.(durSec) };  // the label; the fader keeps its 0..1 value
		});
	};

	// ---- Live mode ----
	~startLiveMode = {
		~liveMode = true;
		~rec.set(\recGate, 1);
		"Live mode ON".postln;
	};

	~stopLiveMode = {
		~liveMode = false;
		~rec.set(\recGate, 0);
		"Live mode OFF".postln;
	};

	// ---- MultiXY voice management ----
	~spawnXYVoice = { |idx, x, y|
		var posSec       = x * ~bufferDurSec;
		var dur          = y.linlin(0, 1, 0.01, 1.5);
		var detune       = y.linlin(0, 1, 0, 30);
		var distortion   = y.linlin(0, 1, 1.05, 0.7);
		var pendingCount = (~xyVoices.select(_.notNil).size + 1).max(1);
		var spawnCap     = ~xyMaxGrainsHz / pendingCount;
		if (~xyMode) {
			var commonArgs = [
				\ccBus,       ~ccBuses,
				\amp,         1.0,
				\buf,         b,
				\out,         ~fftInBus,
				\atk,         0.01,
				\rel,         0.15,
				\gate,        1,
				\sync,        1,
				\xyMode,      1,
				\fixedPosSec, posSec,
				\minPtrDelay, 0,
				\baseDur,     dur,
				\randDetune,  detune,
				\bitDepth,    distortion,
				\maxDensHz,   spawnCap,
			];
			if (~xyVoices[idx].isNil) {
				~xyVoices[idx] = if (~liveMode) {
					Synth(\gran, commonArgs ++ [
						\fixedPos,       0,
						\fixedPosRand,   0,
						\ptrRandSamples, y * 1.5 * s.sampleRate,
						\safeMargin,     0.02,
					], ~granGrp)
				} {
					Synth(\gran, commonArgs ++ [
						\fixedPos,       1,
						\fixedPosRand,   y * 0.2,
						\ptrRandSamples, 0,
						\safeMargin,     0.0,
					], ~granGrp)
				};
			} {
				if (~liveMode) {
					~xyVoices[idx].set(
						\fixedPosSec,    posSec,
						\baseDur,        dur,
						\randDetune,     detune,
						\bitDepth,       distortion,
						\ptrRandSamples, y * 1.5 * s.sampleRate,
					);
				} {
					~xyVoices[idx].set(
						\fixedPosSec,  posSec,
						\baseDur,      dur,
						\randDetune,   detune,
						\bitDepth,     distortion,
						\fixedPosRand, y * 0.2,
					);
				};
			};
			~updateXYDensCap.();
		};
	};

	~releaseXYVoice = { |idx|
		~xyTimeouts[idx] !? { ~xyTimeouts[idx].stop; ~xyTimeouts[idx] = nil };
		if (~xyVoices[idx].notNil) {
			~xyVoices[idx].set(\gate, 0);
			~xyVoices[idx] = nil;
			~updateXYDensCap.();
		};
	};

	// ---- OSC control layer ----
	thisProcess.interpreter.executeFile(~basePath ++ "osc/oscconfig_multi.scd");
	thisProcess.interpreter.executeFile(~basePath ++ "osc/presets.scd");

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

	"Multi-synth patch booted (grain ON, tape OFF, cembalo OFF; grain input: guitar).".postln;
	s.meter;
};
)
