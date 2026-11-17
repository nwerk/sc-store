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
~presetMode   = \load;               // what a slot tap does: \load, \save, \delete (the arm buttons)
~presetDirty  = false;               // something was changed on the tablet since the last load / save
~presetStatus = "tap a slot to load";

// ---- Fader bus indices (the parameters stored in presets) ----
// (~fftPadSlots, main_multi.scd only: the FFT pad's two slots, which are not faders)
~presetFaderIndices = (~oscMap.select { |spec| spec[\type] == \fader }.values.collect { |spec| spec[\busIndex] }.asArray
	++ (~fftPadSlots ? [])).sort;

// ---- Preset file path helper ----
~presetPath = { |index|
	~presetDir ++ "preset_" ++ index.asString ++ ".scd";
};

// ---- Read a preset file; nil if it is missing or damaged ----
// A power loss while a preset was being written could leave a half-written file (saving is atomic now, see
// ~writePresetFile, but older files or a damaged SD card can still have them). Such a file is skipped with a
// warning instead of stopping the boot sync / footswitch.
~readPresetData = { |path|
	var data = if (File.exists(path)) { try { Object.readArchive(path) } { nil } };
	if (data.isKindOf(Dictionary) and: { data[\faders].isKindOf(Dictionary) }) {
		data
	} {
		if (File.exists(path)) { ("Preset file % is damaged (unreadable) and is skipped.".format(path)).warn };
		nil
	};
};

// ---- Write a preset file so that a power loss cannot destroy it ----
// Written to <file>.tmp, checked, flushed to the card, then renamed over the old file (a rename is atomic):
// after a power loss either the old or the new preset is there, never a half-written one.
~writePresetFile = { |data, path|
	var tmp = path ++ ".tmp";
	data.writeArchive(tmp);
	if (~readPresetData.(tmp).isNil) {
		("Preset could not be written to %".format(tmp)).warn;
		false
	} {
		if (thisProcess.platform.name == \windows) {
			File.delete(path); File.copy(tmp, path); File.delete(tmp);
		} {
			("sync -- % && mv -f -- % % && sync -- %".format(
				tmp.shellQuote, tmp.shellQuote, path.shellQuote, ~presetDir.shellQuote)).systemCmd;
		};
		true
	};
};

// ---- Check if a preset slot is occupied ----
~presetExists = { |index|
	File.exists(~presetPath.(index));
};

// ---- Send the preset state to TouchOSC ----
// Preset page (main_multi): 16 slot buttons /preset/tap/N (lit = active preset) with labels /preset/label/N
// ("3  ●" = stored, "3" = empty), the arm buttons /preset/saveArm and /preset/deleteArm, the status line
// /preset/status. Right column: /preset/name ("PRESET 3", "*" = changed since loaded / saved).
// /preset/slot/N and /preset/active are kept for other layouts.
~sendPresetName = {
	~touchOSC.sendMsg('/preset/name',
		if (~activePreset >= 0) { "PRESET " ++ ~activePreset } { "PRESET -" } ++ if (~presetDirty, " *", ""));
};
~sendPresetSlots = {
	16.do { |i|
		var used = ~presetExists.(i);
		~sendToTouchOSC.("/preset/slot/" ++ i.asString, used.asInteger.asFloat);
		~touchOSC.sendMsg("/preset/label/" ++ i, i.asString ++ if (used, "  ●", ""));
		~sendToTouchOSC.("/preset/tap/" ++ i, (i == ~activePreset).asInteger.asFloat);
	};
	~sendToTouchOSC.('/preset/active', ~activePreset);
	~sendToTouchOSC.('/preset/saveArm',   (~presetMode == \save).asInteger.asFloat);
	~sendToTouchOSC.('/preset/deleteArm', (~presetMode == \delete).asInteger.asFloat);
	~touchOSC.sendMsg('/preset/status', ~presetStatus);
	~sendPresetName.();
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
	data[\liveMode]      = (~liveMode ? false).asInteger;  // main_grain.scd only (main_multi: REC alone)
	data[\reverseState]  = ~reverseState.asInteger;
	data[\fixedPosState] = ~fixedPosState.asInteger;
	data[\fftFreezeState]   = ~fftFreezeState.asInteger;
	data[\densFromDurState] = ~densFromDurState.asInteger;
	data[\currentRate]      = ~currentRate;
	data[\pitchTrackMode]   = ~pitchTrackMode.asInteger;
	data[\ptRateScale]      = ~ptRateScale;
	data[\ptFixedPosSec]    = ~ptFixedPosSec;
	data[\samplePath]       = ~samplePath;
	// main_multi.scd: which sources feed the grain buffer (guitar / cembalo / tape / pad)
	~grainSrc !? { data[\grainSrc] = ~grainSrc.copy };
	// main_multi.scd: what the XY pads do (mapping, hold)
	~xyMap !? { data[\xyMap] = ~xyMap; data[\xyHold] = ~xyHold.asInteger };

	// Write to disk (atomically, see ~writePresetFile)
	if (~writePresetFile.(data, path)) {
		~activePreset = index;
		~presetDirty = false;
		~presetStatus = "saved to " ++ index;
		("Preset " ++ index ++ " saved to: " ++ path).postln;
	} {
		~presetStatus = "SAVE FAILED (" ++ index ++ ")";
	};
	~sendPresetSlots.();
};

// ---- Load preset ----
// Reads from disk → sets ccBuses + toggle states → sends all values to TouchOSC
// Returns true if the preset was loaded (false: missing or damaged).
~loadPreset = { |index|
	var path = ~presetPath.(index);
	var data = ~readPresetData.(path);
	var presetLen;

	if (data.notNil) {

		// Restore fader values
		data[\faders].keysValuesDo { |busIdx, val|
			~ccBuses.setAt(busIdx.asInteger, val.asFloat);
		};

		// Apply master volume to synth arg directly (CC bus read alone is not enough)
		~setMasterVol.(data[\faders][~busNames[\masterVol].index] ? 1.0);

		// Parameters that are not read from the CC buses (main_multi.scd: the cembalo)
		~onPresetFaders !? { ~onPresetFaders.(data[\faders]) };

		// Restore toggle states
		~recState      = (data[\recState] ? 0).asBoolean;
		~liveMode      = (data[\liveMode] ? 0).asBoolean;
		~reverseState  = data[\reverseState].asBoolean;
		~fixedPosState = data[\fixedPosState].asBoolean;
		~fftFreezeState   = (data[\fftFreezeState] ? data[\muteState] ? 0).asBoolean;
		~densFromDurState = (data[\densFromDurState] ? 0).asBoolean;
		~currentRate      = data[\currentRate] ? 1.0;
		~pitchTrackMode   = (data[\pitchTrackMode] ? 0).asBoolean;
		~ptRateScale      = data[\ptRateScale]    ? 0.0;
		~ptFixedPosSec    = data[\ptFixedPosSec]  ? 0.0;
		~samplePath       = data[\samplePath];

		// Apply toggle states to synths
		if (~setRecording.notNil) {
			// main_multi.scd: REC is the only recorder switch; older presets kept "Live Mode" separately
			~setRecording.(~recState or: { ~liveMode });
		} {
			~rec.set(\recGate, ~recState.asInteger);
			if (~liveMode) { ~startLiveMode.() } { ~stopLiveMode.() };
		};
		~g.set(\reverseGrain, ~reverseState.asInteger);
		~g.set(\fixedPos, ~fixedPosState.asInteger);
		~ccBuses.setAt(~busNames[\fftFreeze].index, ~fftFreezeState.asInteger.asFloat);
		~g.set(\densFromDurMode, ~densFromDurState.asInteger);
		~g.set(\rate, ~currentRate);
		~g.set(\pitchTrackMode, ~pitchTrackMode.asInteger,
		       \ptRateScale,    ~ptRateScale,
		       \fixedPosSec,    ~ptFixedPosSec);
		if (~pitchTrackMode) { ~g.set(\fixedPos, 1) };
		// a sample that is gone (deleted, other machine) must not stop the preset from loading
		if (~samplePath.notNil and: { File.exists(~samplePath) }) { ~loadBuffer.(~samplePath) };
		// main_multi.scd: grain input sources (presets saved before this existed keep the current ones)
		if (data[\grainSrc].notNil and: { ~grainSrc.notNil }) {
			data[\grainSrc].keysValuesDo { |k, v| if (~grainSrc.includesKey(k)) { ~grainSrc[k] = v } };
			~updateChains !? { ~updateChains.() };
		};

		// main_multi.scd: XY mapping and hold (presets saved before they existed keep the current ones)
		if (~setXYMap.notNil) {
			data[\xyMap] !? { |name| ~setXYMap.(name) };
			data[\xyHold] !? { |on| ~setXYHold.(on.asBoolean) };
		};

		// Reallocate the buffer if the stored length differs (a new buffer is empty: the same length keeps
		// the recorded loop). After the toggle states, so the recording state is already restored.
		presetLen = (data[\faders][~busNames[\bufferLen].index] ? 0.5).linlin(0.0, 1.0, 0.1, 8.0);
		if ((presetLen - ~bufferDurSec).abs > 0.001) { ~allocBuffer.(presetLen) };

		~activePreset = index;
		~presetDirty = false;
		~presetStatus = "loaded " ++ index;
		("Preset " ++ index ++ " loaded.").postln;

		// Send entire state to TouchOSC (faders + toggles + slot indicators).
		// Pass the preset's values: the buses were only just set and cannot be read back yet.
		~sendAllState.(data[\faders]);
		true
	} {
		~presetStatus = "slot " ++ index ++ if(File.exists(path), " is damaged", " is empty");
		("Preset " ++ index ++ " " ++ if(File.exists(path), "is damaged, not loaded.", "does not exist.")).postln;
		~sendPresetSlots !? { ~sendPresetSlots.() };
		false
	};
};

// ---- Next stored preset (footswitch) ----
// Steps through the occupied slots 0..15 in order, wrapping around; starts at the lowest one.
// A damaged preset is skipped (the next one is tried).
~loadNextPreset = {
	var used = (0..15).select { |i| ~presetExists.(i) };
	var start = used.detect { |i| i > ~activePreset } ? used.first;
	if (used.isEmpty) {
		"No presets stored.".postln;
	} {
		used = used.rotate(used.indexOf(start).neg);  // start, the ones after it, then the ones before
		used.detect { |i| ~loadPreset.(i) } ?? { "No preset could be loaded.".warn };
	};
};

// ---- Delete preset ----
~deletePreset = { |index|
	var path = ~presetPath.(index);

	if (File.exists(path)) {
		File.delete(path);
		if (~activePreset == index) { ~activePreset = -1 };
		~presetStatus = "deleted " ++ index;
		("Preset " ++ index ++ " deleted.").postln;
	} {
		~presetStatus = "slot " ++ index ++ " is empty";
		("Preset " ++ index ++ " not found.").postln;
	};
	~sendPresetSlots.();
};

// ---- OSC responders for presets ----

// ---- Preset page: slot grid + arm buttons ----
// Tap a slot: load it (tapping the active slot again reloads it, i.e. undoes your changes).
// SAVE / DELETE arm the next tap: tap SAVE (lights up), then a slot. They switch off after one tap, and tapping
// an arm button again cancels. The slot buttons are push buttons, so a tap on the same slot always arrives.
~setPresetMode = { |mode|
	~presetMode = mode;
	~presetStatus = switch (mode,
		\save,   { "SAVE: tap a slot" },
		\delete, { "DELETE: tap a slot" },
		{ "tap a slot to load" });
	~sendPresetSlots.();
};

16.do { |i|
	var addr = "/preset/tap/" ++ i;
	OSCdef(addr.asSymbol, { |msg|
		if (msg[1] >= 0.5) {
			var mode = ~presetMode;
			~presetMode = \load;  // an armed action applies to one tap only
			switch (mode,
				\save,   { ~savePreset.(i) },
				\delete, { ~deletePreset.(i) },
				{ ~loadPreset.(i) });
			~sendPresetSlots.();
		} {
			// release: the push button has gone dark on the tablet; light it again if it is the active slot
			~sendToTouchOSC.(addr, (i == ~activePreset).asInteger.asFloat);
		};
	}, addr);
};

OSCdef('/preset/saveArm', { |msg|
	~setPresetMode.(if (msg[1] >= 0.5) { \save } { \load });
}, "/preset/saveArm");

OSCdef('/preset/deleteArm', { |msg|
	~setPresetMode.(if (msg[1] >= 0.5) { \delete } { \load });
}, "/preset/deleteArm");

// ---- "changed since loaded" marker (PRESET 3 *) ----
// Any value the tablet changes that a preset stores marks the preset as changed. Gestures that are not stored
// (XY pads, sample loading, stop) and the footswitch / expression pedal do not.
~presetDirtyIgnore = ["/grain/xy/", "/grain/loadSample", "/grain/deleteBuffer", "/grain/stopAudio"];
~presetDirtyPrefixes = ["/grain/", "/tape/", "/cembalo/", "/pad/", "/master/"];
~presetDirtyWatcher !? { thisProcess.removeOSCRecvFunc(~presetDirtyWatcher) };
~presetDirtyWatcher = { |msg, time, addr|
	var a;
	if (~presetDirty.not) {
		a = msg[0].asString;
		if (~presetDirtyPrefixes.any { |p| a.beginsWith(p) } and: { ~presetDirtyIgnore.every { |p| a.beginsWith(p).not } }) {
			~presetDirty = true;
			~sendPresetName.();
		};
	};
};
thisProcess.addOSCRecvFunc(~presetDirtyWatcher);

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
