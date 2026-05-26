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
thisProcess.interpreter.executeFile(~basePath ++ "synths/fft_freeze.scd");
// tapeemulate.scd uses ~busNames[\badness] etc. — now baked as 90–96
thisProcess.interpreter.executeFile(~basePath ++ "synths/tapeemulate.scd");
// inputtracker.scd: \tartiniTracker_sigmundStyle (no ~busNames refs)
thisProcess.interpreter.executeFile(~basePath ++ "classes/inputtracker.scd");
// master.scd: \master SynthDef uses ~busNames[\masterVol].index = 11 (grain master)
thisProcess.interpreter.executeFile(~basePath ++ "classes/master.scd");

// ---- Tape output stage SynthDef (inline — cannot use \master, which hardcodes CC 11) ----
// \ape already applies its own master_vol from CC 96 internally.
// \tapeOutput is purely a mute/enable gate controlled via ~tapeMaster.set(\amp, ...).
SynthDef(\tapeOutput, { |out=0, inBus=0, amp=0.0|
	var sig = In.ar(inBus, 2);
	sig = sig * amp.lag(0.1);
	Out.ar(out, sig);
}).add;

s.waitForBoot {
	// ---- System state ----
	~synthEnabled = ( grain: true, tape: false );
	~focusedSynth = \grain;

	// ---- Audio buses ----
	~micBus      = Bus.audio(s, 1);   // mono microphone input
	~ptrBus      = Bus.audio(s, 1);   // record pointer
	~fftInBus    = Bus.audio(s, 2);   // grain → FFT stage input
	~grainOutBus = Bus.audio(s, 2);   // FFT stage output → grain master
	~tapeOutBus  = Bus.audio(s, 2);   // \ape output → tape output stage
	~freqBus     = Bus.control(s, 1); // Tartini pitch output
	~ampBus      = Bus.control(s, 1); // Tartini amplitude output
	s.sync;

	// ---- Groups (ordered for signal flow) ----
	~micGrp     = Group.new;
	~ptrGrp     = Group.after(~micGrp);
	~recGrp     = Group.after(~ptrGrp);
	~tartiniGrp = Group.after(~recGrp);
	~granGrp    = Group.after(~tartiniGrp);
	~fftGrp     = Group.after(~granGrp);
	~tapeGrp    = Group.after(~fftGrp);
	~masterGrp  = Group.after(~tapeGrp);
	s.sync;

	// ---- Buffer setup ----
	~bufferDurSec = 4.0;
	b = Buffer.alloc(s, s.sampleRate * ~bufferDurSec, 1);
	s.sync; // wait for buffer allocation before any UGen accesses it

	// ---- Granular chain ----
	~mic = Synth(\mic, [\in, 0, \out, ~micBus], ~micGrp);
	~ptr = Synth(\ptr, [\out, ~ptrBus, \buf, b], ~ptrGrp);
	~rec = Synth(\rec, [
		\ccBus,     ~ccBuses,
		\ptrIn,     ~ptrBus,
		\micIn,     ~micBus,
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

	~fftFx = Synth(\fftFreeze, [
		\micIn,       ~micBus,
		\granIn,      ~fftInBus,
		\ccBus,       ~ccBuses,
		\out,         ~grainOutBus,
		\freeze,      0,
		\fftFilterAmt,0,
		\morphAmt,    0,
	], ~fftGrp);

	// ---- Tartini pitch tracker (shared; used by \ape) ----
	~tartini = Synth(\tartiniTracker_sigmundStyle,
		[\inChan, 0, \freqBus, ~freqBus, \ampBus, ~ampBus], ~tartiniGrp);

	// ---- Tape chain ----
	// \ape reads badness/wavemix/etc. from CC slots 90–96 (baked in at compile time).
	~ape = Synth(\ape, [
		\ccBus,       ~ccBuses,
		\input_pitch, ~freqBus.index,
		\vol,         ~ampBus.index,
		\out,         ~tapeOutBus,
	], ~tapeGrp);

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
	~xyMode           = false;
	~densFromDurState = false;
	~pitchTrackMode   = false;
	~ptRateScale      = 0.0;
	~ptFixedPosSec    = 0.0;
	~samplePath       = nil;

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
			~sendToTouchOSC !? { ~sendToTouchOSC.('/grain/bufferLen', durSec.asFloat) };
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
			if (~presetExists.(0)) { ~loadPreset.(0) } { ~sendAllState.() };
		};
		nil;
	});
	AppClock.sched(3.0, {
		if (s.serverRunning) {
			if (~presetExists.(0)) { ~loadPreset.(0) } { ~sendAllState.() };
		};
		nil;
	});

	"Multi-synth patch booted (grain ON, tape OFF).".postln;
	s.meter;
};
)
