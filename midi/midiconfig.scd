(
s.waitForBoot {
    ~ccBuses = Bus.control(s, 128);
    ~ccBuses.setn(Array.fill(128, 0.0));

    ~latchingCCs = [79, 80, 81, 82, 83, 84];
    ~latchingStates = Array.fill(128, 0);

    MIDIClient.init;
    MIDIIn.connectAll;
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
};
)

