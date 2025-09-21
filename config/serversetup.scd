(
Platform.case(
	\linux, {
		"Running Linux SuperCollider script...".postln;
		s.quit;
		s.options.sampleRate = 48000;
		s.options.blockSize = 64;
		s.options.device = "JackDriver";
		s.boot;
	},
	\windows, {
		"Running Windows SuperCollider script...".postln;
		s.quit;
		s.options.sampleRate = 48000;
		s.options.blockSize = 8;
		s.options.device = "Focusrite USB ASIO";
		s.boot;
	},
	{
		"Unknown OS - no script executed.".warn;
	}
);
)