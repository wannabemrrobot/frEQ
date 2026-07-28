// Standalone tests for AEDSP: transparency, per-effect frequency behavior,
// level matching, stability, smoothing, and the lock-free param handoff.
// Run via: clang -O2 -Wall -Wextra -std=c11 -o /tmp/dsp-tests \
//   App/Sources/Audio/AEDSP.c Tests/DSPTests.c -lm -lpthread && /tmp/dsp-tests

#include "../App/Sources/Audio/AEDSP.h"
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static int failures = 0;
#define EXPECT(cond, msg) do { \
    if (cond) { printf("  ok: %s\n", msg); } \
    else { printf("  FAIL: %s\n", msg); failures++; } \
} while (0)

static const double kPi = 3.14159265358979323846;
#define FS 48000.0
#define BLOCK 512u
#define WARM 24000u   /* 0.5 s: lets 10 ms ramps fully settle + snap */
#define MEAS 48000u   /* 1 s measurement window (integer Hz = integer bins) */

// ---------------------------------------------------------------------------
// Helpers

static float* allocStereo(uint32_t frames)
{
    float* p = (float*)malloc((size_t)frames * 2 * sizeof(float));
    if (!p) { fprintf(stderr, "alloc failure\n"); exit(2); }
    return p;
}

static void processBlocks(AEDSPState* st, float* buf, uint32_t frames)
{
    uint32_t off = 0;
    while (off < frames) {
        uint32_t n = frames - off < BLOCK ? frames - off : BLOCK;
        AEDSPProcess(st, buf + 2 * off, n);
        off += n;
    }
}

// Sine with independent per-channel frequency/amplitude, phase-continuous
// from absolute frame 0.
static void sineFill(float* buf, uint32_t frames,
                     double freqL, double ampL, double freqR, double ampR)
{
    for (uint32_t n = 0; n < frames; n++) {
        buf[2 * n] = (float)(ampL * sin(2.0 * kPi * freqL * n / FS));
        buf[2 * n + 1] = (float)(ampR * sin(2.0 * kPi * freqR * n / FS));
    }
}

static uint32_t lcgNext(uint32_t* s)
{
    *s = *s * 1664525u + 1013904223u;
    return *s;
}

static float lcgFloat(uint32_t* s, float amp)   // uniform in [-amp, amp)
{
    return ((float)(lcgNext(s) >> 8) / 8388608.0f - 1.0f) * amp;
}

static void noiseFill(float* buf, uint32_t frames, float amp, uint32_t seed,
                      bool mono)
{
    uint32_t s = seed;
    for (uint32_t n = 0; n < frames; n++) {
        float l = lcgFloat(&s, amp);
        buf[2 * n] = l;
        buf[2 * n + 1] = mono ? l : lcgFloat(&s, amp);
    }
}

// Goertzel amplitude of one channel over [start, start+n) frames.
static double goertzelAmp(const float* buf, uint32_t start, uint32_t n,
                          int ch, double freq)
{
    double w = 2.0 * kPi * freq / FS;
    double cw = 2.0 * cos(w);
    double s1 = 0.0, s2 = 0.0;
    for (uint32_t i = 0; i < n; i++) {
        double s0 = buf[2 * (start + i) + ch] + cw * s1 - s2;
        s2 = s1;
        s1 = s0;
    }
    double p = s1 * s1 + s2 * s2 - cw * s1 * s2;
    return 2.0 * sqrt(p > 0.0 ? p : 0.0) / n;
}

static double rmsCh(const float* buf, uint32_t start, uint32_t n, int ch)
{
    double acc = 0.0;
    for (uint32_t i = 0; i < n; i++) {
        double v = buf[2 * (start + i) + ch];
        acc += v * v;
    }
    return sqrt(acc / n);
}

static double meanCh(const float* buf, uint32_t start, uint32_t n, int ch)
{
    double acc = 0.0;
    for (uint32_t i = 0; i < n; i++) acc += buf[2 * (start + i) + ch];
    return acc / n;
}

// RMS of mid or side signal over [start, start+n).
static double msRMS(const float* buf, uint32_t start, uint32_t n, bool side)
{
    double acc = 0.0;
    for (uint32_t i = 0; i < n; i++) {
        double l = buf[2 * (start + i)], r = buf[2 * (start + i) + 1];
        double v = side ? 0.5 * (l - r) : 0.5 * (l + r);
        acc += v * v;
    }
    return sqrt(acc / n);
}

static double toDB(double x) { return 20.0 * log10(x); }

// ---------------------------------------------------------------------------
// 1) Neutral params -> bit-identical passthrough + IsActive.

static void testNeutralPassthrough(void)
{
    printf("case: neutral passthrough\n");
    AEDSPState* st = AEDSPCreate(FS);
    EXPECT(!AEDSPIsActive(st), "neutral state reports inactive");

    AEDSPParams p = AEDSPParamsNeutral();
    AEDSPSetParams(st, &p);

    const uint32_t n = 4096;
    float* buf = allocStereo(n);
    float* ref = allocStereo(n);
    noiseFill(buf, n, 0.8f, 12345u, false);
    memcpy(ref, buf, (size_t)n * 2 * sizeof(float));
    processBlocks(st, buf, n);
    EXPECT(memcmp(buf, ref, (size_t)n * 2 * sizeof(float)) == 0,
           "4096 frames of noise are bit-identical through neutral chain");

    p.bassEnabled = true;
    AEDSPSetParams(st, &p);
    EXPECT(AEDSPIsActive(st), "IsActive true once an effect is enabled");
    p = AEDSPParamsNeutral();
    AEDSPSetParams(st, &p);
    EXPECT(!AEDSPIsActive(st), "IsActive false again after reset");

    free(buf); free(ref);
    AEDSPDestroy(st);
}

// ---------------------------------------------------------------------------
// 2) Bass shelf response.

static double toneGainDB(const AEDSPParams* p, double freq, double amp)
{
    AEDSPState* st = AEDSPCreate(FS);
    AEDSPSetParams(st, p);
    const uint32_t total = WARM + MEAS;
    float* in = allocStereo(total);
    float* out = allocStereo(total);
    sineFill(in, total, freq, amp, freq, amp);
    memcpy(out, in, (size_t)total * 2 * sizeof(float));
    processBlocks(st, out, total);
    double gi = goertzelAmp(in, WARM, MEAS, 0, freq);
    double go = goertzelAmp(out, WARM, MEAS, 0, freq);
    free(in); free(out);
    AEDSPDestroy(st);
    return toDB(go / gi);
}

static void testBassShelf(void)
{
    printf("case: bass shelf (+9 dB @ 100 Hz)\n");
    AEDSPParams p = AEDSPParamsNeutral();
    p.bassEnabled = true;
    p.bassGainDB = 9.0f;
    p.bassFrequency = 100.0f;

    double g50 = toneGainDB(&p, 50.0, 0.25);
    double g5k = toneGainDB(&p, 5000.0, 0.25);
    printf("  measured: 50 Hz %+0.2f dB, 5 kHz %+0.3f dB\n", g50, g5k);
    EXPECT(g50 >= 8.0 && g50 <= 10.0, "50 Hz sine gains 8-10 dB");
    EXPECT(fabs(g5k) < 0.5, "5 kHz sine changes < 0.5 dB");
}

// ---------------------------------------------------------------------------
// 3) Width.

static void testWidth(void)
{
    printf("case: width\n");
    const uint32_t total = WARM + MEAS;
    float* in = allocStereo(total);
    float* out = allocStereo(total);
    sineFill(in, total, 500.0, 0.4, 750.0, 0.3);
    double sideRef = msRMS(in, WARM, MEAS, true);
    double midRef = msRMS(in, WARM, MEAS, false);

    // width 0 -> strictly mono output
    AEDSPParams p = AEDSPParamsNeutral();
    p.widthPercent = 0.0f;
    AEDSPState* st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);
    memcpy(out, in, (size_t)total * 2 * sizeof(float));
    processBlocks(st, out, total);
    float maxDiff = 0.0f;
    for (uint32_t i = WARM; i < total; i++) {
        float d = fabsf(out[2 * i] - out[2 * i + 1]);
        if (d > maxDiff) maxDiff = d;
    }
    EXPECT(maxDiff == 0.0f, "width 0: L and R identical (mono)");
    AEDSPDestroy(st);

    // width 200 -> side RMS ~2x, mid unchanged
    p.widthPercent = 200.0f;
    st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);
    memcpy(out, in, (size_t)total * 2 * sizeof(float));
    processBlocks(st, out, total);
    double side2 = msRMS(out, WARM, MEAS, true);
    double mid2 = msRMS(out, WARM, MEAS, false);
    printf("  side x%.3f (want 2 +/-10%%), mid x%.4f (want 1 +/-2%%)\n",
           side2 / sideRef, mid2 / midRef);
    EXPECT(fabs(side2 / sideRef - 2.0) < 0.2, "width 200: side RMS ~2x");
    EXPECT(fabs(mid2 / midRef - 1.0) < 0.02, "width 200: mid RMS unchanged");
    AEDSPDestroy(st);

    free(in); free(out);
}

// ---------------------------------------------------------------------------
// 4) Balance.

static void testBalance(void)
{
    printf("case: balance\n");
    const uint32_t total = WARM + MEAS;
    float* in = allocStereo(total);
    float* out = allocStereo(total);
    sineFill(in, total, 500.0, 0.3, 500.0, 0.3);
    double refRMS = rmsCh(in, WARM, MEAS, 0);

    for (int dir = 0; dir < 2; dir++) {
        AEDSPParams p = AEDSPParamsNeutral();
        p.balance = dir == 0 ? -1.0f : 1.0f;
        int muted = dir == 0 ? 1 : 0;    // -1 mutes right, +1 mutes left
        int kept = 1 - muted;
        AEDSPState* st = AEDSPCreate(FS);
        AEDSPSetParams(st, &p);
        memcpy(out, in, (size_t)total * 2 * sizeof(float));
        processBlocks(st, out, total);
        double mutedRMS = rmsCh(out, WARM, MEAS, muted);
        double keptRMS = rmsCh(out, WARM, MEAS, kept);
        EXPECT(mutedRMS < 1.0e-3,
               dir == 0 ? "balance -1: right < -60 dBFS"
                        : "balance +1: left < -60 dBFS");
        EXPECT(fabs(toDB(keptRMS / refRMS)) < 0.1,
               dir == 0 ? "balance -1: left unchanged"
                        : "balance +1: right unchanged");
        AEDSPDestroy(st);
    }
    free(in); free(out);
}

// ---------------------------------------------------------------------------
// 5) Crossfeed.

static void testCrossfeed(void)
{
    printf("case: crossfeed (4.5 dB / 700 Hz)\n");
    AEDSPParams p = AEDSPParamsNeutral();
    p.crossfeedEnabled = true;
    p.crossfeedFeedDB = 4.5f;
    p.crossfeedCutoffHz = 700.0f;
    const uint32_t total = WARM + MEAS;
    float* in = allocStereo(total);
    float* out = allocStereo(total);

    // (a) mono passthrough at 100 Hz and 5 kHz
    double monoFreqs[2] = { 100.0, 5000.0 };
    for (int f = 0; f < 2; f++) {
        AEDSPState* st = AEDSPCreate(FS);
        AEDSPSetParams(st, &p);
        sineFill(in, total, monoFreqs[f], 0.4, monoFreqs[f], 0.4);
        memcpy(out, in, (size_t)total * 2 * sizeof(float));
        processBlocks(st, out, total);
        double gi = goertzelAmp(in, WARM, MEAS, 0, monoFreqs[f]);
        double go = goertzelAmp(out, WARM, MEAS, 0, monoFreqs[f]);
        char msg[80];
        snprintf(msg, sizeof(msg), "mono %g Hz passes within 0.1 dB",
                 monoFreqs[f]);
        EXPECT(fabs(toDB(go / gi)) < 0.1, msg);
        AEDSPDestroy(st);
    }

    // (b) hard-panned leak: strong at 200 Hz, weak at 8 kHz
    double leak[2];
    double ipsiGainDB = 0;   // L-channel (ipsilateral) gain at 200 Hz
    double panFreqs[2] = { 200.0, 8000.0 };
    for (int f = 0; f < 2; f++) {
        AEDSPState* st = AEDSPCreate(FS);
        AEDSPSetParams(st, &p);
        sineFill(in, total, panFreqs[f], 0.5, panFreqs[f], 0.0); // left only
        memcpy(out, in, (size_t)total * 2 * sizeof(float));
        processBlocks(st, out, total);
        leak[f] = goertzelAmp(out, WARM, MEAS, 1, panFreqs[f]);
        if (f == 0) {
            double inL = goertzelAmp(in, WARM, MEAS, 0, panFreqs[f]);
            double outL = goertzelAmp(out, WARM, MEAS, 0, panFreqs[f]);
            ipsiGainDB = toDB(outL / inL);
        }
        AEDSPDestroy(st);
    }
    printf("  leak 200 Hz %.1f dBFS, 8 kHz rel %.1f dB, ipsi-L %.1f dB\n",
           toDB(leak[0]), toDB(leak[1] / leak[0]), ipsiGainDB);
    EXPECT(toDB(leak[0]) > -30.0, "200 Hz left-only leaks into R > -30 dBFS");
    EXPECT(toDB(leak[1] / leak[0]) < -25.0,
           "8 kHz leak < -25 dB relative to 200 Hz leak");
    // Sign check: a correct crossfeed subtracts the ipsilateral lowpass from
    // its own channel (outL = L·(1−g)), so the left channel is ATTENUATED. An
    // L/R sign-swapped network would add it (L·(1+g)) and boost L instead.
    // This kills the sign-swap mutant that the leak-magnitude checks miss
    // (Goertzel amplitude is sign-blind).
    EXPECT(ipsiGainDB < -1.0, "200 Hz left-only: ipsilateral L is attenuated (not boosted)");
    free(in); free(out);
}

// ---------------------------------------------------------------------------
// 6) Tube: harmonics appear, level matched, no DC.

static void testTube(void)
{
    printf("case: tube saturator (amount 1.0, -6 dBFS 1 kHz)\n");
    const uint32_t total = WARM + MEAS;
    float* in = allocStereo(total);
    float* out = allocStereo(total);
    sineFill(in, total, 1000.0, 0.5, 1000.0, 0.5);

    // Disabled baseline harmonic floor (pure sine, integer bins).
    double h2b = goertzelAmp(in, WARM, MEAS, 0, 2000.0);
    double h3b = goertzelAmp(in, WARM, MEAS, 0, 3000.0);
    double base = h2b > h3b ? h2b : h3b;
    if (base < 1.0e-12) base = 1.0e-12;

    AEDSPParams p = AEDSPParamsNeutral();
    p.tubeEnabled = true;
    p.tubeAmount = 1.0f;
    AEDSPState* st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);
    memcpy(out, in, (size_t)total * 2 * sizeof(float));
    processBlocks(st, out, total);

    double h2 = goertzelAmp(out, WARM, MEAS, 0, 2000.0);
    double h3 = goertzelAmp(out, WARM, MEAS, 0, 3000.0);
    double harm = h2 > h3 ? h2 : h3;
    double rmsIn = rmsCh(in, WARM, MEAS, 0);
    double rmsOut = rmsCh(out, WARM, MEAS, 0);
    double dc = fabs(meanCh(out, WARM, MEAS, 0));
    printf("  harmonic rise %.1f dB, level %+0.2f dB, DC %.1f dBFS\n",
           toDB(harm / base), toDB(rmsOut / rmsIn), toDB(dc + 1e-15));
    EXPECT(toDB(harm / base) >= 20.0,
           "2nd/3rd harmonic rises >= 20 dB over disabled case");
    EXPECT(fabs(toDB(rmsOut / rmsIn)) <= 1.0, "output RMS within +/-1 dB");
    EXPECT(dc < 1.0e-3, "DC < -60 dBFS after DC blocker");

    free(in); free(out);
    AEDSPDestroy(st);
}

// ---------------------------------------------------------------------------
// 7) Clarity: adds HF energy, leaves lows alone.

static double bandEnergy(const float* buf, uint32_t start, uint32_t n,
                         double f0, double f1, double step)
{
    double e = 0.0;
    for (double f = f0; f <= f1 + 0.5; f += step) {
        double a = goertzelAmp(buf, start, n, 0, f);
        e += a * a;
    }
    return e;
}

// Single-tone fundamental gain (dB) for clarity at a given amount. A small
// amplitude keeps the tanh sparkle path effectively linear so the measured
// number reflects the real fundamental-band lift (the shelf), not compression.
static double clarityToneDB(float amount, double freq)
{
    AEDSPParams p = AEDSPParamsNeutral();
    p.clarityEnabled = true;
    p.clarityAmount = amount;
    AEDSPState* st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);
    const uint32_t total = WARM + MEAS;
    float* in = allocStereo(total);
    float* out = allocStereo(total);
    sineFill(in, total, freq, 0.1, freq, 0.1);
    memcpy(out, in, (size_t)total * 2 * sizeof(float));
    processBlocks(st, out, total);
    double gi = goertzelAmp(in, WARM, MEAS, 0, freq);
    double go = goertzelAmp(out, WARM, MEAS, 0, freq);
    free(in); free(out);
    AEDSPDestroy(st);
    return toDB(go / gi);
}

static void testClarity(void)
{
    printf("case: clarity exciter (presence lift @ ~4 kHz)\n");

    // (a) amount 1.0: strong, audible in-band lift; flat below 1.5 kHz.
    double f500  = clarityToneDB(1.0f, 500.0);
    double f1k   = clarityToneDB(1.0f, 1000.0);
    double f5k   = clarityToneDB(1.0f, 5000.0);
    double f8k   = clarityToneDB(1.0f, 8000.0);
    printf("  amount 1.0: 500 Hz %+0.2f, 1 kHz %+0.2f, 5 kHz %+0.2f, "
           "8 kHz %+0.2f dB\n", f500, f1k, f5k, f8k);
    EXPECT(f5k >= 5.0, "amount 1.0: 5 kHz gains >= +5 dB (audible)");
    EXPECT(f8k >= 5.0, "amount 1.0: 8 kHz gains >= +5 dB (audible)");
    EXPECT(fabs(f500) < 0.5, "amount 1.0: 500 Hz changes < 0.5 dB");
    EXPECT(fabs(f1k) < 0.5, "amount 1.0: 1 kHz changes < 0.5 dB");

    // (b) amount 0.5 (the user's setting): still clearly audible in-band.
    double h5k = clarityToneDB(0.5f, 5000.0);
    double h8k = clarityToneDB(0.5f, 8000.0);
    double h500 = clarityToneDB(0.5f, 500.0);
    printf("  amount 0.5: 500 Hz %+0.2f, 5 kHz %+0.2f, 8 kHz %+0.2f dB\n",
           h500, h5k, h8k);
    EXPECT(h5k >= 2.5, "amount 0.5: 5 kHz gains >= +2.5 dB (audible at 50%)");
    EXPECT(h8k >= 2.5, "amount 0.5: 8 kHz gains >= +2.5 dB (audible at 50%)");
    EXPECT(fabs(h500) < 0.5, "amount 0.5: 500 Hz changes < 0.5 dB");

    // (c) broadband: HF band clearly lifted, sub-1.5 kHz essentially untouched.
    const uint32_t total = WARM + MEAS;
    float* in = allocStereo(total);
    float* out = allocStereo(total);
    noiseFill(in, total, 0.3f, 777u, true);
    AEDSPParams p = AEDSPParamsNeutral();
    p.clarityEnabled = true;
    p.clarityAmount = 1.0f;
    AEDSPState* st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);
    memcpy(out, in, (size_t)total * 2 * sizeof(float));
    processBlocks(st, out, total);
    double lowDry = bandEnergy(in, WARM, MEAS, 200.0, 1400.0, 200.0);
    double lowWet = bandEnergy(out, WARM, MEAS, 200.0, 1400.0, 200.0);
    double hiDry = bandEnergy(in, WARM, MEAS, 8500.0, 15500.0, 500.0);
    double hiWet = bandEnergy(out, WARM, MEAS, 8500.0, 15500.0, 500.0);
    double lowDB = 10.0 * log10(lowWet / lowDry);
    double hiDB = 10.0 * log10(hiWet / hiDry);
    printf("  broadband: 8-16 kHz %+0.2f dB, <1.5 kHz %+0.3f dB\n", hiDB, lowDB);
    EXPECT(hiDB > 5.0, "8-16 kHz band gains > +5 dB");
    EXPECT(fabs(lowDB) < 0.5, "below 1.5 kHz changes < 0.5 dB");

    free(in); free(out);
    AEDSPDestroy(st);
}

// ---------------------------------------------------------------------------
// 8) Stability on 30 s of full-scale square, then convergence to passthrough.

static float squareAt(uint64_t n)
{
    return (n % 480u) < 240u ? 1.0f : -1.0f;   // 100 Hz at 48 kHz
}

// A different full-scale square for the right channel so the stress signal is
// genuinely stereo: crossfeed (needs L≠R for a nonzero cross term) and width
// 200 (multiplies the side channel, which is 0 for mono) are otherwise
// arithmetically inert and never exercised under stress.
static float squareAtR(uint64_t n)
{
    return (n % 654u) < 327u ? 1.0f : -1.0f;   // ~73 Hz, coprime-ish period
}

static void testStability(void)
{
    printf("case: 30 s full-scale square, all effects maxed\n");
    AEDSPParams p = AEDSPParamsNeutral();
    p.bassEnabled = true; p.bassGainDB = 12.0f; p.bassFrequency = 200.0f;
    p.tubeEnabled = true; p.tubeAmount = 1.0f;
    p.clarityEnabled = true; p.clarityAmount = 1.0f;
    p.crossfeedEnabled = true; p.crossfeedFeedDB = 2.0f;
    p.crossfeedCutoffHz = 1200.0f;
    p.widthPercent = 200.0f;
    p.balance = -0.5f;

    AEDSPState* st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);

    float block[BLOCK * 2];
    uint64_t n = 0;
    bool finiteOK = true, boundOK = true;
    // The DSP core is intentionally NOT self-limiting: with bass +12 dB (4x),
    // width 200 on anti-correlated channels, and crossfeed all stacked on a
    // full-scale square, a steady peak of ~6 (≈15.6 dBFS) is legitimate gain,
    // not instability. The master limiter downstream in the pipeline bounds
    // the final output. So the ceiling here only needs to catch genuine
    // runaway (a diverging recursive filter reaches thousands/Inf); the
    // real stability proof is the no-growth check below.
    const float kSaneCeiling = 16.0f;
    // Track peak over the first vs. last third to prove the recursive state
    // (biquads, one-poles, DC blocker, smoothers) does not accumulate.
    float earlyPeak = 0.0f, latePeak = 0.0f;
    const uint64_t thirtySec = 30u * 48000u;
    const uint64_t earlyEnd = thirtySec / 3u;
    const uint64_t lateStart = (2u * thirtySec) / 3u;
    while (n < thirtySec) {
        for (uint32_t i = 0; i < BLOCK; i++) {
            block[2 * i] = squareAt(n + i);
            block[2 * i + 1] = squareAtR(n + i);
        }
        AEDSPProcess(st, block, BLOCK);
        for (uint32_t i = 0; i < BLOCK * 2; i++) {
            float a = fabsf(block[i]);
            if (!isfinite(block[i])) finiteOK = false;
            if (a > kSaneCeiling) boundOK = false;
            uint64_t frame = n + (i / 2);
            if (frame < earlyEnd && a > earlyPeak) earlyPeak = a;
            else if (frame >= lateStart && a > latePeak) latePeak = a;
        }
        n += BLOCK;
    }
    printf("  early peak %.3f, late peak %.3f\n", earlyPeak, latePeak);
    EXPECT(finiteOK, "no NaN/Inf across 30 s (all effects maxed, stereo)");
    EXPECT(boundOK, "output stays below sane ceiling (no runaway)");
    // No-growth: late peak must not exceed the early peak by more than 1% —
    // a diverging filter would show monotonic growth here.
    EXPECT(latePeak <= earlyPeak * 1.01f + 1e-4f, "peak does not grow over 30 s (stable)");

    // Neutral params mid-stream: converge back to passthrough within 100 ms.
    AEDSPParams neutral = AEDSPParamsNeutral();
    AEDSPSetParams(st, &neutral);
    const uint64_t switchAt = n;
    double maxErr = 0.0;
    while (n < switchAt + 12000u) {          // 0.25 s more
        for (uint32_t i = 0; i < BLOCK; i++) {
            block[2 * i] = squareAt(n + i);
            block[2 * i + 1] = squareAtR(n + i);
        }
        AEDSPProcess(st, block, BLOCK);
        for (uint32_t i = 0; i < BLOCK; i++) {
            if (n + i < switchAt + 4800u) continue;   // allow 100 ms
            double e0 = fabs(block[2 * i] - squareAt(n + i));
            double e1 = fabs(block[2 * i + 1] - squareAtR(n + i));
            if (e0 > maxErr) maxErr = e0;
            if (e1 > maxErr) maxErr = e1;
        }
        n += BLOCK;
    }
    printf("  max relative error after 100 ms: %.2e\n", maxErr);
    EXPECT(maxErr < 1.0e-3, "converges to passthrough within 100 ms");
    AEDSPDestroy(st);
}

// ---------------------------------------------------------------------------
// 9) Param smoothing: bass gain toggles must not click.

static float maxConsecDiff(const float* buf, uint32_t start, uint32_t n)
{
    float maxd = 0.0f;
    for (uint32_t i = start + 1; i < start + n; i++) {
        float d = fabsf(buf[2 * i] - buf[2 * (i - 1)]);
        if (d > maxd) maxd = d;
    }
    return maxd;
}

static void testSmoothing(void)
{
    printf("case: param smoothing (bass 0 <-> 12 dB toggles)\n");
    AEDSPParams p = AEDSPParamsNeutral();
    p.bassEnabled = true;
    p.bassGainDB = 12.0f;
    p.bassFrequency = 200.0f;

    const uint32_t nToggleBlocks = 96;
    const uint32_t total = WARM + nToggleBlocks * BLOCK;
    float* buf = allocStereo(total);

    // Steady reference: gain fixed at 12 dB.
    AEDSPState* st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);
    sineFill(buf, total, 100.0, 0.25, 100.0, 0.25);
    processBlocks(st, buf, total);
    float steadyMax = maxConsecDiff(buf, WARM, total - WARM);
    AEDSPDestroy(st);

    // Toggle run: alternate 0 / 12 dB between blocks.
    st = AEDSPCreate(FS);
    AEDSPSetParams(st, &p);
    sineFill(buf, total, 100.0, 0.25, 100.0, 0.25);
    processBlocks(st, buf, WARM);
    for (uint32_t b = 0; b < nToggleBlocks; b++) {
        p.bassGainDB = (b & 1u) ? 12.0f : 0.0f;
        AEDSPSetParams(st, &p);
        AEDSPProcess(st, buf + 2 * (WARM + b * BLOCK), BLOCK);
    }
    float toggleMax = maxConsecDiff(buf, WARM - 1, total - WARM + 1);
    AEDSPDestroy(st);

    printf("  steady max diff %.4f, toggling max diff %.4f\n",
           (double)steadyMax, (double)toggleMax);
    EXPECT(steadyMax < 0.05f, "steady-state consecutive diff sane");
    EXPECT(toggleMax < steadyMax + 0.05f,
           "toggling adds no jump > 0.05 over steady case");
    free(buf);
}

// ---------------------------------------------------------------------------
// 10) Concurrent SetParams hammer while processing.

static AEDSPState* gST;
static _Atomic bool gDone;

static void* hammer(void* arg)
{
    (void)arg;
    uint32_t s = 99u;
    while (!atomic_load_explicit(&gDone, memory_order_relaxed)) {
        AEDSPParams p;
        p.bassEnabled = (lcgNext(&s) >> 16) & 1u;
        p.bassGainDB = (float)(lcgNext(&s) % 1201u) / 100.0f;
        p.bassFrequency = 40.0f + (float)(lcgNext(&s) % 161u);
        p.tubeEnabled = (lcgNext(&s) >> 16) & 1u;
        p.tubeAmount = (float)(lcgNext(&s) % 101u) / 100.0f;
        p.clarityEnabled = (lcgNext(&s) >> 16) & 1u;
        p.clarityAmount = (float)(lcgNext(&s) % 101u) / 100.0f;
        p.crossfeedEnabled = (lcgNext(&s) >> 16) & 1u;
        p.crossfeedFeedDB = 2.0f + (float)(lcgNext(&s) % 601u) / 100.0f;
        p.crossfeedCutoffHz = 400.0f + (float)(lcgNext(&s) % 801u);
        p.widthPercent = (float)(lcgNext(&s) % 201u);
        p.balance = ((float)(lcgNext(&s) % 201u) - 100.0f) / 100.0f;
        AEDSPSetParams(gST, &p);
    }
    return NULL;
}

static double nowSec(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + 1.0e-9 * (double)ts.tv_nsec;
}

static void testThreadHandoff(void)
{
    printf("case: 2 s SetParams hammer vs render thread\n");
    gST = AEDSPCreate(FS);
    atomic_store(&gDone, false);
    pthread_t th;
    pthread_create(&th, NULL, hammer, NULL);

    float block[BLOCK * 2];
    uint32_t seed = 4242u;
    bool ok = true;
    double t0 = nowSec();
    while (nowSec() - t0 < 2.0) {
        for (uint32_t i = 0; i < BLOCK * 2; i++)
            block[i] = lcgFloat(&seed, 0.9f);
        AEDSPProcess(gST, block, BLOCK);
        for (uint32_t i = 0; i < BLOCK * 2; i++) {
            if (!isfinite(block[i]) || fabsf(block[i]) > 100.0f) ok = false;
        }
    }
    atomic_store(&gDone, true);
    pthread_join(th, NULL);
    EXPECT(ok, "no NaN/Inf/blowup under concurrent param hammering");
    AEDSPDestroy(gST);
}

// ---------------------------------------------------------------------------

int main(void)
{
    testNeutralPassthrough();
    testBassShelf();
    testWidth();
    testBalance();
    testCrossfeed();
    testTube();
    testClarity();
    testStability();
    testSmoothing();
    testThreadHandoff();
    if (failures > 0) {
        printf("\n%d FAILURE(S)\n", failures);
        return 1;
    }
    printf("\nall DSP tests passed\n");
    return 0;
}
