(
Server.killAll;
//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
// OSC mappings define ~busNames (same CC indices) + ~oscMap
thisProcess.interpreter.executeFile(~basePath ++ "osc/osc_mappings.scd");
// MIDI kept for Boss FS-1-WL foot controller
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/granular.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/fft_freeze.scd");
thisProcess.interpreter.executeFile(~basePath ++ "classes/master.scd");

s.waitForBoot{
	// ---- Buffer setup ----
	~bufferDurSec = 4.0; // default buffer length in seconds (PD default: 4000 ms)
    b = Buffer.alloc(s, s.sampleRate * ~bufferDurSec, 1);

	// ---- Audio buses ----
	~micBus = Bus.audio(s, 1);
    ~ptrBus = Bus.audio(s, 1);
	~fftInBus = Bus.audio(s, 2);
	~masterInBus = Bus.audio(s, 2);
	s.sync;

	// ---- Synth groups (ordered for signal flow) ----
    ~micGrp = Group.new;
    ~ptrGrp = Group.after(~micGrp);
    ~recGrp = Group.after(~ptrGrp);
    ~granGrp = Group.after(~recGrp);
	~fftGrp = Group.after(~granGrp);
	~masterGrp = Group.after(~fftGrp);
	s.sync;

	// ---- Synth instances ----
    ~mic = Synth(\mic, [\in, 0, \out, ~micBus], ~micGrp);
    ~ptr = Synth(\ptr, [\out, ~ptrBus, \buf, b], ~ptrGrp);
    ~rec = Synth(\rec, [
		\ccBus, ~ccBuses,
		\ptrIn, ~ptrBus,
		\micIn, ~micBus,
		\buf, b,
		\recGate, 0,
		\xfadeTime, 0.05
	], ~recGrp);

    ~g = Synth(\gran, [
		\ccBus, ~ccBuses,
        \amp, 1.0,  // master synth handles overall volume via CC 62
		\buf, b,
		\out, ~fftInBus,
		\atk, 0,
		\rel, 1,
		\gate, 1,
		\sync, 1,
		\dens, 40,
		\baseDur, 0.1,
		\durRand, 1,
		\rate, 1.0,
		\rateRand, 1.0,
		\panRand, 0,
		\grainEnv, -1,
		\ptrBus, ~ptrBus,
		\ptrSampleDelay, 20000,
		\ptrRandSamples, 5000,
 		\minPtrDelay, 1000,
		\safeMargin, 0.02,
	    \filterFreq, 15000,
		// PD-ported params (defaults match PD loadbang values)
		\reverseGrain, 0,
		\bitDepth, 1,
		\bitVol, 1,
		\freqModAmt, 0,
		\freqModFreq, 0,
		\fixedPos, 0,
		\fixedPosSec, 0,
		\randDetune, 0,
		\randomOctave, 1,
		\octaveGroups, 1,
		\densFromDurMode, 0,
		\timeStretch, 1.0,
	], ~granGrp);

	~fftFx = Synth(\fftFreeze, [
		\micIn, ~micBus,
		\granIn, ~fftInBus,
		\ccBus, ~ccBuses,
		\out, ~masterInBus,
		\freeze, 0,
		\fftFilterAmt, 0,
		\morphAmt, 0,
	], ~fftGrp);

	~master = Synth(\master, [
		\inBus, ~masterInBus,
		\ccBus, ~ccBuses,
		\out, 0,
	], ~masterGrp);

	// ---- Master volume helper ----
	// Single point of control: sets synth arg + CC bus + sends to TouchOSC.
	~setMasterVol = { |val|
		val = val.clip(0.0, 1.0);
		~ccBuses.setAt(~busNames[\masterVol].index, val);
		~touchOSC !? { ~touchOSC.sendMsg('/master/volume', val.asFloat) };
	};

	~setMasterVol.(1.0);

	// ---- State variables for toggles ----
	~recState = false;
	~liveMode = false;
	~liveRoutine = nil;
	~reverseState = false;
	~fixedPosState = false;
	~fftFreezeState = false;
	~currentRate = 1.0;
	~xyMode = false;
	~densFromDurState = false;

	// ---- MultiXY voice state (5 touch slots) ----
	~xyVoices      = Array.newClear(5);
	~xyTimeouts    = Array.newClear(5);
	~xyMaxGrainsHz = 80; // total grain budget (Hz) shared across all active XY voices — tune as needed

	// Divide ~xyMaxGrainsHz equally among active voices and push the cap to each running synth.
	// Called after every spawn or release so all voices stay within budget.
	~updateXYDensCap = {
		var count = ~xyVoices.select(_.notNil).size.max(1);
		var capHz = ~xyMaxGrainsHz / count;
		~xyVoices.do { |v| v !? { v.set(\maxDensHz, capHz) } };
	};

	// ---- Buffer management functions ----

	// Load a sample file (opens dialog if no path given)
	~loadBuffer = { |path|
		if (path.notNil) {
			b.free;
			b = Buffer.readChannel(s, path, channels: [0], action: { |buf|
				("Buffer loaded: " ++ path ++ " (" ++ buf.numFrames ++ " frames)").postln;
				// update synths with new buffer
				~ptr.set(\buf, buf);
				~rec.set(\buf, buf);
				~g.set(\buf, buf);
			});
		} {
			Dialog.openPanel({ |path|
				~loadBuffer.(path);
			});
		};
	};

	// Delete buffer contents (PD: "; Buffer const 0")
	~deleteBuffer = {
		b.zero;
		"Buffer cleared.".postln;
	};

	// Allocate a new buffer with given duration in seconds
	~allocBuffer = { |durSec|
		var wasRecording = ~recState, wasLiveMode = ~liveMode;
		durSec = durSec ? ~bufferDurSec;
		~bufferDurSec = durSec;
		// Stop recording while swapping the buffer to prevent writes to freed memory
		~rec.set(\recGate, 0);
		b.free;
		b = Buffer.alloc(s, s.sampleRate * durSec, 1, completionMessage: { |buf|
			~ptr.set(\buf, buf);
			~rec.set(\buf, buf);
			~g.set(\buf, buf);
			// Restore recording/live-mode state if either was active before
			if (wasRecording || wasLiveMode) { ~rec.set(\recGate, 1) };
			("Buffer allocated: " ++ durSec ++ "s (" ++ buf.numFrames ++ " frames)").postln;
			~sendToTouchOSC !? { ~sendToTouchOSC.('/grain/bufferLen', durSec.asFloat) };
		});
	};

	// ---- Live mode (PD: continuous auto-retrigger recording) ----
	~startLiveMode = {
		~liveMode = true;
		~rec.set(\recGate, 1);
		("Live mode ON").postln;
	};

	~stopLiveMode = {
		~liveMode = false;
		~rec.set(\recGate, 0);
		("Live mode OFF").postln;
	};

	// ---- MultiXY voice management ----
	// X (0–1) → buffer position (seconds). Y (0–1) → duration / detune / jitter / distortion.
	// LiveMode ON:  fixedPos=0, xyMode=1 — X injected into candidateCenter, safety mechanism runs.
	// LiveMode OFF: fixedPos=1, xyMode=1 — exact position, safety bypassed; scatter via fixedPosRand.
	// Each of the 5 touch slots spawns/updates an independent \gran synth.
	// A 200ms inactivity timeout triggers a 150ms release fade when the finger lifts.
	// ~g is muted while any XY voice is active and restored when all fingers are lifted.
	~spawnXYVoice = { |idx, x, y|
		var posSec      = x * ~bufferDurSec;
		var dur         = y.linlin(0, 1, 0.01, 1.5);
		var detune      = y.linlin(0, 1, 0, 30);
		var distortion  = y.linlin(0, 1, 1.05, 0.7);
		// Cap for the new voice: budget ÷ (current count + 1 for the incoming voice)
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
					// LiveMode ON: X injected into candidateCenter; safety snaps if near write head
					Synth(\gran, commonArgs ++ [
						\fixedPos,       0,
						\fixedPosRand,   0,
						\ptrRandSamples, y * 1.5 * s.sampleRate,
						\safeMargin,     0.02,
					], ~granGrp)
				} {
					// LiveMode OFF: buffer static, exact position; scatter via fixedPosRand
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
			~updateXYDensCap.(); // push new lower cap to all existing voices
		};
	};

	~releaseXYVoice = { |idx|
		~xyTimeouts[idx] !? { ~xyTimeouts[idx].stop; ~xyTimeouts[idx] = nil };
		if (~xyVoices[idx].notNil) {
			~xyVoices[idx].set(\gate, 0);
			~xyVoices[idx] = nil;
			~updateXYDensCap.(); // raise cap for remaining voices
		};
	};

	// ---- CC 16: Buffer Length → handled via OSCdef in oscconfig.scd ----
	// (direct ~allocBuffer call on fader move; no polling routine needed)

	// ---- OSC control layer (TouchOSC faders, toggles, momentaries, presets) ----
	thisProcess.interpreter.executeFile(~basePath ++ "osc/oscconfig.scd");
	thisProcess.interpreter.executeFile(~basePath ++ "osc/presets.scd");

	// ---- Send full state to TouchOSC on boot ----
	// First pass at 0.5s (synths ready); second pass at 3.0s in case TouchOSC
	// wasn't fully connected yet and missed the first burst of OSC messages.
	AppClock.sched(0.5, {
		if (~presetExists.(0)) {
			~loadPreset.(0);
		} {
			~sendAllState.();
		};
		nil;
	});
	AppClock.sched(3.0, {
		if (~presetExists.(0)) {
			~loadPreset.(0);
		} {
			~sendAllState.();
		};
		nil;
	});

	"Synth \\gran created with TouchOSC + OSC control!".postln;
	s.meter;
};
)
