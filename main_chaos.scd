(
Server.killAll;

//////// CONFIGURATION ///////////////////
// Edit these two lines to match your setup:
~touchOSCAddr = NetAddr("192.168.1.100", 9000);  // IP of TouchOSC device, SC-receive port in TouchOSC
~chaosDataPath = Platform.userAppSupportDir +/+ "chaos_data";

//////// IMPORTS ///////////////////
~basePath = PathName(thisProcess.nowExecutingPath).pathOnly;
thisProcess.interpreter.executeFile(~basePath ++ "config/serversetup.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/mappings/chaos_regressor_midi.scd");
thisProcess.interpreter.executeFile(~basePath ++ "midi/midiconfig.scd");
thisProcess.interpreter.executeFile(~basePath ++ "synths/chaos_regressor.scd");
thisProcess.interpreter.executeFile(~basePath ++ "osc/chaos_osc.scd");

s.waitForBoot {
	// FluCoMa buffers and datasets are created by chaos_regressor.scd above.
	// Instantiate the synth and store the reference for OSC/MIDI control.
	~chaosSynth = Synth(\chaosRegressor);
	"Synth \\chaosRegressor created!".postln;
	"TouchOSC: set Send Port to % in TouchOSC settings.".format(NetAddr.langPort).postln;
}
)
