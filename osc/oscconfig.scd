(
// Multi-touch voice management for Kaoss Pad
// TouchOSC Multi-XY sends per-cursor per-axis messages:
//   /multixy/N/x float   (N = cursor index 1-5)
//   /multixy/N/y float
//   /multixy/N/z float   (1 = touch down, 0 = touch up)

~kaossVoices = Dictionary.new;
~kaossCursorX = Array.fill(6, 0.5); // index 0 unused, 1-5 for cursors
~kaossCursorY = Array.fill(6, 0.5);

// Register listeners for cursors 1 through 5
(1..5).do { |i|
	// X position update
	OSCdef(("kaossX" ++ i).asSymbol, { |msg|
		~kaossCursorX[i] = msg[1];
		if (~kaossVoices[i].notNil) {
			~kaossVoices[i].set(\padX, msg[1]);
		};
	}, "/multixy/" ++ i ++ "/x");

	// Y position update
	OSCdef(("kaossY" ++ i).asSymbol, { |msg|
		~kaossCursorY[i] = msg[1];
		if (~kaossVoices[i].notNil) {
			~kaossVoices[i].set(\padY, msg[1]);
		};
	}, "/multixy/" ++ i ++ "/y");

	// Z (touch state) — spawn or release voice
	OSCdef(("kaossZ" ++ i).asSymbol, { |msg|
		var z = msg[1];
		if (z > 0) {
			// Touch down — spawn voice
			if (~kaossVoices[i].isNil) {
				~kaossVoices[i] = Synth(\kaossVoice, [
					\out, 0,
					\buf, ~loopBuf,
					\padX, ~kaossCursorX[i],
					\padY, ~kaossCursorY[i],
					\gate, 1,
					\ccBus, ~ccBuses,
					\amp, 0.5
				]);
				("Kaoss voice " ++ i ++ " spawned").postln;
			};
		} {
			// Touch up — release voice
			if (~kaossVoices[i].notNil) {
				~kaossVoices[i].set(\gate, 0);
				~kaossVoices.removeAt(i);
				("Kaoss voice " ++ i ++ " released").postln;
			};
		};
	}, "/multixy/" ++ i ++ "/z");
};

// Window size slider from TouchOSC
OSCdef(\kaossWindow, { |msg|
	~ccBuses.setAt(~busNames[\kaoss_window][\index], msg[1]);
}, '/kaoss/window');

// Volume control from TouchOSC fader
OSCdef(\kaossVol, { |msg|
	~ccBuses.setAt(~busNames[\kaoss_vol][\index], msg[1]);
}, '/kaoss/vol');
OSCFunc.trace(true);

// Quantized mode toggle (harmonic minor quantization)
// OSC: send /kaoss/quant_toggle with any value to toggle
~kaossQuantizedMode = false; // global flag
OSCdef(\kaossQuantToggle, { |msg|
	~kaossQuantizedMode = ~kaossQuantizedMode.not;
	// Update all active voices immediately
	~kaossVoices.do { |voice|
		if (voice.notNil) {
			voice.set(\kaossQuantizedMode, ~kaossQuantizedMode.asInteger);
		}
	};
	("Kaoss quantized mode: " ++ ~kaossQuantizedMode).postln;
}, '/kaoss/quant_toggle');

"OSC config for Kaoss Pad loaded!".postln;
)
