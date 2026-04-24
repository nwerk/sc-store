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
    ~ptr = Synth(\ptr, [\out, ~ptrBus, \buf, b, \speed, 1], ~ptrGrp);
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
		\playGroups, 1,
		\fixedPos, 0,
		\fixedPosSec, 0,
		\randDetune, 0,
		\randomOctave, 1,
		\octaveGroups, 1,
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

	// ---- MultiXY voice state (5 touch slots) ----
	~xyVoices   = Array.newClear(5);
	~xyTimeouts = Array.newClear(5);
	~xyActive   = 0;

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
			~sendToTouchOSC !? { ~sendToTouchOSC.('/status/bufferLen', durSec.asFloat) };
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
	// X (0–1) → sample position in buffer; Y (0–1) → grain duration (5ms–500ms)
	// Each of the 5 touch slots spawns/updates an independent \gran synth.
	// A 200ms inactivity timeout triggers a 150ms release fade when the finger lifts.
	~spawnXYVoice = { |idx, x, y|
		var posSec = x * ~bufferDurSec;
		var durSec = y.clip(0.001, 1).linexp(0.001, 1, 0.005, 0.5);
		if (~xyVoices[idx].isNil) {
			~xyVoices[idx] = Synth(\gran, [
				\ccBus,       ~ccBuses,
				\amp,         1.0,
				\buf,         b,
				\out,         ~fftInBus,
				\atk,         0.01,
				\rel,         0.15,
				\gate,        1,
				\sync,        1,
				\fixedPos,    1,
				\fixedPosSec, posSec,
				\baseDur,     durSec,
				\ptrBus,      ~ptrBus,
				\minPtrDelay, 1000,
				\safeMargin,  0.02,
			], ~granGrp);
			~xyActive = ~xyActive + 1;
			if (~xyActive == 1) { ~g !? { ~g.set(\amp, 0) } };
		} {
			~xyVoices[idx].set(\fixedPosSec, posSec, \baseDur, durSec);
		};
	};

	~releaseXYVoice = { |idx|
		~xyTimeouts[idx] !? { ~xyTimeouts[idx].stop; ~xyTimeouts[idx] = nil };
		if (~xyVoices[idx].notNil) {
			~xyVoices[idx].set(\gate, 0);
			~xyVoices[idx] = nil;
			~xyActive = (~xyActive - 1).max(0);
			if (~xyActive == 0) { ~g !? { ~g.set(\amp, 1.0) } };
		};
	};

	// ---- CC 55: Playback Speed → update \ptr speed in real time ----
	// (Read CC 55 and route to \ptr synth since ptr doesn't read ccBus itself)
	~speedUpdater = Routine({
		inf.do {
			~ccBuses.getn(55, 1, { |val|
				var speed = val[0].linlin(0, 1, 0.0625, 3.0625);
				~ptr.set(\speed, speed);
			});
			0.05.wait; // 50ms update rate
		};
	}).play(AppClock);

	// ---- CC 16: Buffer Length → handled via OSCdef in oscconfig.scd ----
	// (direct ~allocBuffer call on fader move; no polling routine needed)

	// ---- OSC control layer (TouchOSC faders, toggles, momentaries, presets) ----
	thisProcess.interpreter.executeFile(~basePath ++ "osc/oscconfig.scd");
	thisProcess.interpreter.executeFile(~basePath ++ "osc/presets.scd");

	// ---- Send full state to TouchOSC on boot ----
	// (short delay so synths are fully ready)
	AppClock.sched(0.5, {
		// Load preset 0 on startup if it exists, otherwise just sync state
		if (~presetExists.(0)) {
			~loadPreset.(0);
		} {
			~sendAllState.();
		};
		nil; // don't reschedule
	});

	"Synth \\gran created with TouchOSC + OSC control!".postln;
	s.meter;
};
)
