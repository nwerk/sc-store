// Polyphonic guitar pitch tracker (replaces the old Tartini-based tracker).
//
// A small neural network runs in an external Python process (tracker/polytracker, numpy only, ~9 % of one
// laptop core at a 5.3 ms hop; measure your Pi with `python -m polytracker bench`). At startup it measures the
// machine and picks a 5.3 ms hop, or 10.7 ms if the CPU cannot keep up comfortably (`hop:` option). It listens to
// the guitar through its own JACK input and writes its results straight into a block of control buses on
// scsynth (OSC /c_setn) - sclang is not in the audio path.
// Note on/off events are additionally sent to sclang (/polytracker/noteOn, /polytracker/noteOff).
//
// Bus block layout (control buses starting at tracker.block.index, see tracker/polytracker/outputs.py):
//   +0 mono freq (Hz, 0 = none)  +1 mono amp  +2 number of sounding notes  +3 heartbeat
//   +4 .. +9  voice freq (Hz)    +10 .. +15 voice amp (0..1)    +16 .. +21 voice gate (0/1)
//
// Usage (inside s.waitForBoot):
//   ~tracker = ~polyTrackerNew.(s, (inChan: 0, freqBus: ~freqBus, ampBus: ~ampBus)).start;
//   ~tracker.onNoteOn  = { |voice, midi, freq, amp| ... };
//   ~tracker.onNoteOff = { |voice, midi| ... };
//   In.kr(~tracker.voiceFreqBus.index, 6)   // all voice frequencies in a SynthDef
//   ~tracker.set(\monoMode, \lowest);       // latest | lowest | highest | loudest (also: on, off, onset, gate_db, ...)
//   ~tracker.run(false);  ~tracker.run(true) // pause / resume (also stops the Python analysis: no CPU)
//   ~tracker.quit;                          // NOT .stop: Object:stop exists and would silently do nothing
//
// The tracker object is an Environment with know=true (not an Event: Event already defines .set/.stop/.synth).
//
// The old \tartiniTracker_sigmundStyle SynthDef is kept as an alias of \polyTracker with the same
// arguments, so existing patches keep working; it now needs polyBus to be set (the factory does that).
(
~polyTrackerVoices = 6;
~polyTrackerHeader = 4;
~polyTrackerBlockSize = ~polyTrackerHeader + (3 * ~polyTrackerVoices);
~polyTrackerHome = if(thisProcess.nowExecutingPath.notNil) {
	PathName(thisProcess.nowExecutingPath).pathOnly +/+ "../tracker"
} {
	if(~basePath.notNil) { ~basePath +/+ "tracker" } { nil }
};

// ---- audio-side part: amplitude, onsets (zero latency) + smoothing of the tracker's mono pitch ----
~polyTrackerGraph = { |inChan=0, polyBus=0, freqBus=0, ampBus=1, lagAmpBus=2, trigBus=3, ampAvgWindowSec=10,
	inGain=2.0, hpFreq=5, lpFreq=2000, execFreq=60,
	ampMapMax=0.08, lagTime=0.03, gateThreshold=0.03, holdLast=0,  // holdLast: 0 = pitch drops to 0 when no note sounds; 1 = hold the last note's pitch
	onsetThreshold=0.5, onsetType=3|  // onsetType: 0=power, 1=magsum, 2=complex, 3=rcomplex, 4=phase, 5=wphase, 6=mkl
	var sig, pre, ampRMS, ampMapped;
	var trk, alive, freqRaw, valid, trigValid, freqLatched;
	var freqSm_base, freqSm_hold, freqOut, ampSm;
	var nSamp, lagAmpSm;
	var fft, onsetTrig;

	sig = SoundIn.ar(inChan) * inGain;
	pre = HPF.ar(sig, hpFreq);              // remove subsonic noise
	pre = LPF.ar(pre, lpFreq);
	ampRMS = Amplitude.kr(pre, 0.01, 0.01); // robust RMS measure
	ampMapped = ampRMS.linlin(0.0, ampMapMax, 0.0, 1.0).clip(0, 1);

	// Transient/onset detection using FFT + Onsets
	fft = FFT(LocalBuf(512), pre);
	onsetTrig = Onsets.kr(fft, onsetThreshold, onsetType);

	// Mono pitch from the neural tracker; a silent heartbeat (tracker crashed/stopped) counts as "no pitch"
	trk = In.kr(polyBus, 4);
	alive = Sweep.kr(Changed.kr(trk[3]), 1) < 0.5;
	freqRaw = trk[0] * alive;

	// Hold-last path: latch the most recent valid frequency at exec rate
	valid = (freqRaw > 0) * (ampMapped > gateThreshold);
	trigValid   = Impulse.kr(execFreq) * valid;
	freqLatched = Latch.kr(freqRaw, trigValid);

	// smoothing
	freqSm_base = Lag.kr(freqRaw,     lagTime);   // no hold
	freqSm_hold = Lag.kr(freqLatched, lagTime);   // hold-last behaviour
	freqOut     = Select.kr(holdLast.clip(0,1), [freqSm_base, freqSm_hold]);

	ampSm  = Lag.kr(ampMapped, lagTime);
	// 10s moving average (boxcar) at control rate
	nSamp = (ampAvgWindowSec.max(0.001) * ControlRate.ir);
	lagAmpSm = (RunningSum.kr(ampMapped, nSamp) / nSamp).clip(0, 1);

	Out.kr(freqBus, freqOut);
	Out.kr(ampBus,  ampSm);
	Out.kr(lagAmpBus,  lagAmpSm);
	Out.kr(trigBus, onsetTrig);  // 1 on transient, 0 otherwise

	// Send OSC message on transient with freq and amp
	SendReply.kr(onsetTrig, '/transient', [freqOut, ampSm]);
};
SynthDef(\polyTracker, ~polyTrackerGraph).add;
SynthDef(\tartiniTracker_sigmundStyle, ~polyTrackerGraph).add;  // legacy name, same arguments

// ---- language-side part: buses, Python process, events ----
~polyTrackerNew = { |server, opts|
	var t = Environment.new(know: true);  // not Event: Event already defines .set, .stop and .synth
	var o = (
		inChan: 0,
		voices: ~polyTrackerVoices,
		freqBus: nil, ampBus: nil, lagAmpBus: nil, trigBus: nil,  // Bus objects; nil = allocate
		target: nil, addAction: \addToTail,
		synthArgs: [],                       // extra \polyTracker args, e.g. [\holdLast, 1]
		autoLaunch: (thisProcess.platform.name == \linux),
		home: ~polyTrackerHome,              // tracker/ directory
		python: nil,                         // default: tracker/.venv/bin/python, then python3
		model: nil,                          // default: tracker/models/guitar_v1.npz
		jackPort: nil,                       // default: system:capture_<inChan+1>
		monoMode: \latest, controlPort: 57150, cpu: nil, rtPriority: 50,
		hop: \auto,                          // \auto (measure at startup), 256 (5.3 ms) or 512 (10.7 ms, half the CPU)
		decoderArgs: "",                     // extra command line, e.g. "--on 0.6 --gate-db -70"
		verbose: false
	);
	opts !? { opts.keysValuesDo { |k, v| o[k] = v } };

	t[\server] = server;
	t[\opts] = o;
	t[\held] = Dictionary.new;
	t[\onNoteOn] = nil;
	t[\onNoteOff] = nil;
	t[\running] = false;
	t[\lastSeen] = 0;
	t[\load] = 0;
	t[\ownedBuses] = List.new;
	t[\settings] = IdentityDictionary.new;  // replayed to the Python process when it reports ready (UDP sent earlier is lost)

	t[\voiceFreqBus] = { |self| Bus.new(\control, self[\block].index + ~polyTrackerHeader, ~polyTrackerVoices, self[\server]) };
	t[\voiceAmpBus]  = { |self| Bus.new(\control, self[\block].index + ~polyTrackerHeader + ~polyTrackerVoices, ~polyTrackerVoices, self[\server]) };
	t[\voiceGateBus] = { |self| Bus.new(\control, self[\block].index + ~polyTrackerHeader + (2 * ~polyTrackerVoices), ~polyTrackerVoices, self[\server]) };
	t[\freqBus]    = { |self| self[\opts][\freqBus] };
	t[\ampBus]     = { |self| self[\opts][\ampBus] };
	t[\lagAmpBus]  = { |self| self[\opts][\lagAmpBus] };
	t[\trigBus]    = { |self| self[\opts][\trigBus] };
	t[\numActive]  = { |self| self[\held].size };
	t[\heldNotes]  = { |self| self[\held].keys.asArray.sort.collect { |v| self[\held][v] } };

	t[\command] = { |self|
		var o = self[\opts], s = self[\server];
		// Absolute paths: the command cd's into home before exec'ing python, so paths relative to sclang's working
		// directory (e.g. after `sclang main_multi.scd`) would no longer resolve. No realpath on python: resolving
		// the .venv/bin/python symlink would bypass the virtualenv.
		var abs = { |p| if(p.notNil and: { p[0] != $/ } and: { p.contains("/") }) { File.getcwd +/+ p } { p } };
		var home = abs.(o[\home]), py = abs.(o[\python] ? (home +/+ ".venv/bin/python"));
		var cmd;
		if(File.exists(py).not) { py = "python3" };
		cmd = "cd % && exec % -m polytracker run --input % --scsynth 127.0.0.1:% --lang 127.0.0.1:% --bus % --voices % --control-port % --mono-mode % --parent-pid %".format(
			home.shellQuote, py.shellQuote,
			(o[\jackPort] ? ("system:capture_" ++ (o[\inChan] + 1))).shellQuote,
			s.addr.port, NetAddr.langPort, self[\block].index, o[\voices], o[\controlPort], o[\monoMode], thisProcess.pid);
		o[\model] !? { cmd = cmd ++ " --model " ++ o[\model].shellQuote };
		o[\cpu] !? { cmd = cmd ++ " --cpu " ++ o[\cpu] };
		cmd = cmd ++ " --rt-priority " ++ o[\rtPriority] ++ " --hop " ++ o[\hop];
		if(o[\verbose]) { cmd = cmd ++ " --verbose" };
		cmd ++ " " ++ o[\decoderArgs]
	};

	t[\makeSynth] = { |self|
		var o = self[\opts];
		self[\synth] = Synth(\polyTracker, [
			\inChan, o[\inChan], \polyBus, self[\block].index,
			\freqBus, o[\freqBus].index, \ampBus, o[\ampBus].index,
			\lagAmpBus, o[\lagAmpBus].index, \trigBus, o[\trigBus].index
		] ++ o[\synthArgs], o[\target] ? self[\server].defaultGroup, o[\addAction]);
	};

	t[\panic] = { |self|
		self[\block].setn(Array.fill(~polyTrackerBlockSize, 0));
		self[\held].keysValuesDo { |v, h| self[\onNoteOff].value(v, h[\midi]) };
		self[\held].clear;
	};

	t[\set] = { |self, name, value|
		var v = if(value.isKindOf(Symbol)) { value.asString } { value };
		self[\settings][name.asSymbol] = v;
		NetAddr("127.0.0.1", self[\opts][\controlPort]).sendMsg("/polytracker/set", name.asString, v);
		self
	};

	// Pause/resume like Synth.run: stops the audio-side synth and the Python analysis (saves CPU)
	t[\run] = { |self, flag = true|
		self[\synth] !? { self[\synth].run(flag) };
		if(self[\opts][\autoLaunch]) { self[\set].value(self, \pause, flag.not.binaryValue) };
		self
	};

	t[\start] = { |self|
		var o = self[\opts], s = self[\server], me = self;
		if(self[\running].not) {
			if(s.serverRunning.not) { Error("polyTracker: boot the server first (call .start inside s.waitForBoot)").throw };
			self[\block] = Bus.control(s, ~polyTrackerBlockSize);
			self[\block].setn(Array.fill(~polyTrackerBlockSize, 0));
			[\freqBus, \ampBus, \lagAmpBus, \trigBus].do { |k|
				if(o[k].isNil) { o[k] = Bus.control(s, 1); self[\ownedBuses].add(o[k]) };
			};
			self[\makeSynth].value(self);

			OSCdef(\polyTracker_noteOn, { |msg|
				var v = msg[1].asInteger, h = (midi: msg[2].asInteger, freq: msg[3], amp: msg[4]);
				me[\held][v] = h;
				me[\onNoteOn].value(v, h[\midi], h[\freq], h[\amp]);
			}, '/polytracker/noteOn');
			OSCdef(\polyTracker_noteOff, { |msg|
				var v = msg[1].asInteger, midi = msg[2].asInteger;
				me[\held].removeAt(v);
				me[\onNoteOff].value(v, midi);
			}, '/polytracker/noteOff');
			OSCdef(\polyTracker_stats, { |msg|
				me[\lastSeen] = Main.elapsedTime;
				me[\load] = msg[1];
				if(o[\verbose]) {
					("polyTracker: load " ++ (msg[1] * 100).round(0.1) ++ "%, frames " ++ msg[2] ++ ", dropped " ++ msg[3] ++ ", worst " ++ msg[4].round(0.01) ++ " ms").postln;
				};
			}, '/polytracker/stats');
			OSCdef(\polyTracker_ready, { |msg|
				me[\lastSeen] = Main.elapsedTime;
				("polyTracker: ready (model " ++ msg[1] ++ ", bus " ++ msg[2] ++ ")").postln;
				me[\settings].keysValuesDo { |k, v| me[\set].value(me, k, v) };  // settings made before the process was up
			}, '/polytracker/ready');

			self[\lastSeen] = Main.elapsedTime;
			self[\running] = true;
			if(o[\autoLaunch]) {
				if(o[\home].isNil or: { File.exists(o[\home]).not }) {
					"polyTracker: tracker/ directory not found - set the 'home' option".warn;
				} {
					self[\pid] = self[\command].value(self).unixCmd({ |code, pid|
						if(me[\running]) { ("polyTracker: Python process exited with code " ++ code).warn };
					}, true);
					self[\watchdog] = Routine({
						loop {
							1.0.wait;
							if(((Main.elapsedTime - me[\lastSeen]) > 5.0) and: { me[\held].size > 0 }) {
								"polyTracker: no heartbeat, releasing notes".warn;
								me[\panic].value(me);
							};
						}
					}).play(SystemClock);
				};
			};
			self[\cmdPeriod] = {
				if(me[\running]) {
					SystemClock.sched(0.3, { me[\makeSynth].value(me); nil });
				};
			};
			CmdPeriod.add(self[\cmdPeriod]);
		};
		self
	};

	t[\quit] = { |self|
		if(self[\running]) {
			self[\running] = false;
			CmdPeriod.remove(self[\cmdPeriod]);
			self[\watchdog] !? { self[\watchdog].stop };
			if(self[\opts][\autoLaunch]) {
				NetAddr("127.0.0.1", self[\opts][\controlPort]).sendMsg("/polytracker/quit");
				self[\pid] !? { |p| SystemClock.sched(1.0, { ("kill " ++ p ++ " 2>/dev/null").unixCmd(postOutput: false); nil }) };
			};
			[\polyTracker_noteOn, \polyTracker_noteOff, \polyTracker_stats, \polyTracker_ready].do { |k| OSCdef(k).free };
			self[\synth] !? { self[\synth].free };
			self[\panic].value(self);
			self[\ownedBuses].do { |b| b.free };
			self[\ownedBuses].clear;
			self[\block].free;
		};
		self
	};
	t
};
)
