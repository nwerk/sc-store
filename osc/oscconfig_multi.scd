// ============================================================
// OSC Configuration — TouchOSC ↔ SuperCollider (Multi-Synth Patch)
// ============================================================
// Requires: ~oscMap, ~busToOsc        (osc_mappings_multi.scd)
//           ~ccBuses, ~busNames       (midiconfig_multi.scd)
//           ~rec, ~g, ~ptr, b        (main_multi.scd)
//           ~grainMaster, ~tapeMaster, ~cembaloMaster, ~padMaster (main_multi.scd)
//           ~synthEnabled, ~grainSrc, ~focusedSynth, ~updateChains,
//           ~setCembaloParam, ~cembaloSpecs (main_multi.scd)
//           ~xyTouch, ~setXYMap, ~setXYHold, ~xyMaps, ~xyMapOrder (main_multi.scd)
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
	[\grain, \tape, \cembalo, \pad].do { |name|
		~sendToTouchOSC.("/synth/" ++ name ++ "/focused", (~focusedSynth == name).asInteger.asFloat);
	};
};

// Grain input source toggles: ~grainSrc key → OSC address
~grainSrcAddr = ( guitar: "/grain/srcGuitar", cembalo: "/grain/srcCembalo", tape: "/grain/srcTape", pad: "/grain/srcPad" );
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

// ---- FFT effect: what its stepped / bipolar controls are set to, in real units ----
// The same curves as in synths/fft_prism.scd (keep them in sync).
~fftBipolar = { |v, dead = 0.06| var d = (v - 0.5) * 2; d.sign * ((d.abs - dead).max(0) / (1 - dead)) };
~signed = { |v, digits = 0.1| if (v > 0, "+", "") ++ v.round(digits).asString };
~faderLabels = (
	'/grain/fftWarp': { |v|
		var semi = (~fftBipolar.(v) * 12).round.asInteger;
		if (semi == 0) { "off" } { ~signed.(semi, 1) ++ " st" }
	},
	'/grain/fftTime': { |v| (v.squared * 1.5 + 0.045).round(0.01).asString ++ " s" },
	'/grain/fftSource': { |v| case { v < 0.02 } { "grains" } { v > 0.98 } { "input" } { (v * 100).round.asInteger.asString ++ " % in" } },
	'/grain/fftTilt': { |v|
		var w = ~fftBipolar.(v, 0.04);
		case
		{ w < 0 } { "LP " ++ (24000 * (0.004 ** w.abs)).round(10).asInteger ++ " Hz" }
		{ w > 0 } { "HP " ++ (24000 * ((125 ** w) - 1) * 0.002).round(10).asInteger ++ " Hz" }
		{ "open" }
	},
);
~sendFaderLabel = { |addr, val|
	~faderLabels[addr.asSymbol] !? { |fn| ~touchOSC.sendMsg(addr.asString ++ "-label", fn.(val)) };
};

// ---- FFT pad: x = frequency shift per round (fftSpiral), y = feedback (fftFeedback) ----
~sendFftPadLabel = { |x, y|
	var hz = ~fftBipolar.(x) ** 3 * 600;
	var fb = y.lincurve(0, 1, 0, 1.05, -2.5);
	~touchOSC.sendMsg('/grain/fftPad-label',
		"shift " ++ if (hz == 0) { "off" } { ~signed.(hz, if (hz.abs < 10, 0.01, 1)) ++ " Hz" }
		++ "   ·   feedback " ++ if (fb >= 1) { "endless" } { (fb * 100).round.asInteger.asString ++ " %" });
};
~sendFftPad = { |x, y|
	~touchOSC.sendMsg('/grain/fftPad', x.asFloat, y.asFloat);
	~sendFftPadLabel.(x, y);
};

// ---- MultiXY page: mapping buttons, hold, the line that says what the axes do ----
~sendXYState = {
	~xyMapOrder.do { |name|
		~sendToTouchOSC.("/grain/xyMap/" ++ name, (name == ~xyMap).asInteger.asFloat);
	};
	~sendToTouchOSC.('/grain/xyHold', ~xyHold.asInteger.asFloat);
	~touchOSC.sendMsg('/grain/xyHint', ~xyMaps[~xyMap][\hint]);
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
			~sendFaderLabel.(addr, allVals.at(spec[\busIndex]));
		};
	};
	~sendFftPad.(allVals[~busNames[\fftSpiral].index], allVals[~busNames[\fftFeedback].index]);
	~touchOSC.sendMsg('/grain/timeStretch-label', ~timeStretchLabel.(allVals[~busNames[\timeStretch].index]));
	~sendBufferLenLabel.(~bufferDurSec);

	// Grain loop (LIVE button + status line), sample slots, output recorder, grain toggles
	~sendBufferStatus.();
	~sendSampleSlots.();
	~sendOutRecStatus.();
	~sendToTouchOSC.('/grain/reverse',     ~reverseState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fixedPos',    ~fixedPosState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/fftFreeze',   ~fftFreezeState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/xyMode',         ~xyMode.asInteger.asFloat);
	~sendXYState.();
	~sendToTouchOSC.('/grain/densFromDur',    ~densFromDurState.asInteger.asFloat);
	~sendToTouchOSC.('/grain/pitchTrackMode', ~pitchTrackMode.asInteger.asFloat);
	~sendToTouchOSC.('/grain/pitchMode/pos',
		(~ptFixedPosSec / ~bufferDurSec.max(0.001)).clip(0.0, 1.0).asFloat);
	~sendToTouchOSC.('/grain/pitchMode/rateScale', ~ptRateScale.asFloat);

	// Status
	~sendToTouchOSC.('/status/rate',      ~currentRate.asFloat);
	~sendToTouchOSC.('/status/bufferLen', ~bufferDurSec.asFloat);

	// Synth enable/focus state
	~sendToTouchOSC.('/synth/grain/enable', ~synthEnabled[\grain].asInteger.asFloat);
	~sendToTouchOSC.('/synth/tape/enable',  ~synthEnabled[\tape].asInteger.asFloat);
	~sendToTouchOSC.('/synth/cembalo/enable', ~synthEnabled[\cembalo].asInteger.asFloat);
	~sendToTouchOSC.('/synth/pad/enable',  ~synthEnabled[\pad].asInteger.asFloat);
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
			~sendFaderLabel.(addr, val);
		}, addr.asString);
	};
};

// ---- FFT pad (an XY control: x, y, touch) ----
// Not echoed while it is touched: the pad would fight the finger. The label follows.
OSCdef('/grain/fftPad', { |msg|
	var x = msg[1].clip(0.0, 1.0), y = msg[2].clip(0.0, 1.0);
	~ccBuses.setAt(~busNames[\fftSpiral].index, x);
	~ccBuses.setAt(~busNames[\fftFeedback].index, y);
	~sendFftPadLabel.(x, y);
}, "/grain/fftPad");

// ---- Cembalo faders: override the generic handler (the cembalo's parameters live in sclang) ----
~cembaloSpecs.keysDo { |key|
	var addr = "/cembalo/" ++ key;
	OSCdef(addr.asSymbol, { |msg| ~setCembaloParam.(key, msg[1]) }, addr);
};

// ---- Grain input sources: guitar / cembalo / tape synth / pad, any combination ----
// Latching buttons in TouchOSC: the value is the new state. A source that is not audible on its own
// (cembalo / tape / pad enable off) is started anyway while it feeds the grains.
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

// LIVE: the one switch of the grain loop (main_multi.scd, ~setLiveMode)
OSCdef('/grain/liveMode', { |msg| ~setLiveMode.(msg[1] >= 0.5) }, "/grain/liveMode");

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

// ---- Pitch-tracker mode toggle ----
// On activation: forces fixedPos=1, stops live mode, applies modulation preset (all zeros).
// Modulation CC buses are set to 0 so sliders snap; user can freely adjust from there.
OSCdef('/grain/pitchTrackMode', { |msg|
	if (msg[1] >= 1.0) {
		~pitchTrackMode = ~pitchTrackMode.not;
		~g.set(\pitchTrackMode, ~pitchTrackMode.asInteger);
		if (~pitchTrackMode) {
			// Position lock
			~g.set(\fixedPos, 1);
			~fixedPosState = true;
			~sendToTouchOSC.('/grain/fixedPos', 1.0);
			// Stop live mode: the loop holds still
			~setLiveMode.(false);
			// Force Impulse trigger + no rate scatter (not CC-bus driven)
			~g.set(\sync, 1, \rateRand, 1);
			// Zero modulation CC buses + send slider feedback to TouchOSC
			~ccBuses.setAt(~busNames[\randomOctave].index, 0.0);
			~ccBuses.setAt(~busNames[\randDetune].index,   0.0);
			~ccBuses.setAt(~busNames[\freqModAmt].index,   0.0);
			~ccBuses.setAt(~busNames[\freqModFreq].index,  0.0);
			~ccBuses.setAt(~busNames[\jitter].index,       0.0);
			~ccBuses.setAt(~busNames[\panRand].index,      0.0);
			~sendToTouchOSC.('/grain/randomOctave', 0.0);
			~sendToTouchOSC.('/grain/randDetune',   0.0);
			~sendToTouchOSC.('/grain/freqModAmt',   0.0);
			~sendToTouchOSC.('/grain/freqModFreq',  0.0);
			~sendToTouchOSC.('/grain/jitter',       0.0);
			~sendToTouchOSC.('/grain/panRand',      0.0);
		};
		~sendToTouchOSC.('/grain/pitchTrackMode', ~pitchTrackMode.asInteger.asFloat);
		("Pitch Track Mode: " ++ if(~pitchTrackMode, "ON", "OFF")).postln;
	};
}, "/grain/pitchTrackMode");

// ---- Pitch-tracker: sample position slider (0–1 → 0–bufferDur seconds) ----
OSCdef('/grain/pitchMode/pos', { |msg|
	var val    = msg[1].clip(0.0, 1.0);
	var posSec = val * ~bufferDurSec;
	~ptFixedPosSec = posSec;
	~g.set(\fixedPosSec, posSec);
	~sendToTouchOSC.('/grain/pitchMode/pos', val);
	~touchOSC.sendMsg('/grain/pitchMode/pos-label', posSec.round(0.01).asString ++ "s");
}, "/grain/pitchMode/pos");

// ---- Pitch-tracker: amplitude→rate modulation depth ----
OSCdef('/grain/pitchMode/rateScale', { |msg|
	var val = msg[1].clip(0.0, 1.0);
	~ptRateScale = val;
	~g.set(\ptRateScale, val);
	~sendToTouchOSC.('/grain/pitchMode/rateScale', val);
}, "/grain/pitchMode/rateScale");

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
			~releaseAllXYVoices.();
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
		~xyTouch.(idx, x, y, z);
	}, addr);
};

// ---- MultiXY: mapping (one of the buttons is lit) and hold ----
// Toggle buttons on the tablet; tapping the lit one keeps it lit.
~xyMapOrder.do { |name|
	var addr = "/grain/xyMap/" ++ name;
	OSCdef(addr.asSymbol, { |msg|
		if (msg[1] >= 0.5) { ~setXYMap.(name) } { ~sendXYState.() };
	}, addr);
};
OSCdef('/grain/xyHold', { |msg| ~setXYHold.(msg[1] >= 0.5) }, "/grain/xyHold");

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

// CLEAR: a push button, acts on the press
OSCdef('/grain/deleteBuffer', { |msg|
	if (msg[1] >= 0.5) { ~deleteBuffer.() };
}, "/grain/deleteBuffer");

OSCdef('/grain/stopAudio', { |msg|
	if (msg[1] >= 1.0) {
		"Stopping all audio...".postln;
		~speedUpdater.stop;
		~releaseAllXYVoices.();
		s.freeAll;
	};
}, "/grain/stopAudio");

// ---- Output recorder: REC in the right column (main_multi.scd, ~startOutputRecording) ----
// A toggle button: the value is the new state, the state is sent back.
OSCdef('/record/disk', { |msg|
	if (msg[1] >= 0.5) { ~startOutputRecording.() } { ~stopOutputRecording.() };
}, "/record/disk");

// ---- Sample slots A-D on the preset page: load the first four files of samples/ into the grain buffer ----
// Push buttons: act on the press; on release the slot of the loaded sample is lit again.
~sampleSlotCount.do { |i|
	var addr = "/preset/sample/" ++ i;
	OSCdef(addr.asSymbol, { |msg|
		if (msg[1] >= 0.5) {
			~loadSampleSlot.(i);
			// a preset stores its sample: choosing another one is a change to the loaded preset
			if (~activePreset >= 0 and: { ~presetDirty.not }) { ~presetDirty = true; ~sendPresetName.() };
		} {
			~sendSampleSlots.();
		};
	}, addr);
};

// ---- Synth enable/disable ----
// ~setSynthEnabled.(\grain | \tape | \cembalo | \pad, bool, focus)
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
			~releaseAllXYVoices !? { ~releaseAllXYVoices.() };
			~g !? { ~g.run(false) };
			~fftFx !? { ~fftFx.run(false) };
			~grainMaster !? { ~grainMaster.run(false) };
			// ~mic / ~ptr / ~rec kept running so the buffer stays current
		};
	} {
		// tape / cembalo / pad: starts / fades in, or fades out and pauses (unless it still feeds the grains)
		~updateChains.();
	};
	if (on and: { focus }) {
		~focusedSynth = name;
		~sendFocusFeedback.();
	};
	~sendToTouchOSC.("/synth/" ++ name ++ "/enable", on.asInteger.asFloat);
	(name.asString ++ ": " ++ if(on, "ENABLED", "DISABLED")).postln;
};

[\grain, \tape, \cembalo, \pad].do { |name|
	var addr = "/synth/" ++ name ++ "/enable";
	OSCdef(addr.asSymbol, { |msg| ~setSynthEnabled.(name, msg[1] >= 0.5) }, addr);
};

// ---- Synth focus (MIDI expression pedal routing) ----
OSCdef('/synth/focus', { |msg|
	var name = msg[1].asSymbol;
	if (#[\grain, \tape, \cembalo, \pad].includes(name)) {
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
