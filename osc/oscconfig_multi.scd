// ============================================================
// OSC Configuration — TouchOSC ↔ SuperCollider (Multi-Synth Patch)
// ============================================================
// Requires: ~oscMap, ~busToOsc        (osc_mappings_multi.scd)
//           ~ccBuses, ~busNames       (midiconfig_multi.scd)
//           ~rec, ~g, ~ptr, b        (main_multi.scd)
//           ~grainMaster, ~tapeMaster, ~cembaloMaster (main_multi.scd)
//           ~synthEnabled, ~grainSrc, ~focusedSynth, ~updateChains,
//           ~setCembaloParam, ~cembaloSpecs (main_multi.scd)
//
// Loaded INSIDE s.waitForBoot in main_multi.scd, after synth
// instantiation so all synth handles are available.
// ============================================================

(
// ---- Network setup ----
// The tablet's address per machine (Pi hotspot / laptop at home) is set in run-sc-main_multi.sh, which passes it
// as TOUCHOSC_IP. The defaults below only apply when main_multi.scd is started without the launcher
// (Linux = the Pi's hotspot, Windows = a test setup), or override it by hand:
//   TOUCHOSC_IP=192.168.0.50 sclang main_multi.scd
// The tablet has to send to this machine too: TouchOSC's OSC target = this machine's IP, port NetAddr.langPort (57120).
~touchOSCip = "TOUCHOSC_IP".getenv;
if(~touchOSCip.isNil or: { ~touchOSCip.isEmpty }) {
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
} {
	"TouchOSC address taken from $TOUCHOSC_IP".postln;
};
~touchOSCport = 9000;
~touchOSC     = NetAddr(~touchOSCip, ~touchOSCport);

"TouchOSC target: % : %".format(~touchOSCip, ~touchOSCport).postln;
"SC listening on port: %".format(NetAddr.langPort).postln;

// ---- OSC debug logging ----
// Off by default (the tablet's faders send many messages per second). Switch on with
//   OSC_LOG=1 sclang main_multi.scd      or at runtime:  ~setOscLogging.(true)  /  ~setOscLogging.(false)
// Hooks into the language's receive path: an OSCFunc with a nil path matches nothing, so it cannot be used
// as a catch-all. Replies from scsynth and the pitch tracker's own messages are left out.
~setOscLogging = { |enabled=true|
	if (~oscLogger.notNil) {
		thisProcess.removeOSCRecvFunc(~oscLogger);
		~oscLogger = nil;
	};
	if (enabled) {
		~oscLogger = { |msg, time, addr, recvPort|
			if ((addr.port != s.addr.port) and: { msg[0].asString.beginsWith("/polytracker/").not }) {
				("[OSC IN] addr:% from:%:% port:% msg:%"
					.format(msg[0], addr.ip, addr.port, recvPort, msg)
				).postln;
			};
		};
		thisProcess.addOSCRecvFunc(~oscLogger);
		"OSC logging enabled (incoming messages from the tablet and other clients).".postln;
	} {
		"OSC logging off (OSC_LOG=1 or ~setOscLogging.(true) shows incoming messages).".postln;
	};
};

~setOscLogging.("OSC_LOG".getenv == "1");

// ---- Feedback helper ----
~sendToTouchOSC = { |addr, value|
	~touchOSC.sendMsg(addr.asString, value.asFloat);
};

// ---- Synth focus feedback ----
// Sends /synth/<name>/focused back to TouchOSC.
~sendFocusFeedback = {
	[\grain, \tape, \cembalo].do { |name|
		~sendToTouchOSC.("/synth/" ++ name ++ "/focused", (~focusedSynth == name).asInteger.asFloat);
	};
};

// Grain input source toggles: ~grainSrc key → OSC address
~grainSrcAddr = ( guitar: "/grain/srcGuitar", cembalo: "/grain/srcCembalo", tape: "/grain/srcTape" );
~sendGrainSrcFeedback = {
	~grainSrcAddr.keysValuesDo { |name, addr|
		~sendToTouchOSC.(addr, ~grainSrc[name].asInteger.asFloat);
	};
};

// ---- Value labels next to faders ----
~timeStretchLabel = { |val|
	var ts = if (val >= 0.5) { val.linlin(0.5, 1.0, 1.0, 4.0) } { val.linlin(0.0, 0.5, 0.25, 1.0) };
	ts.round(0.01).asString ++ "×"
};
~sendBufferLenLabel = { |durSec|
	~touchOSC.sendMsg('/grain/bufferLen-label', durSec.round(0.1).asString ++ " s");
};

// ---- Send all fader + toggle state to TouchOSC (boot sync / preset load) ----
// faderVals (optional): busIndex -> value, used instead of reading the buses back. Right after a preset
// has set the buses, the server has not applied them yet and getnSynchronous still returns the old values.
~sendAllState = { |faderVals|
	var allVals = ~ccBuses.getnSynchronous(128);
	faderVals !? { faderVals.keysValuesDo { |idx, val| allVals[idx.asInteger] = val } };
	// Faders: all entries in ~oscMap with a busIndex
	~oscMap.keysValuesDo { |addr, spec|
		if (spec[\type] == \fader) {
			~sendToTouchOSC.(addr, allVals.at(spec[\busIndex]));
		};
	};
	~touchOSC.sendMsg('/grain/timeStretch-label', ~timeStretchLabel.(allVals[~busNames[\timeStretch].index]));
	~sendBufferLenLabel.(~bufferDurSec);

	// Recorder (REC button + status line) and grain toggles
	~sendRecStatus.();
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
	~sendToTouchOSC.('/synth/cembalo/enable', ~synthEnabled[\cembalo].asInteger.asFloat);
	~sendFocusFeedback.();
	~sendGrainSrcFeedback.();

	// Preset grid: occupied / active slots, arm buttons, status (osc/presets.scd)
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

// ---- Cembalo faders: override the generic handler (the cembalo's parameters live in sclang) ----
~cembaloSpecs.keysDo { |key|
	var addr = "/cembalo/" ++ key;
	OSCdef(addr.asSymbol, { |msg| ~setCembaloParam.(key, msg[1]) }, addr);
};

// ---- Grain input sources: guitar / cembalo / tape synth, any combination ----
// Latching buttons in TouchOSC: the value is the new state. A source that is not audible on its own
// (cembalo / tape enable off) is started anyway while it feeds the grains.
~grainSrcAddr.keysValuesDo { |name, addr|
	OSCdef(addr.asSymbol, { |msg|
		var on = msg[1] >= 0.5;
		~grainSrc[name] = on;
		~updateChains.();
		~sendToTouchOSC.(addr, on.asInteger.asFloat);
		("Grain input " ++ name ++ ": " ++ if(on, "ON", "OFF")).postln;
	}, addr);
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
	var val;
	val = msg[1].clip(0.0, 1.0);
	~ccBuses.setAt(~busNames[\timeStretch].index, val);
	~sendToTouchOSC.('/grain/timeStretch', val);
	~touchOSC.sendMsg('/grain/timeStretch-label', ~timeStretchLabel.(val));
}, "/grain/timeStretch");

// ---- Buffer length fader: directly reallocate buffer ----
// A new buffer is empty: it is only allocated once the fader has rested for 0.4 s (not for every step
// while it is dragged); the label follows the fader right away.
OSCdef('/grain/bufferLen', { |msg|
	var val = msg[1].clip(0.0, 1.0);
	var durSec = val.linlin(0.0, 1.0, 0.1, 8.0);
	~ccBuses.setAt(~busNames[\bufferLen].index, val);
	~sendToTouchOSC.('/grain/bufferLen', val);
	~sendBufferLenLabel.(durSec);
	~bufferLenTask !? { ~bufferLenTask.stop };
	~bufferLenTask = Routine({
		0.4.wait;
		~bufferLenTask = nil;
		if ((durSec - ~bufferDurSec).abs > 0.001) { ~allocBuffer.(durSec) };
	}).play(AppClock);
}, "/grain/bufferLen");

// ---- Grain toggle OSCdefs ----
// All on/off buttons are toggle buttons on the tablet: the value IS the new state (1 = on, 0 = off), and
// the state is sent back so the button always shows what the patch does.

// REC: the one switch of the recorder (main_multi.scd, ~setRecording)
OSCdef('/grain/record', { |msg| ~setRecording.(msg[1] >= 0.5) }, "/grain/record");

OSCdef('/grain/reverse', { |msg|
	if (msg[1] >= 1.0) {
		~reverseState = ~reverseState.not;
		~g.set(\reverseGrain, ~reverseState.asInteger);
		~sendToTouchOSC.('/grain/reverse', ~reverseState.asInteger.asFloat);
		("Reverse grain: " ++ if(~reverseState, "ON", "OFF")).postln;
	};
}, "/grain/reverse");

OSCdef('/grain/fixedPos', { |msg|
	~fixedPosState = msg[1] >= 0.5;
	~g.set(\fixedPos, ~fixedPosState.asInteger);
	~sendToTouchOSC.('/grain/fixedPos', ~fixedPosState.asInteger.asFloat);
	("Fixed position: " ++ if(~fixedPosState, "ON", "OFF")).postln;
}, "/grain/fixedPos");

OSCdef('/grain/densFromDur', { |msg|
	~densFromDurState = msg[1] >= 0.5;
	~g.set(\densFromDurMode, ~densFromDurState.asInteger);
	~sendToTouchOSC.('/grain/densFromDur', ~densFromDurState.asInteger.asFloat);
	("Density from Duration: " ++ if(~densFromDurState, "ON", "OFF")).postln;
}, "/grain/densFromDur");

OSCdef('/grain/fftFreeze', { |msg|
	~fftFreezeState = msg[1] >= 0.5;
	~ccBuses.setAt(~busNames[\fftFreeze].index, ~fftFreezeState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fftFreeze', ~fftFreezeState.asInteger.asFloat);
	("FFT Freeze: " ++ if(~fftFreezeState, "ON", "OFF")).postln;
}, "/grain/fftFreeze");

OSCdef('/grain/xyMode', { |msg|
	var on = msg[1] >= 0.5;
	if (on != ~xyMode) {
		~xyMode = on;
		if (~xyMode) {
			~g !? { ~g.run(false) };
		} {
			5.do { |i| ~releaseXYVoice.(i) };
			~g !? { ~g.run(true) };
		};
		("XY Mode: " ++ if(~xyMode, "ON", "OFF")).postln;
	};
	~sendToTouchOSC.('/grain/xyMode', ~xyMode.asInteger.asFloat);
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

// CLEAR and LOAD SAMPLE: push buttons, act on the press
OSCdef('/grain/deleteBuffer', { |msg|
	if (msg[1] >= 0.5) { ~deleteBuffer.() };
}, "/grain/deleteBuffer");

OSCdef('/grain/loadSample', { |msg|
	if (msg[1] >= 0.5) { ~loadBuffer.(nil) };
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
// ~setSynthEnabled.(\grain | \tape | \cembalo, bool, focus)
// Used by the tablet buttons and the footswitch (midiconfig_multi.scd). focus: also point the expression pedal
// at this synth when it is switched on (the tablet does that; the footswitch does not).
~setSynthEnabled = { |name, on, focus = true|
	~synthEnabled[name] = on;
	if (name == \grain) {
		if (on) {
			// Resume grain chain
			~g !? { if (~xyMode.not) { ~g.run(true) } };
			~fftFx !? { ~fftFx.run(true) };
			~grainMaster !? { ~grainMaster.run(true) };
		} {
			// Release XY voices, then pause grain chain
			5.do { |i| ~releaseXYVoice !? { ~releaseXYVoice.(i) } };
			~g !? { ~g.run(false) };
			~fftFx !? { ~fftFx.run(false) };
			~grainMaster !? { ~grainMaster.run(false) };
			// ~mic / ~ptr / ~rec kept running so the buffer stays current
		};
	} {
		// tape / cembalo: starts / fades in, or fades out and pauses (unless it still feeds the grains)
		~updateChains.();
	};
	if (on and: { focus }) {
		~focusedSynth = name;
		~sendFocusFeedback.();
	};
	~sendToTouchOSC.("/synth/" ++ name ++ "/enable", on.asInteger.asFloat);
	(name.asString ++ ": " ++ if(on, "ENABLED", "DISABLED")).postln;
};

[\grain, \tape, \cembalo].do { |name|
	var addr = "/synth/" ++ name ++ "/enable";
	OSCdef(addr.asSymbol, { |msg| ~setSynthEnabled.(name, msg[1] >= 0.5) }, addr);
};

// ---- Synth focus (MIDI expression pedal routing) ----
OSCdef('/synth/focus', { |msg|
	var name = msg[1].asSymbol;
	if (#[\grain, \tape, \cembalo].includes(name)) {
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
