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


~connect_midi_devices.("MIDI Mix", "MIDI Mix MIDI 1"); // test it now

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

"Config file loaded!".postln;
)