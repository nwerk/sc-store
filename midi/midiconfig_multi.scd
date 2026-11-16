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
//       cembalo focused → cembalo volume (~setCembaloParam, CC 100 + /cembalo/volume)
//       pad focused   → CC 110 bus slot + /pad/volume
//   - Footswitches CC 80/81/82: granular on/off, next preset, tape + cembalo on/off
//     (see ~footswitchActions below).
//
// Requires: ~busNames (osc_mappings_multi.scd)
// ============================================================

(
// ~ccBuses (128 control buses, the CC slots) is allocated by main_multi.scd right after the server has booted.
// It must not be allocated here: this file runs before the boot, and booting resets the bus allocator, so the
// pitch tracker's / cembalo's buses would then get the same indices and overwrite the CC slots
// (tracker note frequencies in master volume, density, rate, ...).
~ccBuses = nil;

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
		if (~ccBuses.isNil) {
			// server not booted yet
		} { if (~latchingCCs.includes(ccNum)) {
			if (val == 127) {
				~latchingStates[ccNum] = 1 - ~latchingStates[ccNum];
				~ccBuses.setAt(ccNum, ~latchingStates[ccNum]);
			};
		} {
			~ccBuses.setAt(ccNum, val / 127);
		} };
	}
);

// ---- Boss FS-1-WL expression pedal (CC 11) → focused synth volume ----
// Grain focused: updates CC 11 bus + sends /master/volume via ~setMasterVol.
// Tape focused:  updates CC 96 bus + sends /tape/volume.
// Cembalo focused: cembalo volume via ~setCembaloParam (also sends /cembalo/volume).
// Pad focused: updates CC 110 bus + sends /pad/volume.
~lastExpPedalRaw  = nil;
~expPedalDeadband = 2;
~expPedalSmoothed = 1.0;
~expPedalLagCoeff = 0.15;

MIDIdef.cc(\expressionPedalMasterVol,
	{ |val, ccNum, chan, src|
		if (~lastExpPedalRaw.isNil or: { (val - ~lastExpPedalRaw).abs > ~expPedalDeadband }) {
			~lastExpPedalRaw  = val;
			~expPedalSmoothed = ~expPedalSmoothed + (~expPedalLagCoeff * (val / 127.0 - ~expPedalSmoothed));
			case
			{ ~focusedSynth == \grain } {
				~setMasterVol !? { ~setMasterVol.(~expPedalSmoothed) };
			}
			{ ~focusedSynth == \cembalo } {
				~setCembaloParam !? { ~setCembaloParam.(\volume, ~expPedalSmoothed) };
			}
			{ ~focusedSynth == \pad } {
				~ccBuses !? { ~ccBuses.setAt(~busNames[\pad_volume].index, ~expPedalSmoothed) };
				~sendToTouchOSC !? { ~sendToTouchOSC.('/pad/volume', ~expPedalSmoothed) };
			} {
				// Tape: write to CC 96 bus slot; \ape reads master_vol from there
				~ccBuses !? { ~ccBuses.setAt(~busNames[\tape_master].index, ~expPedalSmoothed) };
				~sendToTouchOSC !? { ~sendToTouchOSC.('/tape/volume', ~expPedalSmoothed) };
			};
		};
	},
	ccNum: 11
);

// ---- Boss FS-1-WL footswitches ----
// The three switches send CC 80 / 81 / 82 (127 on press). If left and right are swapped on your unit,
// swap the CC numbers in ~footswitchCC.
//   left   : granular on / off
//   middle : next stored preset (steps through the occupied slots, wraps around)
//   right  : tape synth + cembalo on / off together (if either is on, both go off)
// The expression pedal keeps its current target (the footswitch does not change ~focusedSynth).
// The pad has no footswitch: it is switched on the tablet.
~footswitchCC = (left: 80, middle: 81, right: 82);
~footswitchActions = (
	left: {
		~setSynthEnabled !? { ~setSynthEnabled.(\grain, ~synthEnabled[\grain].not, false) };
	},
	middle: {
		~loadNextPreset !? { ~loadNextPreset.() };
	},
	right: {
		var on = (~synthEnabled[\tape] or: { ~synthEnabled[\cembalo] }).not;
		~setSynthEnabled !? {
			~setSynthEnabled.(\tape, on, false);
			~setSynthEnabled.(\cembalo, on, false);
		};
	},
);

~footswitchCC.keysValuesDo { |name, cc|
	MIDIdef.cc(("fs1wl_" ++ name).asSymbol, { |val|
		// only once the patch is up (the actions need the server and the OSC layer)
		if (val == 127 and: { ~synthEnabled.notNil }) {
			("Footswitch " ++ name).postln;
			~footswitchActions[name].value;
		};
	}, ccNum: cc);
};

"MIDI config (multi) loaded.".postln;
)
