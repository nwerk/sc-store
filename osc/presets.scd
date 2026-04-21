// ============================================================
// Preset System — Save / Load / Delete (Granular Patch)
// ============================================================
// Requires: ~oscMap, ~ccBuses, ~touchOSC, ~sendToTouchOSC,
//           ~sendAllState (from oscconfig.scd)
// Presets stored as .scd archive files in osc/presets/
// ============================================================

(
~presetDir = ~basePath ++ "osc/presets/";

// Ensure preset directory exists
if (File.exists(~presetDir).not) {
	File.mkdir(~presetDir);
};

~activePreset = -1; // -1 = no preset loaded

// ---- Fader bus indices (the parameters stored in presets) ----
~presetFaderIndices = ~oscMap.select { |spec| spec[\type] == \fader }.values.collect { |spec| spec[\busIndex] }.asArray.sort;

// ---- Preset file path helper ----
~presetPath = { |index|
	~presetDir ++ "preset_" ++ index.asString ++ ".scd";
};

// ---- Check if a preset slot is occupied ----
~presetExists = { |index|
	File.exists(~presetPath.(index));
};

// ---- Send preset slot occupancy to TouchOSC ----
~sendPresetSlots = {
	16.do { |i|
		~sendToTouchOSC.(
			"/preset/slot/" ++ i.asString,
			~presetExists.(i).asInteger.asFloat
		);
	};
	~sendToTouchOSC.('/preset/active', ~activePreset);
};

// ---- Save preset ----
// Snapshots all fader bus values + toggle states → writes to disk
~savePreset = { |index|
	var data = Dictionary.new;
	var path = ~presetPath.(index);
	var faderVals = Dictionary.new;
	var allVals = ~ccBuses.getnSynchronous(128);

	// Read fader values from a full synchronous bus snapshot
	~presetFaderIndices.do { |busIdx|
		faderVals[busIdx] = allVals.at(busIdx);
	};
	data[\faders] = faderVals;

	// Toggle states
	data[\recState]      = ~recState.asInteger;
	data[\liveMode]      = ~liveMode.asInteger;
	data[\reverseState]  = ~reverseState.asInteger;
	data[\fixedPosState] = ~fixedPosState.asInteger;
	data[\fftFreezeState] = ~fftFreezeState.asInteger;
	data[\currentRate]   = ~currentRate;

	// Write to disk
	data.writeArchive(path);
	~activePreset = index;

	("Preset " ++ index ++ " saved to: " ++ path).postln;
	~sendPresetSlots.();
};

// ---- Load preset ----
// Reads from disk → sets ccBuses + toggle states → sends all values to TouchOSC
~loadPreset = { |index|
	var path = ~presetPath.(index);

	if (File.exists(path)) {
		var data = Object.readArchive(path);

		// Restore fader values
		data[\faders].keysValuesDo { |busIdx, val|
			~ccBuses.setAt(busIdx.asInteger, val.asFloat);
		};

		// Apply master volume to synth arg directly (CC bus read alone is not enough)
		~setMasterVol.(data[\faders][~busNames[\masterVol].index] ? 1.0);

		// Restore toggle states
		~recState      = data[\recState].asBoolean;
		~liveMode      = data[\liveMode].asBoolean;
		~reverseState  = data[\reverseState].asBoolean;
		~fixedPosState = data[\fixedPosState].asBoolean;
		~fftFreezeState = (data[\fftFreezeState] ? data[\muteState] ? 0).asBoolean;
		~currentRate   = data[\currentRate] ? 1.0;

		// Apply toggle states to synths
		~rec.set(\recGate, ~recState.asInteger);
		if (~liveMode) { ~startLiveMode.() } { ~stopLiveMode.() };
		~g.set(\reverseGrain, ~reverseState.asInteger);
		~g.set(\fixedPos, ~fixedPosState.asInteger);
		~ccBuses.setAt(~busNames[\fftFreeze].index, ~fftFreezeState.asInteger.asFloat);
		~g.set(\rate, ~currentRate);

		~activePreset = index;
		("Preset " ++ index ++ " loaded.").postln;

		// Send entire state to TouchOSC (faders + toggles + slot indicators)
		~sendAllState.();
	} {
		("Preset " ++ index ++ " does not exist.").postln;
	};
};

// ---- Delete preset ----
~deletePreset = { |index|
	var path = ~presetPath.(index);

	if (File.exists(path)) {
		File.delete(path);
		if (~activePreset == index) { ~activePreset = -1 };
		("Preset " ++ index ++ " deleted.").postln;
	} {
		("Preset " ++ index ++ " not found.").postln;
	};
	~sendPresetSlots.();
};

// ---- OSC responders for presets ----

OSCdef('/preset/load', { |msg|
	var index = msg[1].asInteger.clip(0, 15);
	~loadPreset.(index);
}, "/preset/load");

OSCdef('/preset/save', { |msg|
	var index = msg[1].asInteger.clip(0, 15);
	~savePreset.(index);
}, "/preset/save");

OSCdef('/preset/delete', { |msg|
	var index = msg[1].asInteger.clip(0, 15);
	~deletePreset.(index);
}, "/preset/delete");

"Preset system loaded (" ++ ~presetDir ++ ").".postln;
)
