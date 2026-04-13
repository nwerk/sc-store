(
Server.killAll;
//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/granular_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/granular.scd");

s.waitForBoot{
	// ---- Buffer setup ----
	~bufferDurSec = 4.0; // default buffer length in seconds (PD default: 4000 ms)
    b = Buffer.alloc(s, s.sampleRate * ~bufferDurSec, 1);

	// ---- Audio buses ----
	~micBus = Bus.audio(s, 1);
    ~ptrBus = Bus.audio(s, 1);
	s.sync;

	// ---- Synth groups (ordered for signal flow) ----
    ~micGrp = Group.new;
    ~ptrGrp = Group.after(~micGrp);
    ~recGrp = Group.after(~ptrGrp);
    ~granGrp = Group.after(~recGrp);
	s.sync;

	// ---- Synth instances ----
    ~mic = Synth(\mic, [\in, 0, \out, ~micBus], ~micGrp);
    ~ptr = Synth(\ptr, [\out, ~ptrBus, \buf, b, \speed, 1], ~ptrGrp);
    ~rec = Synth(\rec, [
		\ptrIn, ~ptrBus,
		\micIn, ~micBus,
		\buf, b,
		\fb, 0,
		\recGate, 0,
		\xfadeTime, 0.05
	], ~recGrp);

    ~g = Synth(\gran, [
		\ccBus, ~ccBuses,
        \amp, 0.5,
		\buf, b,
		\out, 0,
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

	// ---- State variables for toggles ----
	~recState = false;
	~liveMode = false;
	~liveRoutine = nil;
	~reverseState = false;
	~fixedPosState = false;
	~muteState = false;
	~prevAmp = 0.5;
	~currentRate = 1.0;

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
		durSec = durSec ? ~bufferDurSec;
		~bufferDurSec = durSec;
		b.free;
		b = Buffer.alloc(s, s.sampleRate * durSec, 1, completionMessage: { |buf|
			("Buffer allocated: " ++ durSec ++ "s (" ++ buf.numFrames ++ " frames)").postln;
			~ptr.set(\buf, buf);
			~rec.set(\buf, buf);
			~g.set(\buf, buf);
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

	// ---- CC 46: Feedback → update \rec fb in real time ----
	~fbUpdater = Routine({
		inf.do {
			~ccBuses.getn(46, 1, { |val|
				~rec.set(\fb, val[0]);
			});
			0.05.wait;
		};
	}).play(AppClock);

	// ---- CC 16: Buffer Length → reallocate buffer ----
	~bufLenUpdater = Routine({
		var lastLen = ~bufferDurSec;
		inf.do {
			~ccBuses.getn(16, 1, { |val|
				var newLen = (val[0] * 8).max(0.01); // 0–8 seconds
				if ((newLen - lastLen).abs > 0.1) { // only reallocate on significant change
					lastLen = newLen;
					~allocBuffer.(newLen);
				};
			});
			0.2.wait; // 200ms — don't reallocate too often
		};
	}).play(AppClock);

	// ---- MIDI Note handlers (PD note triggers) ----

	// Note 1: Record trigger (toggle)
	MIDIdef.noteOn(\recTrigger, { |vel, note|
		~recState = ~recState.not;
		~rec.set(\recGate, ~recState.asInteger);
		("Record: " ++ if(~recState, "ON", "OFF")).postln;
	}, 1);

	// Note 4: Delete buffer
	MIDIdef.noteOn(\deleteBuffer, { |vel, note|
		~deleteBuffer.();
	}, 4);

	// Note 5: Live mode toggle
	MIDIdef.noteOn(\liveToggle, { |vel, note|
		if (~liveMode) {
			~stopLiveMode.();
		} {
			~startLiveMode.();
		};
	}, 5);

	// Note 9: Reverse grain toggle
	MIDIdef.noteOn(\reverseGrain, { |vel, note|
		~reverseState = ~reverseState.not;
		~g.set(\reverseGrain, ~reverseState.asInteger);
		("Reverse grain: " ++ if(~reverseState, "ON", "OFF")).postln;
	}, 9);

	// Note 10: Grain pitch reset → rate = 1.0
	MIDIdef.noteOn(\pitchReset, { |vel, note|
		~currentRate = 1.0;
		~g.set(\rate, 1.0);
		"Grain pitch reset to 1.0".postln;
	}, 10);

	// Note 12: Fixed position toggle
	MIDIdef.noteOn(\fixedPosToggle, { |vel, note|
		~fixedPosState = ~fixedPosState.not;
		~g.set(\fixedPos, ~fixedPosState.asInteger);
		("Fixed position: " ++ if(~fixedPosState, "ON", "OFF")).postln;
	}, 12);

	// Note 13: Octave down (rate × 0.5)
	MIDIdef.noteOn(\octaveDown, { |vel, note|
		~currentRate = ~currentRate * 0.5;
		~g.set(\rate, ~currentRate);
		("Octave down → rate: " ++ ~currentRate).postln;
	}, 13);

	// Note 15: Mute toggle
	MIDIdef.noteOn(\muteToggle, { |vel, note|
		~muteState = ~muteState.not;
		if (~muteState) {
			~g.set(\amp, 0);
			"MUTED".postln;
		} {
			~g.set(\amp, ~prevAmp);
			"UNMUTED".postln;
		};
	}, 15);

	// Note 16: Octave up (rate × 2)
	MIDIdef.noteOn(\octaveUp, { |vel, note|
		~currentRate = ~currentRate * 2.0;
		~g.set(\rate, ~currentRate);
		("Octave up → rate: " ++ ~currentRate).postln;
	}, 16);

	// Note 22: Load sample (file dialog)
	MIDIdef.noteOn(\loadSample, { |vel, note|
		{ ~loadBuffer.(nil); }.defer; // Dialog must run on AppClock
	}, 22);

	// Note 25: Stop audio
	MIDIdef.noteOn(\stopAudio, { |vel, note|
		"Stopping all audio...".postln;
		~speedUpdater.stop;
		~fbUpdater.stop;
		~bufLenUpdater.stop;
		s.freeAll;
	}, 25);

	"Synth \\gran created with PD-ported features!".postln;
	s.meter;
};
)

