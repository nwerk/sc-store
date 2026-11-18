(
Platform.case(
	\linux, {
		// SC_SERVER=supernova (environment, see run-sc-main_multi.sh): supernova instead of scsynth. It computes
		// ParGroups on several CPU cores (the patch puts its independent chains and voices into ParGroups); scsynth
		// computes everything on one core and treats a ParGroup like a Group. Falls back to scsynth if supernova is
		// not installed (package supercollider-supernova).
		var want = "SC_SERVER".getenv ? "scsynth";
		var haveSupernova = "command -v supernova".unixCmdGetStdOut.size > 0;
		if (want == "supernova" and: { haveSupernova }) { Server.supernova } { Server.scsynth };
		if (want == "supernova" and: { haveSupernova.not }) {
			"SC_SERVER=supernova, but supernova is not installed (sudo apt install supercollider-supernova): using scsynth".warn;
		};
		("Running Linux SuperCollider script (server: " ++ Server.program.basename ++ ")...").postln;
		s.quit;
		s.options.sampleRate = 48000;
		s.options.blockSize = 64;
		// scsynth: the name of its JACK client. supernova reads the same option as the name of the JACK *server* to
		// connect to ("Unable to connect to JACK server"), so it stays empty there (the default server).
		s.options.device = if (Server.program.contains("supernova")) { nil } { "JackDriver" };
		// supernova's DSP threads (main + helpers). On the Pi 4 one of its 4 cores stays for the pitch tracker and the
		// system; elsewhere supernova's default (one per core).
		if (File.exists("/usr/local/pisound/scripts/common/common.sh")) { s.options.threads = 3 };
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