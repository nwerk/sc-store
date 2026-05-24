// ============================================================
// OSC Configuration — TouchOSC ↔ SuperCollider (Multi-Synth Patch)
// ============================================================
// Requires: ~oscMap, ~busToOsc        (osc_mappings_multi.scd)
//           ~ccBuses, ~busNames       (midiconfig_multi.scd)
//           ~rec, ~g, ~ptr, b        (main_multi.scd)
//           ~grainMaster, ~tapeMaster (main_multi.scd)
//           ~synthEnabled, ~focusedSynth (main_multi.scd)
//
// Loaded INSIDE s.waitForBoot in main_multi.scd, after synth
// instantiation so all synth handles are available.
// ============================================================

(
// ---- Network setup ----
Platform.case(
	\linux, {
		~touchOSCip = "172.24.1.107";  // ← TouchOSC device's IP
	},
	\windows, {
		~touchOSCip = "192.168.178.75";  // ← TouchOSC device's IP
	},
	{
		"Unknown OS - no TouchOSC device's IP is set".warn;
	}
);
~touchOSCport = 9000;
~touchOSC     = NetAddr(~touchOSCip, ~touchOSCport);

"TouchOSC target: % : %".format(~touchOSCip, ~touchOSCport).postln;
"SC listening on port: %".format(NetAddr.langPort).postln;

// ---- OSC debug logging ----
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
~sendToTouchOSC = { |addr, value|
	~touchOSC.sendMsg(addr.asString, value.asFloat);
};

// ---- Synth focus feedback ----
// Sends /synth/grain/focused and /synth/tape/focused back to TouchOSC.
~sendFocusFeedback = {
	~sendToTouchOSC.('/synth/grain/focused', (~focusedSynth == \grain).asInteger.asFloat);
	~sendToTouchOSC.('/synth/tape/focused',  (~focusedSynth == \tape).asInteger.asFloat);
};

// ---- Send all fader + toggle state to TouchOSC (boot sync / preset load) ----
~sendAllState = {
	var allVals = ~ccBuses.getnSynchronous(128);
	// Faders: all entries in ~oscMap with a busIndex
	~oscMap.keysValuesDo { |addr, spec|
		if (spec[\type] == \fader) {
			~sendToTouchOSC.(addr, allVals.at(spec[\busIndex]));
		};
	};

	// Grain toggles
	~sendToTouchOSC.('/grain/record',      ~recState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/liveMode',    ~liveMode.asInteger.asFloat);
	~sendToTouchOSC.('/grain/reverse',     ~reverseState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fixedPos',    ~fixedPosState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fftFreeze',   ~fftFreezeState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/xyMode',      ~xyMode.asInteger.asFloat);
	~sendToTouchOSC.('/grain/densFromDur', ~densFromDurState.asInteger.asFloat);

	// Status
	~sendToTouchOSC.('/status/rate',      ~currentRate.asFloat);
	~sendToTouchOSC.('/status/bufferLen', ~bufferDurSec.asFloat);

	// Synth enable/focus state
	~sendToTouchOSC.('/synth/grain/enable', ~synthEnabled[\grain].asInteger.asFloat);
	~sendToTouchOSC.('/synth/tape/enable',  ~synthEnabled[\tape].asInteger.asFloat);
	~sendFocusFeedback.();

	// Preset slot indicators
	~sendPresetSlots.();

	"State sent to TouchOSC.".postln;
};

// ---- Register all fader OSCdefs (generic loop) ----
// Handles all \fader entries in ~oscMap including all /tape/* faders.
~oscMap.keysValuesDo { |addr, spec|
	if (spec[\type] == \fader) {
		OSCdef(addr.asSymbol, { |msg|
			var val = msg[1].clip(0.0, 1.0);
			~ccBuses.setAt(spec[\busIndex], val);
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
	densScaled = val.squared.linlin(0, 1, 0.001, 1);
	densHz = 1.0 / (densScaled * 0.8).max(0.005);
	~touchOSC.sendMsg('/grain/density-label', densHz.round(0.1).asString ++ " Hz");
}, "/grain/density");

// ---- Time stretch fader: echo raw value + send scaled multiplier to label ----
OSCdef('/grain/timeStretch', { |msg|
	var val, tsScaled;
	val = msg[1].clip(0.0, 1.0);
	~ccBuses.setAt(~busNames[\timeStretch].index, val);
	~sendToTouchOSC.('/grain/timeStretch', val);
	tsScaled = if (val >= 0.5) {
		val.linlin(0.5, 1.0, 1.0, 4.0)
	} {
		val.linlin(0.0, 0.5, 0.25, 1.0)
	};
	~touchOSC.sendMsg('/grain/timeStretch-label', tsScaled.round(0.01).asString ++ "×");
}, "/grain/timeStretch");

// ---- Buffer length fader: directly reallocate buffer ----
OSCdef('/grain/bufferLen', { |msg|
	var val = msg[1].clip(0.0, 1.0);
	var durSec = val.linlin(0.0, 1.0, 0.1, 8.0);
	~ccBuses.setAt(~busNames[\bufferLen].index, val);
	~sendToTouchOSC.('/grain/bufferLen', val);
	~allocBuffer !? { ~allocBuffer.(durSec) };
}, "/grain/bufferLen");

// ---- Grain toggle OSCdefs ----

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
		if (isOn) { ~startLiveMode.() } { ~stopLiveMode.() };
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

OSCdef('/grain/densFromDur', { |msg|
	if (msg[1] >= 1.0) {
		~densFromDurState = ~densFromDurState.not;
		~g.set(\densFromDurMode, ~densFromDurState.asInteger);
		~sendToTouchOSC.('/grain/densFromDur', ~densFromDurState.asInteger.asFloat);
		("Density from Duration: " ++ if(~densFromDurState, "ON", "OFF")).postln;
	};
}, "/grain/densFromDur");

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
			~g !? { ~g.run(false) };
		} {
			5.do { |i| ~releaseXYVoice.(i) };
			~g !? { ~g.run(true) };
		};
		~sendToTouchOSC.('/grain/xyMode', ~xyMode.asInteger.asFloat);
		("XY Mode: " ++ if(~xyMode, "ON", "OFF")).postln;
	};
}, "/grain/xyMode");

// ---- Momentary OSCdefs ----

// ---- MultiXY: 5 independent touch voices ----
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
	if (msg[1] >= 1.0) { ~deleteBuffer.() };
}, "/grain/deleteBuffer");

OSCdef('/grain/loadSample', { |msg|
	if (msg[1] >= 1.0) { { ~loadBuffer.(nil); }.defer };
}, "/grain/loadSample");

OSCdef('/grain/stopAudio', { |msg|
	if (msg[1] >= 1.0) {
		"Stopping all audio...".postln;
		~speedUpdater.stop;
		5.do { |i| ~releaseXYVoice.(i) };
		s.freeAll;
	};
}, "/grain/stopAudio");

// ---- Synth enable/disable ----

OSCdef('/synth/grain/enable', { |msg|
	var on = msg[1] >= 0.5;
	~synthEnabled[\grain] = on;
	if (on) {
		// Resume grain chain
		~g !? { ~g.run(true) };
		~fftFx !? { ~fftFx.run(true) };
		~grainMaster !? { ~grainMaster.run(true) };
		~focusedSynth = \grain;
		~sendFocusFeedback.();
	} {
		// Release XY voices, then pause grain chain
		5.do { |i| ~releaseXYVoice !? { ~releaseXYVoice.(i) } };
		~g !? { ~g.run(false) };
		~fftFx !? { ~fftFx.run(false) };
		~grainMaster !? { ~grainMaster.run(false) };
		// ~mic / ~ptr / ~rec kept running so the buffer stays current
	};
	~sendToTouchOSC.('/synth/grain/enable', on.asInteger.asFloat);
	("Grain: " ++ if(on, "ENABLED", "DISABLED")).postln;
}, "/synth/grain/enable");

OSCdef('/synth/tape/enable', { |msg|
	var on = msg[1] >= 0.5;
	~synthEnabled[\tape] = on;
	if (on) {
		// Resume tape chain, then fade amp in
		~tartini !? { ~tartini.run(true) };
		~ape !? { ~ape.run(true) };
		~tapeMaster !? { ~tapeMaster.run(true); ~tapeMaster.set(\amp, 1.0) };
		~focusedSynth = \tape;
		~sendFocusFeedback.();
	} {
		// Fade out first (100 ms lag on \tapeOutput), then pause
		~tapeMaster !? { ~tapeMaster.set(\amp, 0.0) };
		AppClock.sched(0.2, {
			~ape !? { ~ape.run(false) };
			~tartini !? { ~tartini.run(false) };
			~tapeMaster !? { ~tapeMaster.run(false) };
			nil;
		});
	};
	~sendToTouchOSC.('/synth/tape/enable', on.asInteger.asFloat);
	("Tape: " ++ if(on, "ENABLED", "DISABLED")).postln;
}, "/synth/tape/enable");

// ---- Synth focus (MIDI expression pedal routing) ----
OSCdef('/synth/focus', { |msg|
	var name = msg[1].asSymbol;
	if (#[\grain, \tape].includes(name)) {
		~focusedSynth = name;
		~sendFocusFeedback.();
		("Focused synth: " ++ name).postln;
	};
}, "/synth/focus");

// ---- Heartbeat ----
~heartbeatOnTime = 0.3;
~heartbeatPeriod = 1.0;

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

"OSC responders (multi) registered.".postln;
)
