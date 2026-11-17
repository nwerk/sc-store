// Where the string was plucked: near the bridge (thin, bright) or towards the neck (round, dull).
// Used by the cembalo (synths/cembalo.scd) and the tape synth (\apePoly, synths/tapeemulate.scd).
//
// What is measured is the brightness of the guitar signal, not the position itself: the "RMS frequency" of the
// last few ms, sqrt(energy of the differentiated signal / energy of the signal), a spectral centroid that needs
// no FFT. A pluck near the bridge has stronger high harmonics, so it reads higher. The same happens with a
// harder pick, a sharper pick angle or the guitar's tone knob: all of them move the value like the picking hand.
//
// Cost: 7 audio-rate UGens on the mono input, once per synth that uses it. It runs beside the audio path and
// only steers parameters, so it adds no latency. Measured with offline renders (laptop): the tape synth takes
// about 4 % longer, a dense cembalo passage about 2 % (within the measurement's noise).
//
// Calibration (the same three numbers for both synths, see ~setPluckCal in main_multi.scd):
//   ref    brightness in Hz of a 220 Hz note picked in the usual place (= position 0)
//   track  how much brighter higher notes are anyway: brightness ~ (freq / 220) ** track
//   span   octaves of brightness from the usual place to "fully at the bridge" (+1) / "fully at the neck" (-1)
// ~cembalo.monitor(true) posts the brightness of every note for finding ref and span on a new guitar.
// The defaults come from a simulated pickup signal, not from a real guitar: expect to set ref and span once.
//
// Limits: the reading needs about one period of the note. The tracker reports a note about 10 ms after the
// pick, which is enough from the D string upwards; on the low E and A strings a very early note-on can misread.
// Notes that start without a pick (hammer-ons, slides) read as dull, i.e. towards the neck.
(
// x: guitar signal (audio rate)  ->  brightness in Hz (control rate)
~pluckBrightness = { |x|
	var sig = LPF.ar(HPF.ar(x, 70), 5000);  // without hum / DC and without hiss above the guitar's range
	var energy = A2K.kr(Lag.ar(sig.squared, 0.03));                // time constant about 4 ms
	var slope = A2K.kr(Lag.ar(HPZ1.ar(sig).squared, 0.03));        // HPZ1: gain sin(pi f / sr)
	((slope / energy.max(1e-12)).sqrt * SampleRate.ir / pi).clip(50, 8000)
};

// brightness (Hz) of a note of frequency freq  ->  position -1 (neck) .. 0 (usual place) .. +1 (bridge)
~pluckPosition = { |bright, freq, ref=800, track=0.5, span=0.75|
	((bright / (ref * ((freq.max(20) / 220) ** track))).log2 / span.max(0.05)).clip(-1, 1)
};
)
