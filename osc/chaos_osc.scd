/*
  TouchOSC Setup:
  1. Install TouchOSC on your tablet/phone (hexler.net/touchosc)
  2. Open the layout file: osc/touchosc/chaos_regressor.tosc
  3. In TouchOSC Connection settings:
     - OSC Host: <IP of your SuperCollider machine>
     - OSC Send Port: <NetAddr.langPort printed in SC post window, usually 57120>
     - OSC Receive Port: 9000 (must match ~touchOSCAddr port in main_chaos.scd)
  4. Boot main_chaos.scd in SuperCollider
  5. Workflow:
     a. Move XY pad + adjust param faders to desired sound
     b. Tap "Add Point" to store that XY -> params mapping
     c. Repeat for multiple positions (aim for 10-30 points)
     d. Tap "Train" — wait for loss to appear in the label
     e. Toggle "Predict" ON — now the XY pad controls all 10 params via the neural network
     f. Save your model with "Save MLP" for recall later
*/

// OSC responders for TouchOSC chaos regressor control.
// Requires ~touchOSCAddr and ~chaosDataPath to be set before loading.
// Requires synths/chaos_regressor.scd to be loaded first (provides ~xybuf, ~paramsbuf, etc.)

(
// Helper: send a status string back to TouchOSC
~chaosSendStatus = { |str|
	~touchOSCAddr.sendMsg("/chaos/status", str);
};

// Helper: send current point count back to TouchOSC
~chaosSendCount = {
	~touchOSCAddr.sendMsg("/chaos/pointcount", ~chaosCounter.asString);
};

// --- XY control ---
OSCdef(\chaosXY, { |msg|
	var x = msg[1], y = msg[2];
	~xybuf.setn(0, [x, y]);
}, "/chaos/xy");

// --- Parameter faders (manual editing before adding a point) ---
10.do { |i|
	OSCdef(("chaosParam" ++ (i + 1)).asSymbol, { |msg|
		~paramsbuf.set(i, msg[1]);
	}, "/chaos/param/" ++ (i + 1));
};

// --- Add training point ---
OSCdef(\chaosAddPoint, { |msg|
	if (msg[1] > 0) {
		var id = "point-%".format(~chaosCounter);
		~xydata.addPoint(id, ~xybuf);
		~paramsdata.addPoint(id, ~paramsbuf);
		~chaosCounter = ~chaosCounter + 1;
		~chaosSendCount.value;
		~chaosSendStatus.value("Point % added".format(~chaosCounter));
		("Added training point: " ++ id).postln;
	};
}, "/chaos/addpoint");

// --- Train ---
OSCdef(\chaosTrain, { |msg|
	if (msg[1] > 0) {
		~chaosSendStatus.value("Training...");
		~mlp.fit(~xydata, ~paramsdata, { |loss|
			var lossStr = loss.round(0.0001).asString;
			defer {
				~touchOSCAddr.sendMsg("/chaos/trainloss", lossStr);
				~chaosSendStatus.value("Done. Loss: " ++ lossStr);
			};
			("Training complete. Loss: " ++ lossStr).postln;
		});
	};
}, "/chaos/train");

// --- Clear data ---
OSCdef(\chaosClearData, { |msg|
	if (msg[1] > 0) {
		~xydata.clear;
		~paramsdata.clear;
		~chaosCounter = 0;
		~chaosSendCount.value;
		~chaosSendStatus.value("Cleared");
		"Training data cleared.".postln;
	};
}, "/chaos/cleardata");

// --- Save data ---
OSCdef(\chaosSaveData, { |msg|
	if (msg[1] > 0) {
		var dir = ~chaosDataPath;
		if (File.exists(dir).not) { File.mkdir(dir) };
		~xydata.write(dir +/+ "xydata.json");
		~paramsdata.write(dir +/+ "paramsdata.json");
		~chaosSendStatus.value("Data saved");
		("Saved data to: " ++ dir).postln;
	};
}, "/chaos/savedata");

// --- Load data ---
OSCdef(\chaosLoadData, { |msg|
	if (msg[1] > 0) {
		var dir = ~chaosDataPath;
		~xydata.read(dir +/+ "xydata.json");
		~paramsdata.read(dir +/+ "paramsdata.json");
		// Update counter from dataset size after a short delay for server round-trip
		AppClock.sched(0.5, {
			~xydata.size({ |sz|
				defer {
					~chaosCounter = sz;
					~chaosSendCount.value;
					~chaosSendStatus.value("Data loaded (% pts)".format(sz));
				};
			});
			nil;
		});
		("Loaded data from: " ++ dir).postln;
	};
}, "/chaos/loaddata");

// --- Save MLP ---
OSCdef(\chaosSaveMLP, { |msg|
	if (msg[1] > 0) {
		var dir = ~chaosDataPath;
		if (File.exists(dir).not) { File.mkdir(dir) };
		~mlp.write(dir +/+ "chaos_mlp.json");
		~chaosSendStatus.value("MLP saved");
		("Saved MLP to: " ++ dir).postln;
	};
}, "/chaos/savemlp");

// --- Load MLP ---
OSCdef(\chaosLoadMLP, { |msg|
	if (msg[1] > 0) {
		~mlp.read(~chaosDataPath +/+ "chaos_mlp.json");
		~chaosSendStatus.value("MLP loaded");
		"MLP loaded.".postln;
	};
}, "/chaos/loadmlp");

// --- Predict toggle ---
OSCdef(\chaosPredict, { |msg|
	var val = msg[1];
	~chaosSynth.set(\predicting, val);
	("Predict: " ++ if(val > 0, "ON", "OFF")).postln;
}, "/chaos/predict");

// --- Feedback: send predicted params back to TouchOSC faders ---
OSCdef(\paramsChanged, { |msg|
	10.do { |i|
		~touchOSCAddr.sendMsg("/chaos/param/" ++ (i + 1), msg[3 + i]);
	};
}, "/paramsChanged");

"chaos_osc.scd loaded. SC listening on port: %".format(NetAddr.langPort).postln;
)
