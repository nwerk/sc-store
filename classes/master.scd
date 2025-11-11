SynthDef(\master, { |out=0, inBus=0, ampBus=0, ccBus=0|
    var ccVals = In.kr(ccBus, 128);
    var amp = Select.kr(~busNames[\master_vol].index, ccVals).lag(0.05);
    var sig = In.ar(inBus, 2);

    sig = sig * amp;

    Out.ar(out, sig);
}).add;