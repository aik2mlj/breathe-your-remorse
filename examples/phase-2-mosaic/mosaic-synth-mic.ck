//------------------------------------------------------------------------------
// name: mosaic-synth-mic.ck (v1.3)
// desc: basic structure for a feature-based synthesizer
//       this particular version uses microphone as live input
//
// version: need chuck version 1.4.2.1 or higher
// sorting: part of ChAI (ChucK for AI)
//
// USAGE: run with INPUT model file
//        > chuck mosaic-synth-mic.ck:file
//
// uncomment the next line to learn more about the KNN2 object:
// KNN2.help();
//
// date: Spring 2023
// authors: Ge Wang (https://ccrma.stanford.edu/~ge/)
//          Yikai Li
//------------------------------------------------------------------------------

// input: pre-extracted model file
string FEATURES_FILE;
// if have arguments, override filename
if (me.args() > 0) {
    me.arg(0) => FEATURES_FILE;
} else {
    // print usage
    <<< "usage: chuck mosaic-synth-mic.ck:INPUT", "" >>>;
    <<< " |- INPUT: model file (.txt) containing extracted feature vectors", "" >>>;
}
//------------------------------------------------------------------------------
// expected model file format; each VALUE is a feature value
// (feel free to adapt and modify the file format as needed)
//------------------------------------------------------------------------------
// filePath windowStartTime VALUE VALUE ... VALUE
// filePath windowStartTime VALUE VALUE ... VALUE
// ...
// filePath windowStartTime VALUE VALUE ... VALUE
//------------------------------------------------------------------------------


//------------------------------------------------------------------------------
// unit analyzer network: *** this must match the features in the features file
//------------------------------------------------------------------------------
// audio input into a FFT
adc => FFT fft;
// a thing for collecting multiple features into one vector
FeatureCollector combo => blackhole;
// add spectral feature: Centroid
fft =^ Centroid centroid =^ combo;
// add spectral feature: Flux
fft =^ Flux flux =^ combo;
// add spectral feature: RMS
fft =^ RMS rms =^ combo;
// add spectral feature: MFCC
fft =^ MFCC mfcc =^ combo;


//-----------------------------------------------------------------------------
// setting analysis parameters -- also should match what was used during extration
//-----------------------------------------------------------------------------
// set number of coefficients in MFCC (how many we get out)
// 13 is a commonly used value; using less here for printing
20 => mfcc.numCoeffs;
// set number of mel filters in MFCC
10 => mfcc.numFilters;

// do one .upchuck() so FeatureCollector knows how many total dimension
combo.upchuck();
// get number of total feature dimensions
combo.fvals().size() => int NUM_DIMENSIONS;

// set FFT size
4096 => fft.size;
// set window type and size
Windowing.hann(fft.size()) => fft.window;
// our hop size (how often to perform analysis)
(fft.size() / 2)::samp => dur HOP;
// how many frames to aggregate before averaging?
// (this does not need to match extraction; might play with this number)
4 => int NUM_FRAMES;
// how much time to aggregate features for each file
fft.size()::samp * NUM_FRAMES => dur EXTRACT_TIME;


//------------------------------------------------------------------------------
// unit generator network: for real-time sound synthesis
//------------------------------------------------------------------------------
// how many max at any time?
16 => int NUM_VOICES;
// a number of audio buffers to cycel between
SndBuf buffers[NUM_VOICES];
ADSR envs[NUM_VOICES];
Pan2 pans[NUM_VOICES];
// set parameters
for (int i; i < NUM_VOICES; i++) {
    // connect audio
    buffers[i] => envs[i] => pans[i] => dac;
    // set chunk size (how to to load at a time)
    // this is important when reading from large files
    // if this is not set, SndBuf.read() will load the entire file immediately
    fft.size() => buffers[i].chunks;
    // randomize pan
    Math.random2f(-.75, .75) => pans[i].pan;
    // set envelope parameters
    envs[i].set(EXTRACT_TIME, EXTRACT_TIME / 2, 1, EXTRACT_TIME);
}


//------------------------------------------------------------------------------
// load feature data; read important global values like numPoints and numCoeffs
//------------------------------------------------------------------------------
// values to be read from file
0 => int numPoints; // number of points in data
0 => int numCoeffs; // number of dimensions in data
// file read PART 1: read over the file to get numPoints and numCoeffs
loadFile(FEATURES_FILE) @=> FileIO @fin;
// check
if (!fin.good())
    me.exit();
// check dimension at least
if (numCoeffs != NUM_DIMENSIONS) {
    // error
    <<< "[error] expecting:", NUM_DIMENSIONS, "dimensions; but features file has:", numCoeffs >>>;
    // stop
    me.exit();
}


//------------------------------------------------------------------------------
// each Point corresponds to one line in the input file, which is one audio window
//------------------------------------------------------------------------------
class AudioWindow {
    // unique point index (use this to lookup feature vector)
    int uid;
    // which file did this come file (in files arary)
    int fileIndex;
    // starting time in that file (in seconds)
    float windowTime;

    // set
    fun void set(int id, int fi, float wt) {
        id => uid;
        fi => fileIndex;
        wt => windowTime;
    }
}

// array of all points in model file
AudioWindow windows[numPoints];
// unique filenames; we will append to this
string files[0];
// map of filenames loaded
int filename2state[0];
// feature vectors of data points
float inFeatures[numPoints][numCoeffs];
// generate array of unique indices
int uids[numPoints];
for (int i; i < numPoints; i++)
    i => uids[i];

// use this for new input
float features[NUM_FRAMES][numCoeffs];
// average values of coefficients across frames
float featureMean[numCoeffs];


//------------------------------------------------------------------------------
// read the data
//------------------------------------------------------------------------------
readData(fin);


//------------------------------------------------------------------------------
// set up our KNN object to use for classification
// (KNN2 is a fancier version of the KNN object)
// -- run KNN2.help(); in a separate program to see its available functions --
//------------------------------------------------------------------------------
KNN2 knn;
// k nearest neighbors
2 => int K;
// results vector (indices of k nearest points)
int knnResult[K];
// knn train
knn.train(inFeatures, uids);


// used to rotate sound buffers
0 => int which;

//------------------------------------------------------------------------------
// SYNTHESIS!!
// this function is meant to be sporked so it can be stacked in time
//------------------------------------------------------------------------------
fun void synthesize(int uid) {
    // get the buffer to use
    buffers[which] @=> SndBuf @sound;
    // get the envelope to use
    envs[which] @=> ADSR @envelope;
    // increment and wrap if needed
    which++;
    if (which >= buffers.size())
        0 => which;

    // get a referencde to the audio fragment to synthesize
    windows[uid] @=> AudioWindow @win;
    // get filename
    files[win.fileIndex] => string filename;
    // load into sound buffer
    filename => sound.read;
    // seek to the window start time
    ((win.windowTime::second) / samp) $ int => sound.pos;

    // print what we are about to play
    chout <= "synthsizing window: ";
    // print label
    chout <= win.uid <= "[" <= win.fileIndex <= ":" <= win.windowTime <= ":POSITION=" <=
        sound.pos() <= "]";
    // endline
    chout <= IO.newline();

    // open the envelope, overlap add this into the overall audio
    envelope.keyOn();
    // wait
    (EXTRACT_TIME * 3) - envelope.releaseTime() => now;
    // start the release
    envelope.keyOff();
    // wait
    envelope.releaseTime() => now;
}


//------------------------------------------------------------------------------
// real-time similarity retrieval loop
//------------------------------------------------------------------------------
while (true) {
    // aggregate features over a period of time
    for (int frame; frame < NUM_FRAMES; frame++) {
        //-------------------------------------------------------------
        // a single upchuck() will trigger analysis on everything
        // connected upstream from combo via the upchuck operator (=^)
        // the total number of output dimensions is the sum of
        // dimensions of all the connected unit analyzers
        //-------------------------------------------------------------
        combo.upchuck();
        // get features
        for (int d; d < NUM_DIMENSIONS; d++) {
            // store them in current frame
            combo.fval(d) => features[frame][d];
        }
        // advance time
        HOP => now;
    }

    // compute means for each coefficient across frames
    for (int d; d < NUM_DIMENSIONS; d++) {
        // zero out
        0.0 => featureMean[d];
        // loop over frames
        for (int j; j < NUM_FRAMES; j++) {
            // add
            features[j][d] +=> featureMean[d];
        }
        // average
        NUM_FRAMES /=> featureMean[d];
    }

    //-------------------------------------------------
    // search using KNN2; results filled in knnResults,
    // which should the indices of k nearest points
    //-------------------------------------------------
    knn.search(featureMean, K, knnResult);

    // SYNTHESIZE THIS
    spork ~ synthesize(knnResult[Math.random2(0, knnResult.size() - 1)]);
}
//------------------------------------------------------------------------------
// end of real-time similiarity retrieval loop
//------------------------------------------------------------------------------


//------------------------------------------------------------------------------
// function: load data file
//------------------------------------------------------------------------------
fun FileIO loadFile(string filepath) {
    // reset
    0 => numPoints;
    0 => numCoeffs;

    // load data
    FileIO fio;
    if (!fio.open(filepath, FileIO.READ)) {
        // error
        <<< "cannot open file:", filepath >>>;
        // close
        fio.close();
        // return
        return fio;
    }

    string str;
    string line;
    // read the first non-empty line
    while (fio.more()) {
        // read each line
        fio.readLine().trim() => str;
        // check if empty line
        if (str != "") {
            numPoints++;
            str => line;
        }
    }

    // a string tokenizer
    StringTokenizer tokenizer;
    // set to last non-empty line
    tokenizer.set(line);
    // negative (to account for filePath windowTime)
    -2 => numCoeffs;
    // see how many, including label name
    while (tokenizer.more()) {
        tokenizer.next();
        numCoeffs++;
    }

    // see if we made it past the initial fields
    if (numCoeffs < 0)
        0 => numCoeffs;

    // check
    if (numPoints == 0 || numCoeffs <= 0) {
        <<< "no data in file:", filepath >>>;
        fio.close();
        return fio;
    }

    // print
    <<< "# of data points:", numPoints, "dimensions:", numCoeffs >>>;

    // done for now
    return fio;
}


//------------------------------------------------------------------------------
// function: read the data
//------------------------------------------------------------------------------
fun void readData(FileIO fio) {
    // rewind the file reader
    fio.seek(0);

    // a line
    string line;
    // a string tokenizer
    StringTokenizer tokenizer;

    // points index
    0 => int index;
    // file index
    0 => int fileIndex;
    // file name
    string filename;
    // window start time
    float windowTime;
    // coefficient
    int c;

    // read the first non-empty line
    while (fio.more()) {
        // read each line
        fio.readLine().trim() => line;
        // check if empty line
        if (line != "") {
            // set to last non-empty line
            tokenizer.set(line);
            // file name
            tokenizer.next() => filename;
            // window start time
            tokenizer.next() => Std.atof => windowTime;
            // have we seen this filename yet?
            if (filename2state[filename] == 0) {
                // make a new string (<< appends by reference)
                filename => string sss;
                // append
                files << sss;
                // new id
                files.size() => filename2state[filename];
            }
            // get fileindex
            filename2state[filename] - 1 => fileIndex;
            // set
            windows[index].set(index, fileIndex, windowTime);

            // zero out
            0 => c;
            // for each dimension in the data
            repeat(numCoeffs) {
                // read next coefficient
                tokenizer.next() => Std.atof => inFeatures[index][c];
                // increment
                c++;
            }

            // increment global index
            index++;
        }
    }
}
