//------------------------------------------------------------------------------
// name: normalize.ck (v1.3)
// desc: takes a model file as input, normalizes it, and outputs
//       1) a normalized model file AND 2) a text file with the mins
//       and maxs for each dimension
//
// USAGE: > chuck normalize.ck:INPUT:OUTPUT:MINMAX
//
// INPUT:  a model file containing feature vectors
//         ------------------------------------------------------------
//          model file format; each VALUE is a feature value
//         (feel free to adapt and modify the file format as needed)
//         ------------------------------------------------------------
//         filePath windowStartTime VALUE VALUE ... VALUE
//         filePath windowStartTime VALUE VALUE ... VALUE
//         ...
//         filePath windowStartTime VALUE VALUE ... VALUE
//         ------------------------------------------------------------
// OUTPUT: a model file of the same format, but where each dimension
//         is normalized 0 to 1
// MINMAX: a second output text file that will contain the minimum and
//         maximum values for each dimension; this file will contain
//         the same number of lines are there dimension in the INPUT file
//         -----------
//         MIN1 MAX1
//         MIN2 MAX2
//         ...
//         MIN_N MAX_N
//         -----------
//
// date: Spring 2023
// authors: Ge Wang (https://ccrma.stanford.edu/~ge/)
//          Yikai Li
//------------------------------------------------------------------------------

// input model file
"" => string INPUT_FILE;
// output normalized mode file
"" => string OUTPUT_FILE;
// file with min and maxes
"" => string MINMAX_FILE;
// if have arguments, override filename
if (me.args() >= 3) {
    me.arg(0) => INPUT_FILE;
    me.arg(1) => OUTPUT_FILE;
    me.arg(2) => MINMAX_FILE;
} else {
    // print usage
    <<< "usage: chuck normalize.ck:INPUT:OUTPUT:MINMAX", "" >>>;
    <<< " |- INPUT: model file (.txt) containing extracted feature vectors", "" >>>;
    <<< " |- OUTPUT: normalized model file (.txt)", "" >>>;
    <<< " |- MINMAX: normalize.ck outputs to this text file min and max for each dimension", "" >>>;
}


//------------------------------------------------------------------------------
// read INPUT; read important global values like numPoints and numCoeffs
//------------------------------------------------------------------------------
// values to be read from file
0 => int numPoints; // number of points in data
0 => int numCoeffs; // number of dimensions in data
float dimMin[];      // array reference for mins
float dimMax[];      // array reference for maxs
// read (part 1): get numPoints and numCoeffs, and min and max for each dim
loadFile(INPUT_FILE) @=> FileIO @fin;
// check
if (!fin.good())
    me.exit();
// if didn't get min or max
if (dimMin == null || dimMax == null) {
    <<< "[normalize]: couldn't compute min or max for data", "" >>>;
    me.exit();
}


//------------------------------------------------------------------------------
// write the normalized data to OUTPUT
//------------------------------------------------------------------------------
writeData(fin, OUTPUT_FILE);


//------------------------------------------------------------------------------
// write the min/max bounds to MINMAX
//------------------------------------------------------------------------------
// file io
FileIO fmm;
// load data
if (!fmm.open(MINMAX_FILE, FileIO.WRITE)) {
    // error
    <<< "cannot open min/max file for writing:", MINMAX_FILE >>>;
    // close
    fmm.close();
    // done
    me.exit();
}

// loop over min/max
for (int i; i < numCoeffs; i++) {
    fmm <= dimMin[i] <= " " <= dimMax[i] <= IO.newline();
}

// flush and close
fmm.flush();
fmm.close();


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
    int c;
    float value;
    // read the first non-empty line
    while (fio.more()) {
        // read each line
        fio.readLine().trim() => str;
        // check if empty line
        if (str != "") {
            // break after first non-empty line
            break;
        }
    }

    // a string tokenizer
    StringTokenizer tokenizer;
    // set to last non-empty line
    tokenizer.set(str);
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
    if (numCoeffs <= 0) {
        <<< "no data in file:", filepath >>>;
        fio.close();
        return fio;
    }

    // allocate array
    new float[numCoeffs] @=> dimMin;
    new float[numCoeffs] @=> dimMax;
    // initialize
    for (int i; i < dimMin.size(); i++)
        Math.FLOAT_MAX / 2 => dimMin[i];
    for (int i; i < dimMax.size(); i++)
        -Math.FLOAT_MAX / 2 => dimMax[i];

    // rewind
    fio.seek(0);

    // read the first non-empty line
    while (fio.more()) {
        // read each line
        fio.readLine().trim() => str;
        // check if empty line
        if (str != "") {
            numPoints++;
            str => line;

            // set to next non-empty line
            tokenizer.set(line);
            // file name (skip)
            tokenizer.next();
            // window start time (skip)
            tokenizer.next();

            // zero out
            0 => c;
            // for each dimension in the data
            repeat(numCoeffs) {
                // read next coefficient
                tokenizer.next() => Std.atof => value;
                // check for min
                if (value < dimMin[c])
                    value => dimMin[c];
                if (value > dimMax[c])
                    value => dimMax[c];
                // increment
                c++;
            }
        }
    }

    // print
    <<< "# of data points:", numPoints, "dimensions:", numCoeffs >>>;

    // done for now
    return fio;
}


//------------------------------------------------------------------------------
// function: read the data
//------------------------------------------------------------------------------
fun int writeData(FileIO fin, string outputFile) {
    // rewind the file reader
    fin.seek(0);

    // file io
    FileIO fout;
    // load data
    if (!fout.open(outputFile, FileIO.WRITE)) {
        // error
        <<< "cannot open file for writing:", outputFile >>>;
        // close
        fout.close();
        // return
        return false;
    }

    // a line
    string line;
    // a string tokenizer
    StringTokenizer tokenizer;

    // points index
    0 => int index;
    // file name
    string filename;
    // window start time
    string windowTime;
    // coefficient index
    int c;
    // a value
    float value;

    // read the first non-empty line
    while (fin.more()) {
        // read each line
        fin.readLine().trim() => line;
        // check if empty line
        if (line != "") {
            // set to next non-empty line
            tokenizer.set(line);
            // file name
            tokenizer.next() => filename;
            // window start time
            tokenizer.next() => windowTime;

            // output
            fout <= filename <= " " <= windowTime <= " ";

            // zero out
            0 => c;
            // for each dimension in the data
            repeat(numCoeffs) {
                // read next coefficient
                tokenizer.next() => Std.atof => value;
                // remap it and output
                fout <= Math.remap(value, dimMin[c], dimMax[c], 0, 1) <= " ";
                // increment
                c++;
            }

            fout <= IO.newline();
        }
    }

    // flush file
    fout.flush();
    // close it
    fout.close();

    // done
    return true;
}
