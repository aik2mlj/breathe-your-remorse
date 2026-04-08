//------------------------------------------------------------------------------
// name: mosaic.ck
// desc: feature-based synthesizer
//       - original mode: match against pre-extracted feature file + play SndBuf
//       - new mode: continuously extract features from mic with delay, match
//         against a rolling corpus built from delayed mic windows, and play
//         back from a rolling LiSa buffer
//------------------------------------------------------------------------------

public class Mosaic {
    //--------------------------------------------------------------------------
    // shared analysis network (input connected in init/initMic)
    //--------------------------------------------------------------------------
    FFT fft;
    FeatureCollector combo => blackhole;
    fft =^ Centroid centroid =^ combo;
    fft =^ Flux flux =^ combo;
    fft =^ RMS rms =^ combo;
    fft =^ MFCC mfcc =^ combo;

    // analysis parameters (same as extract)
    20 => mfcc.numCoeffs;
    10 => mfcc.numFilters;

    4096 => fft.size;
    Windowing.hann(fft.size()) => fft.window;
    (fft.size() / 2)::samp => dur HOP;
    4 => int NUM_FRAMES;
    fft.size()::samp * NUM_FRAMES => dur EXTRACT_TIME;

    int NUM_DIMENSIONS;

    // RMS threshold: only synthesize when there's actual sound
    0.00005 => float RMS_THRESHOLD;

    //--------------------------------------------------------------------------
    // ORIGINAL FILE-BASED SYNTH VOICES
    //--------------------------------------------------------------------------
    16 => int NUM_VOICES;
    SndBuf buffers[NUM_VOICES];
    ADSR envs[NUM_VOICES];
    Pan2 pans[NUM_VOICES];
    Gain mosaicOut;
    1.0 => mosaicOut.gain;

    //--------------------------------------------------------------------------
    // ORIGINAL FILE-BASED DATA
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
    // K nearest
    3 => int K;
    int knnResult[0];
    0 => int which;

    //--------------------------------------------------------------------------
    // NEW MIC-DELAYED MODE STATE
    //--------------------------------------------------------------------------
    int micMode;
    dur EXTRACT_DELAY;
    dur MIC_BUFFER_LEN;
    NRev rev[2];

    // record mic into LiSa
    LiSa2 micBuf;
    // delayed analysis tap
    // DelayA delayTap;

    // rolling corpus
    int MAX_POINTS;
    int micCount;
    int micWriteIdx;
    int micFilled;

    // avoid choosing the most recent few windows (self-match)
    16 => int AVOID_RECENT;

    // store feature vectors + start positions (in samples) for each window
    float micFeatures[0][0];
    float micStartPosSamp[0];

    //--------------------------------------------------------------------------
    // initialize ORIGINAL mode: features file + preMix
    //--------------------------------------------------------------------------
    fun int init(string featuresFile, Gain @preMix) {
        0 => micMode;

        // connect analysis input
        preMix => fft;

        // connect output
        mosaicOut => dac;

        // determine dims
        combo.upchuck();
        combo.fvals().size() => NUM_DIMENSIONS;

        // setup voices (SndBuf-based)
        for (int i; i < NUM_VOICES; i++) {
            buffers[i] => envs[i] => pans[i] => mosaicOut;
            fft.size() => buffers[i].chunks;
            Math.random2f(-.75, .75) => pans[i].pan;
            envs[i].set(EXTRACT_TIME, EXTRACT_TIME / 2, 1, EXTRACT_TIME);
        }

        // load feature file
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

        // read + train
        readData(fin);
        knn.train(inFeatures, uids);

        <<< "[mosaic] initialized (file mode) with", numPoints, "windows" >>>;
        return true;
    }

    //--------------------------------------------------------------------------
    // initialize NEW mic-delayed mode
    //
    // micIn:  connect adc => Gain micIn externally (do NOT route to dac)
    // delay:  EXTRACT_DELAY (e.g., 10::second)
    // bufLen: rolling mic buffer length (e.g., 120::second)
    // maxPts: corpus size (e.g., 600)
    //--------------------------------------------------------------------------
    fun int initMic(Gain @micIn, dur delay, dur bufLen, int maxPts) {
        1 => micMode;

        delay => EXTRACT_DELAY;
        bufLen => MIC_BUFFER_LEN;
        maxPts => MAX_POINTS;


        // determine feature dims
        combo.upchuck();
        combo.fvals().size() => NUM_DIMENSIONS;

        // --- LiSa rolling recorder ---
        MIC_BUFFER_LEN => micBuf.duration;
        // a little safety: allow multiple playback voices
        NUM_VOICES => micBuf.maxVoices;
        // random panning
        // <<< micBuf.channels() >>>;
        for (int v; v < micBuf.maxVoices(); v++) {
            // can pan across all available channels
            // note LiSa.pan( voice, [0...channels-1] )
            micBuf.pan(v, Math.random2f(0, micBuf.channels() - 1));
        }
        // connect mic input to LiSa for recording; connect LiSa output to
        // mosaicOut so it is pulled by the audio graph (required for both
        // recording and playback voices to work)

        // micIn => micBuf => mosaicOut;
        // mosaicOut => dac;

        // reverb
        0.1 => rev[0].mix;
        0.1 => rev[1].mix;

        micIn => micBuf => rev => dac;
        1 => micBuf.record;
        // output

        // connect mic input directly to FFT (no delay — instant response)
        micIn => fft;

        // allocate analysis temp buffers
        new float[NUM_FRAMES][NUM_DIMENSIONS] @=> features;
        new float[NUM_DIMENSIONS] @=> featureMean;

        // allocate corpus arrays (fixed capacity)
        new float[MAX_POINTS][NUM_DIMENSIONS] @=> micFeatures;
        new float[MAX_POINTS] @=> micStartPosSamp;
        0 => micCount;
        0 => micWriteIdx;
        0 => micFilled;

        <<< "[mosaic] initialized (mic mode)", "delay:", (EXTRACT_DELAY / second), "sec",
           "buffer:", (MIC_BUFFER_LEN / second), "sec", "maxPts:", MAX_POINTS >>>;

        return true;
    }

    //--------------------------------------------------------------------------
    // ORIGINAL synthesis: play from disk SndBuf (file mode)
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

        1 => sound.gain;
        1 => sound.rate;

        envelope.keyOn();
        (EXTRACT_TIME * 3) - envelope.releaseTime() => now;
        envelope.keyOff();
        envelope.releaseTime() => now;
    }

    //--------------------------------------------------------------------------
    // NEW mic-mode synthesis: play from LiSa rolling buffer
    // startPos: start position in samples (0..bufferSamples)
    //--------------------------------------------------------------------------
    fun void synthesizeMic(float startPos) { synthesizeMic(startPos, 1.0, 1.0); }

    fun void synthesizeMic(float startPos, float gain, float rate) {
        // allocate a LiSa voice
        micBuf.getVoice() => int v;
        if (v < 0)
            return;

        micBuf.voiceGain(v, gain);
        micBuf.rate(v, rate);
        micBuf.loop(v, 0);

        // set play position and start
        micBuf.playPos(v, startPos::samp);
        // micBuf.play(v, 1);

        // attack
        micBuf.rampUp(v, EXTRACT_TIME);
        EXTRACT_TIME => now;

        // sustain
        EXTRACT_TIME => now;

        // release
        micBuf.rampDown(v, EXTRACT_TIME);
        EXTRACT_TIME => now;

        // stop voice
        // micBuf.play(v, 0);
    }

    //--------------------------------------------------------------------------
    // run loop entrypoint (keeps old behavior)
    //--------------------------------------------------------------------------
    fun void run() {
        if (micMode)
            runMic();
        else
            runFile();
    }

    //--------------------------------------------------------------------------
    // ORIGINAL analysis/synth loop (file mode)
    //--------------------------------------------------------------------------
    fun void runFile() {
        <<< "[mosaic] analysis loop started (file mode)" >>>;

        while (true) {
            // gather frames
            for (int frame; frame < NUM_FRAMES; frame++) {
                combo.upchuck();
                for (int d; d < NUM_DIMENSIONS; d++)
                    combo.fval(d) => features[frame][d];
                HOP => now;
            }

            // mean
            for (int d; d < NUM_DIMENSIONS; d++) {
                0.0 => featureMean[d];
                for (int j; j < NUM_FRAMES; j++)
                    features[j][d] +=> featureMean[d];
                NUM_FRAMES /=> featureMean[d];
            }

            // RMS is featureMean[2] in this chain (Centroid, Flux, RMS, MFCC...)
            if (featureMean[2] > RMS_THRESHOLD) {
                knn.search(featureMean, K, knnResult);
                spork ~ synthesize(knnResult[Math.random2(0, knnResult.size() - 1)]);
            }
        }
    }

    //--------------------------------------------------------------------------
    // NEW analysis/synth loop (mic mode)
    //
    // Behavior:
    // - analysis is performed on live mic signal (no delay)
    // - every window, we:
    //   (1) compute featureMean (delayed)
    //   (2) add that feature + corresponding start position to corpus
    //   (3) if RMS threshold and corpus has enough points, find K nearest
    //       neighbors in corpus and replay one from LiSa
    //--------------------------------------------------------------------------
    fun void runMic() {
        <<< "[mosaic] analysis loop started (mic mode)" >>>;

        // wait one analysis window for FFT to fill
        <<< "[mosaic] waiting", EXTRACT_TIME / second, "sec for FFT fill..." >>>;
        EXTRACT_TIME => now;
        <<< "[mosaic] entering analysis loop" >>>;

        0 => int loopCount;

        while (true) {
            // gather frames (from delayed tap)
            for (int frame; frame < NUM_FRAMES; frame++) {
                combo.upchuck();
                for (int d; d < NUM_DIMENSIONS; d++)
                    combo.fval(d) => features[frame][d];
                HOP => now;
            }

            // mean over frames
            for (int d; d < NUM_DIMENSIONS; d++) {
                0.0 => featureMean[d];
                for (int j; j < NUM_FRAMES; j++)
                    features[j][d] +=> featureMean[d];
                NUM_FRAMES /=> featureMean[d];
            }

            // compute start position in LiSa for the current analysis window:
            // record head is at "now"; analysis covered the last EXTRACT_TIME samples.
            float bufSamples;
            (MIC_BUFFER_LEN / samp) => bufSamples;
            micBuf.recPos() / samp => float recPos;
            recPos - (EXTRACT_TIME / samp) => float startPos;
            // wrap
            while (startPos < 0)
                startPos + bufSamples => startPos;
            while (startPos >= bufSamples)
                startPos - bufSamples => startPos;

            // add to corpus (rolling overwrite)
            for (int d; d < NUM_DIMENSIONS; d++)
                featureMean[d] => micFeatures[micWriteIdx][d];
            startPos => micStartPosSamp[micWriteIdx];

            micWriteIdx++;
            if (micWriteIdx >= MAX_POINTS) {
                0 => micWriteIdx;
                1 => micFilled;
            }

            if (!micFilled)
                micWriteIdx => micCount;
            else
                MAX_POINTS => micCount;

            // periodic status print every 20 loops
            loopCount++;
            if (loopCount % 20 == 0) {
                <<< "[mosaic] loop:", loopCount, "| RMS:", featureMean[2], "| corpus:", micCount,
                   "| recPos:", recPos, "| startPos:", startPos >>>;
            }

            // trigger synth if enough points + above RMS
            if (featureMean[2] > RMS_THRESHOLD && micCount > 8) {
                // find K nearest neighbors (simple euclidean)
                K => int k;
                if (k < 1)
                    1 => k;

                // best lists
                float bestDist[8];
                int bestIdx[8];
                // cap k to 8 here for simplicity
                if (k > 8)
                    8 => k;

                for (int i; i < k; i++) {
                    1e30 => bestDist[i];
                    -1 => bestIdx[i];
                }

                for (int i; i < micCount; i++) {
                    // compute "age" in ring terms
                    // skip a handful of the most recent written windows
                    // (only meaningful when filled; still okay when not filled)
                    if (i == (micWriteIdx - 1 + MAX_POINTS) % MAX_POINTS)
                        continue;

                    // quick skip: avoid very recent indices near write head
                    int ringDist;
                    (micWriteIdx - i);
                    if ((micWriteIdx - i) < 0)
                        (micWriteIdx - i + MAX_POINTS) => ringDist;
                    else
                        (micWriteIdx - i) => ringDist;
                    if (ringDist >= 0 && ringDist <= AVOID_RECENT)
                        continue;

                    // distance
                    0.0 => float dist;
                    for (int d; d < NUM_DIMENSIONS; d++) {
                        (featureMean[d] - micFeatures[i][d]) => float diff;
                        diff * diff +=> dist;
                    }

                    // insert into best list
                    for (int b; b < k; b++) {
                        if (dist < bestDist[b]) {
                            // shift down
                            for (k - 1 => int s; s > b; s--) {
                                bestDist[s - 1] => bestDist[s];
                                bestIdx[s - 1] => bestIdx[s];
                            }
                            dist => bestDist[b];
                            i => bestIdx[b];
                            break;
                        }
                    }
                }

                // choose one of the found neighbors at random
                Math.random2(0, k - 1) => int pick;
                if (bestIdx[pick] >= 0) {
                    micStartPosSamp[bestIdx[pick]] => float playStart;
                    <<< "[mosaic] SYNTH pick:", pick, "idx:", bestIdx[pick], "playStart:", playStart,
                       "dist:", bestDist[pick] >>>;
                    // randomize rate to 1 or -1
                    1 => float rate;
                    if (Math.random2f(0, 1) < 0.3)
                        -1 => rate;
                    spork ~ synthesizeMic(playStart, 1.0, rate);
                } else {
                    <<< "[mosaic] above RMS but no valid neighbor found (pick:", pick,
                       "bestIdx:", bestIdx[pick], ")" >>>;
                }
            } else if (featureMean[2] < RMS_THRESHOLD && micCount > 8) {
                // silent, then randomly sample from the corpus
                if (Math.random2f(0, 1) < 0.4) {
                    Math.random2(0, micCount - 1) => int pick;
                    micStartPosSamp[pick] => float playStart;
                    <<< "[mosaic] SILENT random pick:", pick, "playStart:", playStart >>>;
                    Math.random2f(0.8, 1.2) => float rate;
                    if (Math.random2f(0, 1) < 0.3)
                        -rate => rate;
                    spork ~ synthesizeMic(playStart, 0.5, rate);
                }
            } else if (loopCount % 20 == 0) {
                if (featureMean[2] <= RMS_THRESHOLD)
                    <<< "[mosaic] silent (RMS below threshold:", RMS_THRESHOLD, ")" >>>;
                else
                    <<< "[mosaic] corpus too small:", micCount, "need > 8" >>>;
            }
        }
    }

    fun void randomizeRev() {
        now => time start;
        while (true) {
            // synthesize a sine LFO for mix change
            (now - start) / 1::second => float lfo;
            (Math.sin(lfo) + 1.1) / 7 => rev[0].mix;
            (Math.cos(lfo) + 1.1) / 7 => rev[1].mix;
            1::samp => now;
        }
    }

    //--------------------------------------------------------------------------
    // load data file (file mode)
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
    // read the data (file mode)
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
