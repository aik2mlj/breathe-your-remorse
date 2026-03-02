//------------------------------------------------------------------------------
// name: mosaic.ck
// desc: feature-based synthesizer using preMix as input (not mic)
//       adapted from mosaic-synth-mic.ck
//------------------------------------------------------------------------------

public class Mosaic {
    //--------------------------------------------------------------------------
    // unit analyzer network: will be connected to preMix in init()
    //--------------------------------------------------------------------------
    FFT fft;
    FeatureCollector combo => blackhole;
    fft =^ Centroid centroid =^ combo;
    fft =^ Flux flux =^ combo;
    fft =^ RMS rms =^ combo;
    fft =^ MFCC mfcc =^ combo;

    // analysis parameters
    20 => mfcc.numCoeffs;
    10 => mfcc.numFilters;

    4096 => fft.size;
    Windowing.hann(fft.size()) => fft.window;
    (fft.size() / 2)::samp => dur HOP;
    4 => int NUM_FRAMES;
    fft.size()::samp * NUM_FRAMES => dur EXTRACT_TIME;

    int NUM_DIMENSIONS;

    //--------------------------------------------------------------------------
    // synthesis voices (output goes directly to dac to avoid feedback loop)
    //--------------------------------------------------------------------------
    16 => int NUM_VOICES;
    SndBuf buffers[NUM_VOICES];
    ADSR envs[NUM_VOICES];
    Pan2 pans[NUM_VOICES];
    Gain mosaicOut;
    1.0 => mosaicOut.gain;

    //--------------------------------------------------------------------------
    // data structures
    //--------------------------------------------------------------------------
    int numPoints;
    int numCoeffs;

    class AudioWindow {
        int uid;
        int fileIndex;
        float windowTime;

        fun void set(int id, int fi, float wt) {
            id => uid;
            fi => fileIndex;
            wt => windowTime;
        }
    }

    AudioWindow windows[0];
    string files[0];
    int filename2state[0];
    float inFeatures[0][0];
    int uids[0];
    float features[0][0];
    float featureMean[0];

    KNN2 knn;
    2 => int K;
    int knnResult[0];
    0 => int which;

    // RMS threshold: only synthesize when there's actual sound
    0.0001 => float RMS_THRESHOLD;

    //--------------------------------------------------------------------------
    // initialize with features file and preMix gain
    //--------------------------------------------------------------------------
    fun int init(string featuresFile, Gain @preMix) {
        // connect preMix to FFT for analysis
        preMix => fft;

        // connect mosaic output to dac
        mosaicOut => dac;

        // now we can upchuck to get dimensions
        combo.upchuck();
        combo.fvals().size() => NUM_DIMENSIONS;

        // setup voices
        for (int i; i < NUM_VOICES; i++) {
            buffers[i] => envs[i] => pans[i] => mosaicOut;
            fft.size() => buffers[i].chunks;
            Math.random2f(-.75, .75) => pans[i].pan;
            envs[i].set(EXTRACT_TIME, EXTRACT_TIME / 2, 1, EXTRACT_TIME);
        }

        // load file
        loadFile(featuresFile) @=> FileIO @fin;
        if (!fin.good()) {
            <<< "[mosaic] failed to load file" >>>;
            return false;
        }
        if (numCoeffs != NUM_DIMENSIONS) {
            <<< "[mosaic] error: expecting:", NUM_DIMENSIONS,
               "dimensions; but file has:", numCoeffs >>>;
            return false;
        }

        // allocate arrays
        new AudioWindow[numPoints] @=> windows;
        new float[numPoints][numCoeffs] @=> inFeatures;
        new int[numPoints] @=> uids;
        for (int i; i < numPoints; i++)
            i => uids[i];
        new float[NUM_FRAMES][numCoeffs] @=> features;
        new float[numCoeffs] @=> featureMean;
        new int[K] @=> knnResult;

        // read data
        readData(fin);

        // train KNN
        knn.train(inFeatures, uids);

        <<< "[mosaic] initialized with", numPoints, "windows" >>>;
        return true;
    }

    //--------------------------------------------------------------------------
    // synthesis function
    //--------------------------------------------------------------------------
    fun void synthesize(int uid) {
        buffers[which] @=> SndBuf @sound;
        envs[which] @=> ADSR @envelope;
        which++;
        if (which >= buffers.size())
            0 => which;

        windows[uid] @=> AudioWindow @win;
        files[win.fileIndex] => string filename;
        filename => sound.read;
        ((win.windowTime::second) / samp) $ int => sound.pos;

        <<< "[mosaic] synth uid:", win.uid, "file:", filename, "pos:", sound.pos(),
           "samples:", sound.samples() >>>;

        // make sure sound plays
        1 => sound.gain;
        1 => sound.rate;

        envelope.keyOn();
        (EXTRACT_TIME * 3) - envelope.releaseTime() => now;
        envelope.keyOff();
        envelope.releaseTime() => now;
    }

    //--------------------------------------------------------------------------
    // main analysis/synthesis loop (spork this)
    //--------------------------------------------------------------------------
    fun void run() {
        <<< "[mosaic] analysis loop started" >>>;

        while (true) {
            for (int frame; frame < NUM_FRAMES; frame++) {
                combo.upchuck();
                for (int d; d < NUM_DIMENSIONS; d++) {
                    combo.fval(d) => features[frame][d];
                }
                HOP => now;
            }

            // compute means
            for (int d; d < NUM_DIMENSIONS; d++) {
                0.0 => featureMean[d];
                for (int j; j < NUM_FRAMES; j++) {
                    features[j][d] +=> featureMean[d];
                }
                NUM_FRAMES /=> featureMean[d];
            }

            // debug: print RMS value periodically
            <<< "[mosaic] RMS:", featureMean[2] >>>;

            // check RMS threshold - only trigger if there's sound
            if (featureMean[2] > RMS_THRESHOLD) {
                <<< "[mosaic] triggering synthesis!" >>>;
                knn.search(featureMean, K, knnResult);
                spork ~ synthesize(knnResult[Math.random2(0, knnResult.size() - 1)]);
            }
        }
    }

    //--------------------------------------------------------------------------
    // load data file
    //--------------------------------------------------------------------------
    fun FileIO loadFile(string filepath) {
        0 => numPoints;
        0 => numCoeffs;

        FileIO fio;
        if (!fio.open(filepath, FileIO.READ)) {
            <<< "[mosaic] cannot open file:", filepath >>>;
            fio.close();
            return fio;
        }

        string str;
        string line;
        while (fio.more()) {
            fio.readLine().trim() => str;
            if (str != "") {
                numPoints++;
                str => line;
            }
        }

        StringTokenizer tokenizer;
        tokenizer.set(line);
        -2 => numCoeffs;
        while (tokenizer.more()) {
            tokenizer.next();
            numCoeffs++;
        }

        if (numCoeffs < 0)
            0 => numCoeffs;

        if (numPoints == 0 || numCoeffs <= 0) {
            <<< "[mosaic] no data in file:", filepath >>>;
            fio.close();
            return fio;
        }

        <<< "[mosaic] # of data points:", numPoints, "dimensions:", numCoeffs >>>;
        return fio;
    }

    //--------------------------------------------------------------------------
    // read the data
    //--------------------------------------------------------------------------
    fun void readData(FileIO fio) {
        fio.seek(0);

        string line;
        StringTokenizer tokenizer;

        0 => int index;
        0 => int fileIndex;
        string filename;
        float windowTime;
        int c;

        while (fio.more()) {
            fio.readLine().trim() => line;
            if (line != "") {
                tokenizer.set(line);
                tokenizer.next() => filename;
                tokenizer.next() => Std.atof => windowTime;
                if (filename2state[filename] == 0) {
                    filename => string sss;
                    files << sss;
                    files.size() => filename2state[filename];
                }
                filename2state[filename] - 1 => fileIndex;
                windows[index].set(index, fileIndex, windowTime);

                0 => c;
                repeat(numCoeffs) {
                    tokenizer.next() => Std.atof => inFeatures[index][c];
                    c++;
                }

                index++;
            }
        }
    }
}
