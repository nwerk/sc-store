SynthDef(\master, { |out=0, inBus=0, ccBus=0, amp=1.0|
    var ccVals, vol, sig;
    ccVals = In.kr(ccBus, 128);
    vol = Select.kr(~busNames[\masterVol].index, ccVals);
    sig = In.ar(inBus, 2);
    sig = sig * vol.lag(0.05);
    Out.ar(out, sig);
}).add;