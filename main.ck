//------------------------------------------------------------------------------
// main.ck
// desc: mic-delayed mosaic
//------------------------------------------------------------------------------
@import "mosaic.ck"

// tweakables
5::second => dur EXTRACT_DELAY;
120::second => dur MIC_BUFFER_LEN; // rolling corpus buffer length
600 => int MAX_POINTS;              // how many windows to keep in corpus

// mic input (analysis only; do NOT connect to dac)
adc => Gain micIn;
adc => dac.chan(0);
adc => dac.chan(1);
1.0 => micIn.gain;

// build mosaic
Mosaic m;
m.initMic(micIn, EXTRACT_DELAY, MIC_BUFFER_LEN, MAX_POINTS);

// run
spork ~ m.run();
spork ~ m.randomizeRev();

// keep alive
while (true)
    1::second => now;
