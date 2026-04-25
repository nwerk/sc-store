~busNames = (
    param1:   ( index:1 ), // knob ch1
    param2:   ( index:2 ), // knob ch2
    param3:   ( index:3 ), // knob ch3
    param4:   ( index:4 ), // knob ch4
    param5:   ( index:5 ), // knob ch2 (bank 2)
    param6:   ( index:6 ), // knob ch6
    param7:   ( index:7 ), // knob ch7
    param8:   ( index:8 ), // knob ch8
    param9:   ( index:9 ),
    param10:  ( index:10 ),
    param11:  ( index:11 ),
    param12:  ( index:12 ),
    param13:  ( index:13 ),
    param14:  ( index:14 ),
    param15:  ( index:15 ),
    bufferLen:( index:16 ), // CC 16: Buffer Length (PD: ÷127 × 8000 ms)
    density:  ( index:17 ), // CC 17: Playhead Speed / Density (PD: ÷127 × 800 ms interval)
    randomOctave: ( index:18 ), // CC 18: Random Octave (PD: ÷127 × 4, int)
    param19:  ( index:19 ), // fader ch1
    rate:     ( index:20 ), // CC 20: Grain Pitch (PD: ÷127 × 3 + 0.0625)
    baseDur:  ( index:21 ), // CC 21: Grain Duration (PD: ÷127 × 1000 ms)
    jitter:   ( index:22 ), // CC 22: Jitter (PD: ÷127 × 3000 samples)
    param23:  ( index:23 ), // fader ch2
    playheadRand: ( index:24 ), // CC 24: Playhead Randomize (PD: ÷127 × 300)
    randDetune:   ( index:26 ), // CC 26: Rand Detune (PD: ÷127 × 100)
    param27:  ( index:27 ), // fader ch3
    param28:  ( index:28 ),
    param29:  ( index:29 ), // knob ch8 (bank 2)
    param30:  ( index:30 ),
    param31:  ( index:31 ), // fader ch4
    param32:  ( index:32 ),
    param33:  ( index:33 ),
    param34:  ( index:34 ),
    param35:  ( index:35 ), // fader ch5
    param36:  ( index:36 ),
    param37:  ( index:37 ),
    param38:  ( index:38 ),
    param39:  ( index:39 ), // fader ch6
    param40:  ( index:40 ),
    param41:  ( index:41 ),
    param42:  ( index:42 ),
    param43:  ( index:43 ), // fader ch7
    param44:  ( index:44 ),
    param45:  ( index:45 ),
    feedback: ( index:46 ), // CC 46: Feedback (PD: raw 0–1)
    param47:  ( index:47 ), // fader ch8
    param48:  ( index:48 ),
    param49:  ( index:49 ),
    octaveGroups: ( index:50 ), // CC 50: Octave Groups (PD: ÷127 × 50)
    param51:  ( index:51 ),
    param52:  ( index:52 ),
    param53:  ( index:53 ),
    bitDepth: ( index:54 ), // CC 54: Bit Depth (PD: val + 0.05)
    playbackSpeed: ( index:55 ), // CC 55: Playback Speed (PD: ÷127 × 3 + 0.0625)
    param56:  ( index:56 ),
    param57:  ( index:57 ),
    freqModAmt:  ( index:58 ), // CC 58: Freq Mod Amount (PD: ÷127 × 50)
    freqModFreq: ( index:59 ), // CC 59: Freq Mod Freq (PD: ÷127 × 5 Hz)
    panRand:  ( index:60 ), // CC 60: Panning Amount (PD: 0–1)
    param61:  ( index:61 ),
    masterVol:( index:62 ), // CC 62: Master Volume (PD: 0–1)
    param63:  ( index:63 ),
    param64:  ( index:64 ),
    param65:  ( index:65 ),
    param66:  ( index:66 ),
    param67:  ( index:67 ),
    param68:  ( index:68 ),
    param69:  ( index:69 ),
    param70:  ( index:70 ),
    param71:  ( index:71 ),
    param72:  ( index:72 ),
    param73:  ( index:73 ),
    param74:  ( index:74 ),
    param75:  ( index:75 ),
    param76:  ( index:76 ),
    param77:  ( index:77 ),
    param78:  ( index:78 ),
    param79:  ( index:79 ),
    master_vol:  ( index:80, isLatch:true ), // CC 80: Live Mode Select / Master Mute (PD: sel 3, latch)
    param81:  ( index:81 ), // Boss FS-1-WH footswitch 2
    param82:  ( index:82 ), // Boss FS-1-WH footswitch 3
    param83:  ( index:83 ), // Boss FS-1-WH footswitch 4
    param84:  ( index:84 ), // Boss FS-1-WH expression pedal
    param85:  ( index:85 ),
    param86:  ( index:86 ),
    param87:  ( index:87 ),
    param88:  ( index:88 ),
    param89:  ( index:89 ),
    param90:  ( index:90 ),
    param91:  ( index:91 ),
    param92:  ( index:92 ),
    param93:  ( index:93 ),
    param94:  ( index:94 ),
    param95:  ( index:95 ),
    param96:  ( index:96 ),
    param97:  ( index:97 ),
    param98:  ( index:98 ),
    param99:  ( index:99 ),
    param100: ( index:100 ),
    param101: ( index:101 ),
    param102: ( index:102 ),
    param103: ( index:103 ),
    param104: ( index:104 ),
    param105: ( index:105 ),
    param106: ( index:106 ),
    param107: ( index:107 ),
    param108: ( index:108 ),
    param109: ( index:109 ),
    param110: ( index:110 ),
    param111: ( index:111 ),
    param112: ( index:112 ),
    param113: ( index:113 ),
    param114: ( index:114 ),
    param115: ( index:115 ),
    param116: ( index:116 ),
    param117: ( index:117 ),
    param118: ( index:118 ),
    param119: ( index:119 ),
    param120: ( index:120 ),
    param121: ( index:121 ),
    param122: ( index:122 ),
    param123: ( index:123 ),
    param124: ( index:124 ),
    param125: ( index:125 ),
    param126: ( index:126 ),
    param127: ( index:127 ),
    param128: ( index:128 )
);
