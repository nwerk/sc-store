// ============================================================
// MIDI Configuration — Multi-Synth Patch
// ============================================================
// Connects the Boss FS-1-WL USB-MIDI footswitch only.
// MIDI Mix is not used — all fader/knob control via TouchOSC.
//
// Changes vs midiconfig.scd:
//   - Expression pedal (CC 11) routes to focused synth:
//       grain focused → ~setMasterVol (CC 11 + TouchOSC)
//       tape focused  → CC 96 bus slot + /tape/volume
//   - Footswitches CC 80/81/82 dispatch to ~midiDispatch stubs.
//     Stubs are no-ops; add logic there when needed.
//
// Requires: ~busNames (osc_mappings_multi.scd)
// ============================================================

(
~ccBuses = Bus.control(s, 128);
~ccBuses.setn(Array.fill(128, 0.0));

// Collect all latching CC indices from ~busNames
~latchingCCs = ~busNames.keys.asArray
	.select { |k| (~busNames[k][\isLatch] == true) }
	.collect { |k| ~busNames[k][\index] };

~latchingStates = Array.fill(128, 0);

~connect_midi_devices = { |device, name|
	if (MIDIClient.initialized == false) {
		MIDIClient.init;
	} {
		MIDIClient.list;
	};

	MIDIClient.sources.do({ |endPoint|
		if (device.notNil and: { name.notNil } and: { endPoint.device == device } and: { endPoint.name == name }) {
			try { MIDIOut.connect(0, endPoint.uid) };
			try { MIDIIn.connect(0, endPoint.uid) };
		}
	});
};

Platform.case(
	\linux,   { ~connect_midi_devices.("FS-1-WL USB-MIDI", "FS-1-WL USB-MIDI MIDI 1"); },
	\windows, { ~connect_midi_devices.("FS-1-WL USB-MIDI", "FS-1-WL USB-MIDI"); }
);

MIDIdef.trace(true);

// ---- Store all CC values into shared bus ----
MIDIdef.cc(
	\storeCC,
	{ |val, ccNum, chan, src|
		if (~latchingCCs.includes(ccNum)) {
			if (val == 127) {
				~latchingStates[ccNum] = 1 - ~latchingStates[ccNum];
				~ccBuses.setAt(ccNum, ~latchingStates[ccNum]);
			};
		} {
			~ccBuses.setAt(ccNum, val / 127);
		};
	}
);

// ---- Boss FS-1-WL expression pedal (CC 11) → focused synth volume ----
// Grain focused: updates CC 11 bus + sends /master/volume via ~setMasterVol.
// Tape focused:  updates CC 96 bus + sends /tape/volume.
~lastExpPedalRaw  = nil;
~expPedalDeadband = 2;
~expPedalSmoothed = 1.0;
~expPedalLagCoeff = 0.15;

MIDIdef.cc(\expressionPedalMasterVol,
	{ |val, ccNum, chan, src|
		if (~lastExpPedalRaw.isNil or: { (val - ~lastExpPedalRaw).abs > ~expPedalDeadband }) {
			~lastExpPedalRaw  = val;
			~expPedalSmoothed = ~expPedalSmoothed + (~expPedalLagCoeff * (val / 127.0 - ~expPedalSmoothed));
			if (~focusedSynth == \grain) {
				~setMasterVol !? { ~setMasterVol.(~expPedalSmoothed) };
			} {
				// Tape: write to CC 96 bus slot; \ape reads master_vol from there
				~ccBuses !? { ~ccBuses.setAt(~busNames[\tape_master].index, ~expPedalSmoothed) };
				~sendToTouchOSC !? { ~sendToTouchOSC.('/tape/volume', ~expPedalSmoothed) };
			};
		};
	},
	ccNum: 11
);

// ---- Footswitch dispatch (context-sensitive, no-op stubs) ----
// Populate ~midiDispatch to add per-synth footswitch actions later.
~midiDispatch = (
	grain: (
		cc80: { "FS CC80 (grain): no action".postln },
		cc81: { "FS CC81 (grain): no action".postln },
		cc82: { "FS CC82 (grain): no action".postln },
	),
	tape: (
		cc80: { "FS CC80 (tape): no action".postln },
		cc81: { "FS CC81 (tape): no action".postln },
		cc82: { "FS CC82 (tape): no action".postln },
	),
);

MIDIdef.cc(\fs1wl_80, { |val|
	if (val == 127) { ~midiDispatch[~focusedSynth][\cc80].() }
}, ccNum: 80);

MIDIdef.cc(\fs1wl_81, { |val|
	if (val == 127) { ~midiDispatch[~focusedSynth][\cc81].() }
}, ccNum: 81);

MIDIdef.cc(\fs1wl_82, { |val|
	if (val == 127) { ~midiDispatch[~focusedSynth][\cc82].() }
}, ccNum: 82);

"MIDI config (multi) loaded.".postln;
)
