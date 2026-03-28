(
// Multi-touch voice management for Kaoss Pad
// TouchOSC sends: /kaoss/touch [int:touchIndex, float:x, float:y, float:z]
// z=1 on touch down/move, z=0 on touch up

~kaossVoices = Dictionary.new;

OSCdef(\kaossTouch, { |msg|
	var touchIdx = msg[1].asInteger;
	var x = msg[2].asFloat;
	var y = msg[3].asFloat;
	var z = msg[4].asFloat;

	if (z > 0) {
		// Touch down or move
		if (~kaossVoices[touchIdx].notNil) {
			// Update existing voice position and window
			~kaossVoices[touchIdx].set(\padX, x, \padY, y);
		} {
			// Spawn new voice
			~kaossVoices[touchIdx] = Synth(\kaossVoice, [
				\out, 0,
				\buf, ~loopBuf,
				\padX, x,
				\padY, y,
				\gate, 1,
				\ccBus, ~ccBuses,
				\amp, 0.5
			]);
			("Kaoss voice " ++ touchIdx ++ " spawned").postln;
		};
	} {
		// Touch up — release voice
		if (~kaossVoices[touchIdx].notNil) {
			~kaossVoices[touchIdx].set(\gate, 0);
			~kaossVoices.removeAt(touchIdx);
			("Kaoss voice " ++ touchIdx ++ " released").postln;
		};
	};
}, '/kaoss/touch');

// Volume control from TouchOSC fader
OSCdef(\kaossVol, { |msg|
	~ccBuses.setAt(~busNames[\kaoss_vol][\index], msg[1].asFloat);
}, '/kaoss/vol');

"OSC config for Kaoss Pad loaded!".postln;
)
