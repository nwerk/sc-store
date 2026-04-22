(
~ccBuses = Bus.control(s, 128);
~ccBuses.setn(Array.fill(128, 0.0));

// get all latching CC's
~latchingCCs  = ~busNames.keys.asArray
.select { |k| (~busNames[k][\isLatch] == true) }
.collect { |k| ~busNames[k][\index] };

~latchingStates = Array.fill(128, 0);


~connect_midi_devices = { |device, name|
    // init or refresh MIDIClient end points
    if(MIDIClient.initialized == false) {
        MIDIClient.init;
    } {
        MIDIClient.list;
    };

    MIDIClient.sources.do({ |endPoint|
        if(device.notNil and: { name.notNil } and: { endPoint.device == device } and: { endPoint.name == name }) {
            // catch exception thrown when already connected
            try {
                // connect SuperCollider out port 0 to MIDI device
                MIDIOut.connect(0, endPoint.uid);
            };
            try {
                // connect MIDI device to SuperCollider in port 0
                MIDIIn.connect(0, endPoint.uid);
            }
        }
    })

};


Platform.case(
    \linux,   { ~connect_midi_devices.("FS-1-WL USB-MIDI", "FS-1-WL USB-MIDI MIDI 1"); },
    \windows, { ~connect_midi_devices.("FS-1-WL USB-MIDI", "FS-1-WL USB-MIDI"); }
);
// MIDI Mix removed — now controlled via TouchOSC over OSC.
// Uncomment the line below to re-enable MIDI Mix if needed:
// ~connect_midi_devices.("MIDI Mix", "MIDI Mix MIDI 1");

MIDIdef.trace(true);
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

// ---- Boss FS-1-WL expression pedal → master volume ----
// Deadband suppresses jitter; inline EMA smooths actual movement.
// ~expPedalLagCoeff: 0.0 = frozen, 1.0 = instant (try 0.1–0.3)
~lastExpPedalRaw  = nil;
~expPedalDeadband = 2;
~expPedalSmoothed = 1.0;
~expPedalLagCoeff = 0.15;

MIDIdef.cc(\expressionPedalMasterVol,
	{ |val, ccNum, chan, src|
		if (~lastExpPedalRaw.isNil or: { (val - ~lastExpPedalRaw).abs > ~expPedalDeadband }) {
			~lastExpPedalRaw  = val;
			~expPedalSmoothed = ~expPedalSmoothed + (~expPedalLagCoeff * (val / 127.0 - ~expPedalSmoothed));
			~setMasterVol !? { ~setMasterVol.(~expPedalSmoothed) };
		};
	},
	ccNum: 11
);

// ---- Boss FS-1-WL footswitch A (CC 80) → live mode toggle ----
MIDIdef.cc(\fs1wl_liveMode,
	{ |val, ccNum, chan, src|
		if (val == 127) {
			if (~liveMode) {
				~stopLiveMode !? { ~stopLiveMode.() };
			} {
				~startLiveMode !? { ~startLiveMode.() };
			};
			~touchOSC !? { ~touchOSC.sendMsg('/grain/liveMode', ~liveMode.asInteger.asFloat) };
		};
	},
	ccNum: 80
);

// ---- Boss FS-1-WL footswitch B (CC 81) → delete buffer ----
MIDIdef.cc(\fs1wl_deleteBuffer,
	{ |val, ccNum, chan, src|
		if (val == 127) {
			~deleteBuffer !? { ~deleteBuffer.() };
		};
        "del".poll;
	},
	ccNum: 81
);

// ---- Boss FS-1-WL footswitch C (CC 82) → FFT freeze toggle ----
MIDIdef.cc(\fs1wl_fftFreeze,
	{ |val, ccNum, chan, src|
		if (val == 127) {
			~fftFreezeState = ~fftFreezeState.not;
			~ccBuses !? { ~ccBuses.setAt(~busNames[\fftFreeze].index, ~fftFreezeState.asInteger.asFloat) };
			~touchOSC !? { ~touchOSC.sendMsg('/grain/fftFreeze', ~fftFreezeState.asInteger.asFloat) };
			("FFT Freeze: " ++ if(~fftFreezeState, "ON", "OFF")).postln;
		};
	},
	ccNum: 82
);

"Config file loaded!".postln;
)