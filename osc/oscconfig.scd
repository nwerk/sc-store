// ============================================================
// OSC Configuration — TouchOSC ↔ SuperCollider (Granular Patch)
// ============================================================
// Requires: ~oscMap, ~busToOsc (from osc_mappings.scd)
//           ~ccBuses (from midiconfig.scd)
//           ~rec, ~g, ~ptr, b (synth instances from main_grain.scd)
//
// Loaded AFTER osc_mappings.scd and midiconfig.scd, but BEFORE
// synth instantiation in main_grain.scd.
// ============================================================

(
// ---- Network setup ----
// Change ~touchOSCip to your tablet's IP address.
// TouchOSC default receive port: 9000
// sclang default listen port: 57120 (NetAddr.langPort)
~touchOSCip   = "192.168.178.75";
~touchOSCport = 9000;
~touchOSC     = NetAddr(~touchOSCip, ~touchOSCport);

"TouchOSC target: % : %".format(~touchOSCip, ~touchOSCport).postln;
"SC listening on port: %".format(NetAddr.langPort).postln;

// ---- OSC debug logging ----
// Logs all incoming OSC messages received by this language process.
~setOscLogging = { |enabled=true|
	if (enabled) {
		if (~oscLogger.notNil) { ~oscLogger.free; };
		~oscLogger = OSCFunc({ |msg, time, addr, recvPort|
			("[OSC IN] addr:% from:%:% port:% msg:%"
				.format(msg[0], addr.ip, addr.port, recvPort, msg)
			).postln;
		}, nil);
		"OSC logging enabled (all incoming messages).".postln;
	} {
		if (~oscLogger.notNil) {
			~oscLogger.free;
			~oscLogger = nil;
		};
		"OSC logging disabled.".postln;
	};
};

~setOscLogging.(true);

// ---- Feedback helper ----
// Send a single float value back to TouchOSC on the given address.
~sendToTouchOSC = { |addr, value|
	~touchOSC.sendMsg(addr.asString, value.asFloat);
};

// ---- Send all fader + toggle state to TouchOSC (boot sync / preset load) ----
~sendAllState = {
	// Faders: read all bus values at once, then index per address
	var allVals = ~ccBuses.getnSynchronous(128);
	~oscMap.keysValuesDo { |addr, spec|
		if (spec[\type] == \fader) {
			~sendToTouchOSC.(addr, allVals.at(spec[\busIndex]));
		};
	};

	// Toggles
	~sendToTouchOSC.('/grain/record',   ~recState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/liveMode',  ~liveMode.asInteger.asFloat);
	~sendToTouchOSC.('/grain/reverse',   ~reverseState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fixedPos',  ~fixedPosState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fftFreeze', ~fftFreezeState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/xyMode',    ~xyMode.asInteger.asFloat);

	// Status
	~sendToTouchOSC.('/status/rate',      ~currentRate.asFloat);
	~sendToTouchOSC.('/status/bufferLen', ~bufferDurSec.asFloat);

	// Preset slot indicators
	~sendPresetSlots.();

	"State sent to TouchOSC.".postln;
};

// ---- Register all fader OSCdefs ----
// Each fader: receive float 0–1 → write to ccBuses → echo back
~oscMap.keysValuesDo { |addr, spec|
	if (spec[\type] == \fader) {
		OSCdef(addr.asSymbol, { |msg|
			var val = msg[1].clip(0.0, 1.0);
			~ccBuses.setAt(spec[\busIndex], val);
			// echo value back so TouchOSC stays in sync
			~sendToTouchOSC.(addr, val);
		}, addr.asString);
	};
};

// ---- Density fader: echo raw value + send scaled Hz to label ----
OSCdef('/grain/density', { |msg|
	var val, densScaled, densHz;
	val = msg[1].clip(0.0, 1.0);
	~ccBuses.setAt(~busNames[\density].index, val);
	~sendToTouchOSC.('/grain/density', val);
	// Apply the same squared taper used in the synth and convert to Hz
	densScaled = val.squared.linlin(0, 1, 0.001, 1);
	densHz = 1.0 / (densScaled * 0.8).max(0.005);
	~touchOSC.sendMsg('/grain/density-label', densHz.round(0.1).asString ++ " Hz");
}, "/grain/density");

// ---- Buffer length fader: directly reallocate buffer ----
// Overrides the generic fader handler so allocation happens immediately on fader move.
// Range: 0–1 → 0.1–8 seconds.
OSCdef('/grain/bufferLen', { |msg|
	var val = msg[1].clip(0.0, 1.0);
	var durSec = val.linlin(0.0, 1.0, 0.1, 8.0);
	~ccBuses.setAt(~busNames[\bufferLen].index, val);
	~sendToTouchOSC.('/grain/bufferLen', val);
	~allocBuffer !? { ~allocBuffer.(durSec) };
}, "/grain/bufferLen");

// ---- Toggle OSCdefs ----
// TouchOSC sends 1.0 on tap; SC flips internal state and sends new state back.

OSCdef('/grain/record', { |msg|
	if (msg[1] >= 1.0) {
		~recState = ~recState.not;
		~rec.set(\recGate, ~recState.asInteger);
		~sendToTouchOSC.('/grain/record', ~recState.asInteger.asFloat);
		("Record: " ++ if(~recState, "ON", "OFF")).postln;
	};
}, "/grain/record");

OSCdef('/grain/liveMode', { |msg|
	var isOn = msg[1] >= 0.5;
	if (isOn != ~liveMode) {
		if (isOn) {
			~startLiveMode.();
		} {
			~stopLiveMode.();
		};
	};
	~sendToTouchOSC.('/grain/liveMode', isOn.asInteger.asFloat);
}, "/grain/liveMode");

OSCdef('/grain/reverse', { |msg|
	if (msg[1] >= 1.0) {
		~reverseState = ~reverseState.not;
		~g.set(\reverseGrain, ~reverseState.asInteger);
		~sendToTouchOSC.('/grain/reverse', ~reverseState.asInteger.asFloat);
		("Reverse grain: " ++ if(~reverseState, "ON", "OFF")).postln;
	};
}, "/grain/reverse");

OSCdef('/grain/fixedPos', { |msg|
	if (msg[1] >= 1.0) {
		~fixedPosState = ~fixedPosState.not;
		~g.set(\fixedPos, ~fixedPosState.asInteger);
		~sendToTouchOSC.('/grain/fixedPos', ~fixedPosState.asInteger.asFloat);
		("Fixed position: " ++ if(~fixedPosState, "ON", "OFF")).postln;
	};
}, "/grain/fixedPos");

OSCdef('/grain/fftFreeze', { |msg|
	if (msg[1] >= 1.0) {
		~fftFreezeState = ~fftFreezeState.not;
		~ccBuses.setAt(~busNames[\fftFreeze].index, ~fftFreezeState.asInteger.asFloat);
		~sendToTouchOSC.('/grain/fftFreeze', ~fftFreezeState.asInteger.asFloat);
		("FFT Freeze: " ++ if(~fftFreezeState, "ON", "OFF")).postln;
	};
}, "/grain/fftFreeze");

OSCdef('/grain/xyMode', { |msg|
	if (msg[1] >= 1.0) {
		~xyMode = ~xyMode.not;
		if (~xyMode) {
			// Entering XY mode: silence the main granular synth
			~g !? { ~g.set(\amp, 0) };
		} {
			// Leaving XY mode: release all voices and restore main synth
			5.do { |i| ~releaseXYVoice.(i) };
			~g !? { ~g.set(\amp, 1.0) };
		};
		~sendToTouchOSC.('/grain/xyMode', ~xyMode.asInteger.asFloat);
		("XY Mode: " ++ if(~xyMode, "ON", "OFF")).postln;
	};
}, "/grain/xyMode");

// ---- Momentary OSCdefs ----

// ---- MultiXY: 5 independent touch voices ----
// TouchOSC MK2 MultiXY sends per touch slot N (1–5):
//   /grain/xy/N  x  y  z   — all bundled; z=1 finger down/moving, z=0 finger lifted.
// On lift (z=0): immediate release. On touch/move (z=1): spawn or update voice.
// No timeout — a stationary finger sends no messages but the voice holds until z=0.
// xyMode toggle calls ~releaseXYVoice on all slots as a cleanup safety net.
5.do { |i|
	var idx = i;
	var addr = "/grain/xy/" ++ (idx + 1);
	OSCdef(addr.asSymbol, { |msg|
		var x = msg[1].clip(0.0, 1.0);
		var y = msg[2].clip(0.0, 1.0);
		var z = if (msg.size >= 4) { msg[3] } { 1.0 };
		if (z <= 0) {
			~releaseXYVoice.(idx);
		} {
			~spawnXYVoice.(idx, x, y);
		};
	}, addr);
};

// ---- Master volume: override generic fader to drive synth arg directly ----
OSCdef('/master/volume', { |msg|
	~setMasterVol.(msg[1]);
}, "/master/volume");

OSCdef('/grain/octaveDown', { |msg|
	if (msg[1] >= 1.0) {
		~currentRate = ~currentRate * 0.5;
		~ccBuses.setAt(~busNames[\rate].index, ~currentRate.linlin(0.0625, 3.0625, 0, 1).clip(0, 1));
		~sendToTouchOSC.('/status/rate', ~currentRate.asFloat);
		("Octave down → rate: " ++ ~currentRate).postln;
	};
}, "/grain/octaveDown");

OSCdef('/grain/octaveUp', { |msg|
	if (msg[1] >= 1.0) {
		~currentRate = ~currentRate * 2.0;
		~ccBuses.setAt(~busNames[\rate].index, ~currentRate.linlin(0.0625, 3.0625, 0, 1).clip(0, 1));
		~sendToTouchOSC.('/status/rate', ~currentRate.asFloat);
		("Octave up → rate: " ++ ~currentRate).postln;
	};
}, "/grain/octaveUp");

OSCdef('/grain/pitchReset', { |msg|
	if (msg[1] >= 1.0) {
		var pitchNorm;
		~currentRate = 1.0;
		pitchNorm = 1.0.linlin(0.0625, 3.0625, 0, 1).clip(0, 1);
		~ccBuses.setAt(~busNames[\rate].index, pitchNorm);
		~touchOSC.sendMsg('/grain/pitch-label', pitchNorm.asString);
		~sendToTouchOSC.('/status/rate', 1.0);
		"Grain pitch reset to 1.0".postln;
	};
}, "/grain/pitchReset");

OSCdef('/grain/deleteBuffer', { |msg|
	if (msg[1] >= 1.0) {
		~deleteBuffer.();
	};
}, "/grain/deleteBuffer");

OSCdef('/grain/loadSample', { |msg|
	if (msg[1] >= 1.0) {
		{ ~loadBuffer.(nil); }.defer;
	};
}, "/grain/loadSample");

OSCdef('/grain/stopAudio', { |msg|
	if (msg[1] >= 1.0) {
		"Stopping all audio...".postln;
		~speedUpdater.stop;
		5.do { |i| ~releaseXYVoice.(i) };
		s.freeAll;
	};
}, "/grain/stopAudio");

// ---- Heartbeat ----
// Pulses /status/heartbeat: short ON then long OFF, repeating.
// Button is lit while SC is alive; goes dark if the process stops.
~heartbeatOnTime  = 0.3;   // seconds the button stays ON
~heartbeatPeriod  = 1.0;    // full period (ON + OFF) in seconds

~stopHeartbeat = {
	if (~heartbeatRoutine.notNil) {
		~heartbeatRoutine.stop;
		~heartbeatRoutine = nil;
	};
	~sendToTouchOSC.('/status/heartbeat', 0.0);
};

~startHeartbeat = {
	~stopHeartbeat.();
	~heartbeatRoutine = Routine({
		loop {
			~sendToTouchOSC.('/status/heartbeat', 1.0);
			~heartbeatOnTime.wait;
			~sendToTouchOSC.('/status/heartbeat', 0.0);
			(~heartbeatPeriod - ~heartbeatOnTime).wait;
		};
	}).play(AppClock);
	"Heartbeat started (period: %s, on-time: %s).".format(~heartbeatPeriod, ~heartbeatOnTime).postln;
};

~startHeartbeat.();

"OSC responders registered.".postln;
)
