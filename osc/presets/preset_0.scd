var o, p;
o = [
	Dictionary.prNew,  Array.prNew(32),  Dictionary.prNew,  Array.prNew(128)
];
p = [
	// Dictionary
	0, [ array: o[1],  size: 7 ],  
	// Array
	1, [ nil,  nil,  nil,  nil,  
		nil,  nil,  'faders',  o[2],  
		'recState',  0,  'muteState',  0,  
		nil,  nil,  'reverseState',  0,  
		nil,  nil,  'liveMode',  1,  
		nil,  nil,  'fixedPosState',  0,  
		'currentRate',  1.0,  nil,  nil,  
		nil,  nil,  nil,  nil ],  
	// Dictionary
	2, [ array: o[3],  size: 18 ],  
	// Array
	3, [ nil,  nil,  nil,  nil,  
		16,  0.0,  18,  0.35674458742142,  
		46,  0.5195444226265,  59,  0.0,  
		nil,  nil,  25,  0.0,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  62,  0.0,  
		26,  0.046674430370331,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		60,  1.0,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		61,  0.0,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  20,  0.3125,  
		24,  0.0,  nil,  nil,  
		21,  0.071637749671936,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  54,  0.0,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		22,  0.062709212303162,  55,  0.0,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  nil,  nil,  
		nil,  nil,  58,  0.0,  
		nil,  nil,  50,  0.0,  
		nil,  nil,  17,  0.05354642868042 ]
];
prUnarchive(o,p);
