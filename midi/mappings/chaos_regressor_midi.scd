~busNames = (
    master_vol:   ( index:62 ),            // MIDI Mix master fader (master output volume)
    predict:      ( index:80, isLatch:true ), // FS-1-WL footswitch 1 — predict toggle (latching)
    addpoint:     ( index:81 ),            // FS-1-WL footswitch 2 — add training point (momentary)
    expr:         ( index:84 )             // FS-1-WL expression pedal — reserved for XY axis or param
);

// MIDI CC fallback actions for footswitches.
// These mirror the OSC responders in osc/chaos_osc.scd so the footswitch
// can be used without a tablet connected.
MIDIdef.cc(\chaosMIDIPredict, { |val, cc|
    if (cc == ~busNames[\predict][\index]) {
        // Latch state is already managed by midiconfig.scd;
        // read it back from the bus after a short delay.
        AppClock.sched(0.05, {
            ~ccBuses.get(~busNames[\predict][\index], { |v|
                defer { ~chaosSynth.set(\predicting, v) };
            });
            nil;
        });
    };
});

MIDIdef.cc(\chaosMIDIAddPoint, { |val, cc|
    if ((cc == ~busNames[\addpoint][\index]) and: { val == 127 }) {
        var id = "point-%".format(~chaosCounter);
        ~xydata.addPoint(id, ~xybuf);
        ~paramsdata.addPoint(id, ~paramsbuf);
        ~chaosCounter = ~chaosCounter + 1;
        ("MIDI: Added training point " ++ id).postln;
    };
});

"chaos_regressor_midi.scd loaded.".postln;
