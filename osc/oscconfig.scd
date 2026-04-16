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
~touchOSCip   = "192.168.1.100";
~touchOSCport = 9000;
~touchOSC     = NetAddr(~touchOSCip, ~touchOSCport);

"TouchOSC target: % : %".format(~touchOSCip, ~touchOSCport).postln;
"SC listening on port: %".format(NetAddr.langPort).postln;

// ---- Feedback helper ----
// Send a single float value back to TouchOSC on the given address.
~sendToTouchOSC = { |addr, value|
	~touchOSC.sendMsg(addr.asString, value.asFloat);
};

// ---- Send all fader + toggle state to TouchOSC (boot sync / preset load) ----
~sendAllState = {
	// Faders: read current ccBus values and send back
	~oscMap.keysValuesDo { |addr, spec|
		if (spec[\type] == \fader) {
			~ccBuses.getn(spec[\busIndex], 1, { |val|
				~sendToTouchOSC.(addr, val[0]);
			});
		};
	};

	// Toggles
	~sendToTouchOSC.('/grain/record',   ~recState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/liveMode',  ~liveMode.asInteger.asFloat);
	~sendToTouchOSC.('/grain/reverse',   ~reverseState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fixedPos',  ~fixedPosState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/mute',      ~muteState.asInteger.asFloat);

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
	if (msg[1] >= 1.0) {
		if (~liveMode) {
			~stopLiveMode.();
		} {
			~startLiveMode.();
		};
		~sendToTouchOSC.('/grain/liveMode', ~liveMode.asInteger.asFloat);
	};
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

OSCdef('/grain/mute', { |msg|
	if (msg[1] >= 1.0) {
		~muteState = ~muteState.not;
		if (~muteState) {
			~prevAmp = ~ccBuses.getnSynchronous(128).at(~busNames[\masterVol].index);
			~ccBuses.setAt(~busNames[\masterVol].index, 0);
			"MUTED".postln;
		} {
			~ccBuses.setAt(~busNames[\masterVol].index, ~prevAmp);
			"UNMUTED".postln;
		};
		~sendToTouchOSC.('/grain/mute', ~muteState.asInteger.asFloat);
	};
}, "/grain/mute");

// ---- Momentary OSCdefs ----

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
		~currentRate = 1.0;
		~ccBuses.setAt(~busNames[\rate].index, 1.0.linlin(0.0625, 3.0625, 0, 1).clip(0, 1));
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
		~fbUpdater.stop;
		~bufLenUpdater.stop;
		s.freeAll;
	};
}, "/grain/stopAudio");

"OSC responders registered.".postln;
)
