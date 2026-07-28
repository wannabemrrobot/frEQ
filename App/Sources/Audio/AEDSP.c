// AEDSP.c — custom DSP effect suite for FrEQ (see AEDSP.h for the contract).
//
// Design notes:
//   - Parameter handoff: double-buffered AEDSPParams guarded by an _Atomic
//     sequence counter (single writer = control thread). The render thread
//     snapshots at block start; a torn read is detected by re-checking the
//     counter and simply retried/deferred to the next block. No locks, no
//     allocation, no syscalls on the render path.
//   - On a param change the render thread recomputes coefficient/gain
//     *targets* once, then every audible value is smoothed per sample with a
//     ~10 ms one-pole ramp (snapped to the target once within 1e-6 so the
//     chain provably settles).
//   - When all effects are off and width==100 / balance==0, and every
//     smoother has settled, Process flips into a bypassed state that
//     early-outs without touching the buffer (bit-exact passthrough).
//   - Denormal protection: a tiny DC offset (1e-15) is folded into every
//     recursive filter state update.
//   - Crossfeed: the Meier-style network from the header
//         outL = L + g*(lpR - lpL); outR = R + g*(lpL - lpR)
//     is implemented verbatim (mono-safe by construction). LP1 is realized
//     as two cascaded one-pole sections at the cutoff for a usefully steep
//     high-frequency rolloff; the network topology is unchanged.

#include "AEDSP.h"

#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>

static const double kPi = 3.14159265358979323846;
static const float  kDenorm = 1.0e-15f;      // anti-denormal offset
static const float  kSnapEps = 1.0e-6f;      // smoother snap threshold
static const float  kShelfSlope = 0.9f;      // RBJ low-shelf S
static const double kSmoothTauSec = 0.010;   // ~10 ms parameter ramps
static const double kDCBlockHz = 10.0;       // tube DC blocker corner
static const double kClarityHPHz = 4000.0;   // clarity corner (presence region)
static const double kClarityShelfS = 0.9;    // clarity high-shelf slope
static const float  kTubeMixMax = 0.4f;      // wet mix at amount == 1
static const float  kClarityShelfDBMax = 9.0f; // high-shelf lift at amount == 1
                                             // (~+6 dB @5 kHz, ~+8 dB @8 kHz)
static const float  kClaritySparkleMax = 0.18f; // tanh-exciter sparkle mix @ 1

typedef struct {
    _Atomic uint32_t seq;    // bumped by 2 per publish; (seq>>1)&1 = live box
    AEDSPParams box[2];      // written by the control thread only
} AEParamShare;

struct AEDSPState {
    double fs;
    float  smoothC;          // per-sample one-pole coefficient (~10 ms)
    float  dcPole;           // tube DC blocker feedback (~10 Hz)
    // Clarity exciter tap: 2nd-order RBJ (Butterworth) highpass biquad @
    // 4 kHz. Unity passband, 12 dB/oct rolloff. Fixed by fs; feeds the tanh
    // shaper for harmonic sparkle only. The audible fundamental lift is the
    // smoothed high-shelf below (mixing a highpass with dry would notch the
    // transition band; a shelf sums monotonically and stays flat below).
    float  clarHb0, clarHb1, clarHb2, clarHa1, clarHa2;

    // ---- control <-> render handoff
    AEParamShare share;
    uint32_t     lastSeq;    // render-side: last consumed sequence value
    AEDSPParams  cur;        // render-side snapshot
    _Atomic bool activeFlag; // for AEDSPIsActive (control-side view)

    bool bypassed;           // render-side: settled and fully neutral
    bool activeTarget;       // render-side: current params are non-neutral

    // ---- smoothing targets
    // The bass biquad runs in double precision: a low-frequency shelf at
    // 48 kHz is sensitive enough to coefficient quantization that float32
    // coefficients skew the sub-100 Hz response by ~1 dB.
    double tB0, tB1, tB2, tA1, tA2;                      // bass biquad
    float tTubeMix, tTubeDrive, tTubeBias, tTubeMakeup;  // tube
    // clarity: high-shelf biquad (fundamental lift) + sparkle mix/drive
    double tCS0, tCS1, tCS2, tCSa1, tCSa2;
    float tClarMix, tClarDrive;
    float tXfG, tXfC;                                    // crossfeed
    float tSide, tGL, tGR;                               // width / balance

    // ---- smoothed live values (same layout as the targets)
    double b0, b1, b2, a1, a2;
    float tubeMix, tubeDrive, tubeBias, tubeMakeup;
    double cs0, cs1, cs2, csa1, csa2;
    float clarMix, clarDrive;
    float xfG, xfC;
    float side, gL, gR;

    // ---- filter state, [0]=L [1]=R
    double bassZ1[2], bassZ2[2]; // bass biquad, transposed direct form II
    float dcX[2], dcY[2];        // tube DC blocker
    double clarSz1[2], clarSz2[2];// clarity high-shelf biquad (double, TDF-II)
    float clarHz1[2], clarHz2[2];// clarity HP exciter tap biquad (TDF-II)
    float xfLP1[2], xfLP2[2];    // crossfeed cascaded one-pole lowpasses
};

// ---------------------------------------------------------------------------
// Params

AEDSPParams AEDSPParamsNeutral(void)
{
    AEDSPParams p;
    p.bassEnabled = false;
    p.bassGainDB = 0.0f;
    p.bassFrequency = 100.0f;
    p.tubeEnabled = false;
    p.tubeAmount = 0.0f;
    p.clarityEnabled = false;
    p.clarityAmount = 0.0f;
    p.crossfeedEnabled = false;
    p.crossfeedFeedDB = 4.5f;
    p.crossfeedCutoffHz = 700.0f;
    p.widthPercent = 100.0f;
    p.balance = 0.0f;
    return p;
}

static float clampf(float v, float lo, float hi)
{
    if (!(v == v)) return lo;                 // NaN -> safe end of the range
    return v < lo ? lo : (v > hi ? hi : v);
}

static bool paramsActive(const AEDSPParams* p)
{
    return p->bassEnabled || p->tubeEnabled || p->clarityEnabled ||
           p->crossfeedEnabled || p->widthPercent != 100.0f ||
           p->balance != 0.0f;
}

// ---------------------------------------------------------------------------
// Target computation (render thread, once per parameter change)

// RMS-calibrates the tube wet path so a sine at amplitude 1/sqrt(2) keeps
// its level through the shaper. Bounded 64-iteration loop: RT-safe.
static float tubeMakeupFor(float drive, float bias)
{
    const int n = 64;
    const float tb = tanhf(bias);
    float acc = 0.0f;
    for (int i = 0; i < n; i++) {
        float s = 0.70710678f * sinf((float)(2.0 * kPi * i / n));
        float y = tanhf(drive * s + bias) - tb;
        acc += y * y;
    }
    float rms = sqrtf(acc / (float)n);
    if (rms < 1.0e-9f) return 1.0f;
    return 0.5f / rms;                        // input RMS is 0.7071/sqrt(2)
}

static void computeTargets(AEDSPState* st)
{
    const AEDSPParams* p = &st->cur;

    // Bass: RBJ cookbook low shelf, S = 0.9, identical for both channels.
    if (p->bassEnabled) {
        double gain = clampf(p->bassGainDB, 0.0f, 12.0f);
        double f0 = clampf(p->bassFrequency, 40.0f, 200.0f);
        double A = pow(10.0, gain / 40.0);
        double w0 = 2.0 * kPi * f0 / st->fs;
        double cw = cos(w0);
        double alpha = sin(w0) / 2.0 *
            sqrt((A + 1.0 / A) * (1.0 / kShelfSlope - 1.0) + 2.0);
        double sA2 = 2.0 * sqrt(A) * alpha;
        double b0 = A * ((A + 1.0) - (A - 1.0) * cw + sA2);
        double b1 = 2.0 * A * ((A - 1.0) - (A + 1.0) * cw);
        double b2 = A * ((A + 1.0) - (A - 1.0) * cw - sA2);
        double a0 = (A + 1.0) + (A - 1.0) * cw + sA2;
        double a1 = -2.0 * ((A - 1.0) + (A + 1.0) * cw);
        double a2 = (A + 1.0) + (A - 1.0) * cw - sA2;
        st->tB0 = b0 / a0;
        st->tB1 = b1 / a0;
        st->tB2 = b2 / a0;
        st->tA1 = a1 / a0;
        st->tA2 = a2 / a0;
    } else {
        st->tB0 = 1.0; st->tB1 = 0.0; st->tB2 = 0.0;
        st->tA1 = 0.0; st->tA2 = 0.0;
    }

    // Tube: drive/bias/mix all scale with amount; makeup keeps the wet path
    // level-matched. Disabled -> wet mix fades to zero.
    if (p->tubeEnabled) {
        float a = clampf(p->tubeAmount, 0.0f, 1.0f);
        st->tTubeDrive = 1.0f + 0.5f * a;
        st->tTubeBias = 0.2f * a;
        st->tTubeMix = kTubeMixMax * a;
        st->tTubeMakeup = tubeMakeupFor(st->tTubeDrive, st->tTubeBias);
    } else {
        st->tTubeDrive = 1.0f;
        st->tTubeBias = 0.0f;
        st->tTubeMix = 0.0f;
        st->tTubeMakeup = 1.0f;
    }

    // Clarity: presence-region high-shelf (real fundamental lift, unity below
    // ~1.5 kHz) plus a small tanh exciter for harmonic sparkle. Shelf gain and
    // sparkle mix scale with amount; disabled -> flat shelf + zero sparkle.
    if (p->clarityEnabled) {
        float a = clampf(p->clarityAmount, 0.0f, 1.0f);
        double gain = (double)(kClarityShelfDBMax * a);
        double A = pow(10.0, gain / 40.0);
        double w0 = 2.0 * kPi * kClarityHPHz / st->fs;
        double cw = cos(w0);
        double alpha = sin(w0) / 2.0 *
            sqrt((A + 1.0 / A) * (1.0 / kClarityShelfS - 1.0) + 2.0);
        double sA2 = 2.0 * sqrt(A) * alpha;
        double b0 =  A * ((A + 1.0) + (A - 1.0) * cw + sA2);
        double b1 = -2.0 * A * ((A - 1.0) + (A + 1.0) * cw);
        double b2 =  A * ((A + 1.0) + (A - 1.0) * cw - sA2);
        double a0 =      (A + 1.0) - (A - 1.0) * cw + sA2;
        double a1 =  2.0 * ((A - 1.0) - (A + 1.0) * cw);
        double a2 =      (A + 1.0) - (A - 1.0) * cw - sA2;
        st->tCS0 = b0 / a0;
        st->tCS1 = b1 / a0;
        st->tCS2 = b2 / a0;
        st->tCSa1 = a1 / a0;
        st->tCSa2 = a2 / a0;
        st->tClarDrive = 1.0f + a;
        st->tClarMix = kClaritySparkleMax * a;
    } else {
        st->tCS0 = 1.0; st->tCS1 = 0.0; st->tCS2 = 0.0;
        st->tCSa1 = 0.0; st->tCSa2 = 0.0;
        st->tClarDrive = 1.0f;
        st->tClarMix = 0.0f;
    }

    // Crossfeed: g = 10^(-feedDB/20); cutoff via one-pole coefficient.
    {
        double cutoff = clampf(p->crossfeedCutoffHz, 400.0f, 1200.0f);
        st->tXfC = (float)(1.0 - exp(-2.0 * kPi * cutoff / st->fs));
        if (p->crossfeedEnabled) {
            float feed = clampf(p->crossfeedFeedDB, 2.0f, 8.0f);
            st->tXfG = powf(10.0f, -feed / 20.0f);
        } else {
            st->tXfG = 0.0f;
        }
    }

    // Width / balance.
    st->tSide = clampf(p->widthPercent, 0.0f, 200.0f) / 100.0f;
    float bal = clampf(p->balance, -1.0f, 1.0f);
    st->tGL = bal > 0.0f ? 1.0f - bal : 1.0f;
    st->tGR = bal < 0.0f ? 1.0f + bal : 1.0f;

    st->activeTarget = paramsActive(p);
}

static void snapAllToTargets(AEDSPState* st)
{
    st->b0 = st->tB0; st->b1 = st->tB1; st->b2 = st->tB2;
    st->a1 = st->tA1; st->a2 = st->tA2;
    st->tubeMix = st->tTubeMix; st->tubeDrive = st->tTubeDrive;
    st->tubeBias = st->tTubeBias; st->tubeMakeup = st->tTubeMakeup;
    st->cs0 = st->tCS0; st->cs1 = st->tCS1; st->cs2 = st->tCS2;
    st->csa1 = st->tCSa1; st->csa2 = st->tCSa2;
    st->clarMix = st->tClarMix; st->clarDrive = st->tClarDrive;
    st->xfG = st->tXfG; st->xfC = st->tXfC;
    st->side = st->tSide; st->gL = st->tGL; st->gR = st->tGR;
}

static bool allSettled(const AEDSPState* st)
{
    return st->b0 == st->tB0 && st->b1 == st->tB1 && st->b2 == st->tB2 &&
           st->a1 == st->tA1 && st->a2 == st->tA2 &&
           st->tubeMix == st->tTubeMix && st->tubeDrive == st->tTubeDrive &&
           st->tubeBias == st->tTubeBias &&
           st->tubeMakeup == st->tTubeMakeup &&
           st->cs0 == st->tCS0 && st->cs1 == st->tCS1 && st->cs2 == st->tCS2 &&
           st->csa1 == st->tCSa1 && st->csa2 == st->tCSa2 &&
           st->clarMix == st->tClarMix && st->clarDrive == st->tClarDrive &&
           st->xfG == st->tXfG && st->xfC == st->tXfC &&
           st->side == st->tSide && st->gL == st->tGL && st->gR == st->tGR;
}

static void resetFilterState(AEDSPState* st)
{
    for (int c = 0; c < 2; c++) {
        st->bassZ1[c] = 0.0; st->bassZ2[c] = 0.0;
        st->dcX[c] = 0.0f; st->dcY[c] = 0.0f;
        st->clarSz1[c] = 0.0; st->clarSz2[c] = 0.0;
        st->clarHz1[c] = 0.0f; st->clarHz2[c] = 0.0f;
        st->xfLP1[c] = 0.0f; st->xfLP2[c] = 0.0f;
    }
}

// ---------------------------------------------------------------------------
// Lifecycle

AEDSPState* AEDSPCreate(double sampleRate)
{
    AEDSPState* st = calloc(1, sizeof(AEDSPState));
    if (!st) return NULL;
    st->fs = sampleRate > 0.0 ? sampleRate : 48000.0;
    st->smoothC = (float)(1.0 - exp(-1.0 / (kSmoothTauSec * st->fs)));
    st->dcPole = (float)exp(-2.0 * kPi * kDCBlockHz / st->fs);
    // Clarity: RBJ cookbook 2nd-order highpass biquad at kClarityHPHz, Q =
    // 1/sqrt(2) (Butterworth). Unity gain in the passband, 12 dB/oct rolloff
    // below the corner — steep enough that the strengthened mix stays under
    // 0.5 dB below ~1.5 kHz, unlike the old (input - one_pole_LP) pseudo-HP
    // that asymptoted ~5 dB short of unity.
    {
        double w0 = 2.0 * kPi * kClarityHPHz / st->fs;
        double cw = cos(w0);
        double alpha = sin(w0) / (2.0 * 0.70710678118654752);
        double a0 = 1.0 + alpha;
        st->clarHb0 = (float)(((1.0 + cw) / 2.0) / a0);
        st->clarHb1 = (float)((-(1.0 + cw)) / a0);
        st->clarHb2 = (float)(((1.0 + cw) / 2.0) / a0);
        st->clarHa1 = (float)((-2.0 * cw) / a0);
        st->clarHa2 = (float)((1.0 - alpha) / a0);
    }

    st->cur = AEDSPParamsNeutral();
    st->share.box[0] = st->cur;
    st->share.box[1] = st->cur;
    atomic_init(&st->share.seq, 0u);
    atomic_init(&st->activeFlag, false);
    st->lastSeq = 0;

    computeTargets(st);
    snapAllToTargets(st);
    resetFilterState(st);
    st->bypassed = true;
    return st;
}

void AEDSPDestroy(AEDSPState* state)
{
    free(state);
}

// ---------------------------------------------------------------------------
// Control thread

void AEDSPSetParams(AEDSPState* state, const AEDSPParams* params)
{
    if (!state || !params) return;
    AEParamShare* sh = &state->share;
    uint32_t s = atomic_load_explicit(&sh->seq, memory_order_relaxed);
    uint32_t idx = ((s >> 1) + 1u) & 1u;      // write the inactive box
    sh->box[idx] = *params;
    atomic_store_explicit(&sh->seq, s + 2u, memory_order_release);
    atomic_store_explicit(&state->activeFlag, paramsActive(params),
                          memory_order_relaxed);
}

bool AEDSPIsActive(const AEDSPState* state)
{
    if (!state) return false;
    AEDSPState* st = (AEDSPState*)state;
    return atomic_load_explicit(&st->activeFlag, memory_order_relaxed);
}

// ---------------------------------------------------------------------------
// Render thread

// Snapshot the newest params if the sequence advanced. A concurrent write is
// detected by re-checking the counter; on contention we keep the previous
// params and pick the new ones up next block. Returns true on a new snapshot.
static bool fetchParams(AEDSPState* st)
{
    AEParamShare* sh = &st->share;
    for (int tries = 0; tries < 4; tries++) {
        uint32_t s1 = atomic_load_explicit(&sh->seq, memory_order_acquire);
        if (s1 == st->lastSeq) return false;
        AEDSPParams tmp = sh->box[(s1 >> 1) & 1u];
        atomic_thread_fence(memory_order_acquire);
        uint32_t s2 = atomic_load_explicit(&sh->seq, memory_order_relaxed);
        if (s1 == s2) {
            st->cur = tmp;
            st->lastSeq = s1;
            return true;
        }
    }
    return false;
}

#define AE_SMOOTH(v, t) do { \
    float d_ = (t) - (v); \
    if (fabsf(d_) < kSnapEps) (v) = (t); \
    else (v) += sc * d_; \
} while (0)

#define AE_SMOOTH_D(v, t) do { \
    double d_ = (t) - (v); \
    if (fabs(d_) < (double)kSnapEps) (v) = (t); \
    else (v) += (double)sc * d_; \
} while (0)

void AEDSPProcess(AEDSPState* state, float* interleavedStereo, uint32_t frames)
{
    AEDSPState* st = state;
    if (!st || !interleavedStereo || frames == 0) return;

    if (fetchParams(st)) {
        computeTargets(st);
        // Stay (or become) bypassed only if the new params are neutral AND
        // every smoother is already at its neutral target; otherwise process
        // so the ramps can converge without clicks.
        st->bypassed = !st->activeTarget && allSettled(st);
        if (st->bypassed) resetFilterState(st);
    }
    if (st->bypassed) return;                 // bit-exact, cheap passthrough

    const float sc = st->smoothC;
    const float dcPole = st->dcPole;
    const float hb0 = st->clarHb0, hb1 = st->clarHb1, hb2 = st->clarHb2;
    const float ha1 = st->clarHa1, ha2 = st->clarHa2;
    float* io = interleavedStereo;

    for (uint32_t i = 0; i < frames; i++) {
        // ---- parameter ramps (~10 ms), snapped once converged
        AE_SMOOTH_D(st->b0, st->tB0); AE_SMOOTH_D(st->b1, st->tB1);
        AE_SMOOTH_D(st->b2, st->tB2); AE_SMOOTH_D(st->a1, st->tA1);
        AE_SMOOTH_D(st->a2, st->tA2);
        AE_SMOOTH(st->tubeMix, st->tTubeMix);
        AE_SMOOTH(st->tubeDrive, st->tTubeDrive);
        AE_SMOOTH(st->tubeBias, st->tTubeBias);
        AE_SMOOTH(st->tubeMakeup, st->tTubeMakeup);
        AE_SMOOTH_D(st->cs0, st->tCS0); AE_SMOOTH_D(st->cs1, st->tCS1);
        AE_SMOOTH_D(st->cs2, st->tCS2); AE_SMOOTH_D(st->csa1, st->tCSa1);
        AE_SMOOTH_D(st->csa2, st->tCSa2);
        AE_SMOOTH(st->clarMix, st->tClarMix);
        AE_SMOOTH(st->clarDrive, st->tClarDrive);
        AE_SMOOTH(st->xfG, st->tXfG); AE_SMOOTH(st->xfC, st->tXfC);
        AE_SMOOTH(st->side, st->tSide);
        AE_SMOOTH(st->gL, st->tGL); AE_SMOOTH(st->gR, st->tGR);

        float l = io[2 * i];
        float r = io[2 * i + 1];

        // ---- 1) bass shelf: transposed direct form II biquad (double)
        {
            double yl = st->b0 * l + st->bassZ1[0];
            st->bassZ1[0] = st->b1 * l - st->a1 * yl + st->bassZ2[0] + kDenorm;
            st->bassZ2[0] = st->b2 * l - st->a2 * yl + kDenorm;
            double yr = st->b0 * r + st->bassZ1[1];
            st->bassZ1[1] = st->b1 * r - st->a1 * yr + st->bassZ2[1] + kDenorm;
            st->bassZ2[1] = st->b2 * r - st->a2 * yr + kDenorm;
            l = (float)yl; r = (float)yr;
        }

        // ---- 2) tube: asymmetric tanh -> DC blocker -> makeup -> wet blend
        if (st->tubeMix != 0.0f || st->tTubeMix != 0.0f) {
            const float k = st->tubeDrive;
            const float b = st->tubeBias;
            const float tb = tanhf(b);
            float wl = tanhf(k * l + b) - tb;
            float wr = tanhf(k * r + b) - tb;
            float dl = wl - st->dcX[0] + dcPole * st->dcY[0] + kDenorm;
            st->dcX[0] = wl; st->dcY[0] = dl;
            float dr = wr - st->dcX[1] + dcPole * st->dcY[1] + kDenorm;
            st->dcX[1] = wr; st->dcY[1] = dr;
            l += st->tubeMix * (st->tubeMakeup * dl - l);
            r += st->tubeMix * (st->tubeMakeup * dr - r);
        }

        // ---- 3) clarity: presence high-shelf (real fundamental lift, unity
        //         below ~1.5 kHz) + a small 4 kHz-highpass tanh exciter for
        //         harmonic sparkle on top. The shelf sums monotonically with
        //         the low band (no transition-band notch), so at amount 1.0
        //         the in-band gain is ~+6 dB @5 kHz / ~+8 dB @8 kHz while
        //         <2 kHz is untouched. The tanh adds gentle top-end air.
        bool clarShelfOn = st->cs0 != 1.0 || st->cs1 != 0.0 || st->cs2 != 0.0 ||
                           st->csa1 != 0.0 || st->csa2 != 0.0 ||
                           st->tCS0 != 1.0 || st->tCS1 != 0.0 ||
                           st->tCS2 != 0.0 || st->tCSa1 != 0.0 ||
                           st->tCSa2 != 0.0;
        if (clarShelfOn || st->clarMix != 0.0f || st->tClarMix != 0.0f) {
            // High-shelf biquad (transposed direct form II, double precision).
            double sl = st->cs0 * l + st->clarSz1[0];
            st->clarSz1[0] = st->cs1 * l - st->csa1 * sl + st->clarSz2[0] + kDenorm;
            st->clarSz2[0] = st->cs2 * l - st->csa2 * sl + kDenorm;
            double sr = st->cs0 * r + st->clarSz1[1];
            st->clarSz1[1] = st->cs1 * r - st->csa1 * sr + st->clarSz2[1] + kDenorm;
            st->clarSz2[1] = st->cs2 * r - st->csa2 * sr + kDenorm;

            // Highpass exciter tap on the dry input -> tanh -> add sparkle.
            const float d = st->clarDrive;
            const float invD = 1.0f / d;
            float hl = hb0 * l + st->clarHz1[0];
            st->clarHz1[0] = hb1 * l - ha1 * hl + st->clarHz2[0] + kDenorm;
            st->clarHz2[0] = hb2 * l - ha2 * hl + kDenorm;
            float hr = hb0 * r + st->clarHz1[1];
            st->clarHz1[1] = hb1 * r - ha1 * hr + st->clarHz2[1] + kDenorm;
            st->clarHz2[1] = hb2 * r - ha2 * hr + kDenorm;

            l = (float)sl + st->clarMix * tanhf(d * hl) * invD;
            r = (float)sr + st->clarMix * tanhf(d * hr) * invD;
        }

        // ---- 4) crossfeed: mono-safe Meier-style network
        if (st->xfG != 0.0f || st->tXfG != 0.0f) {
            const float c = st->xfC;
            st->xfLP1[0] += c * (l - st->xfLP1[0]) + kDenorm;
            st->xfLP2[0] += c * (st->xfLP1[0] - st->xfLP2[0]) + kDenorm;
            st->xfLP1[1] += c * (r - st->xfLP1[1]) + kDenorm;
            st->xfLP2[1] += c * (st->xfLP1[1] - st->xfLP2[1]) + kDenorm;
            float cross = st->xfG * (st->xfLP2[1] - st->xfLP2[0]);
            l += cross;                       // L + g*(lpR - lpL)
            r -= cross;                       // R + g*(lpL - lpR)
        }

        // ---- 5) width: mid/side scaling
        {
            float mid = 0.5f * (l + r);
            float sd = 0.5f * (l - r) * st->side;
            l = mid + sd;
            r = mid - sd;
        }

        // ---- 6) balance
        l *= st->gL;
        r *= st->gR;

        io[2 * i] = l;
        io[2 * i + 1] = r;
    }

    // Once fully neutral and every ramp has settled, flip to the bit-exact
    // bypass path for subsequent blocks.
    if (!st->activeTarget && allSettled(st)) {
        resetFilterState(st);
        st->bypassed = true;
    }
}
