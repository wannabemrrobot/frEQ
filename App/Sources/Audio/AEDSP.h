// Custom DSP effect suite for FrEQ (ViPER4FX-style enhancers).
// Runs inside the render path's source-node block on interleaved stereo
// Float32. Implemented in C for the same reason as AERingBuffer: real-time
// safety with explicit atomics and zero Swift runtime involvement.
//
// Threading contract:
//   - AEDSPProcess is called from exactly one real-time render thread.
//   - AEDSPSetParams may be called concurrently from the control (main)
//     thread; the implementation must hand parameters to the render thread
//     lock-free (version-stamped snapshot) and must smooth audible
//     parameters (gains/mixes, ~10 ms one-pole) so live edits never zipper
//     or click.
//   - AEDSPProcess must not allocate, lock, or call anything non-RT-safe.
//
// Signal chain inside AEDSPProcess (order fixed):
//   bass shelf → tube saturator → clarity exciter → crossfeed → width → balance
//
// All effects must be exactly transparent when disabled (bit-identical
// passthrough when every effect is off), and the whole Process call should
// early-out cheaply in that case. Filter state must be protected against
// denormals (anti-denormal offset or explicit flushing).

#ifndef AEDSP_h
#define AEDSP_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AEDSPState AEDSPState;

typedef struct {
    // --- Bass boost: RBJ low-shelf biquad (per channel, identical L/R).
    bool  bassEnabled;
    float bassGainDB;        // 0 .. +12 dB shelf gain
    float bassFrequency;     // 40 .. 200 Hz shelf corner (S = 0.9)

    // --- Tube warmth: asymmetric soft saturator blended with the dry
    //     signal. amount 0..1 scales both drive and wet mix; the output must
    //     stay level-matched within ±1 dB of the input for amount ≤ 1 on
    //     full-scale material, and a DC blocker must follow the shaper
    //     (asymmetry creates DC).
    bool  tubeEnabled;
    float tubeAmount;        // 0 .. 1

    // --- Clarity: presence/brilliance-region exciter. A proper first-order
    //     (bilinear) highpass at ~4 kHz — unity gain in its passband — feeds a
    //     tanh shaper; the high-band result is mixed back on top of the dry
    //     signal. The mix provides a real fundamental-band lift (not only
    //     harmonic sparkle): at amount 1.0 the in-band (4–10 kHz) gain is
    //     roughly +6 to +10 dB, and clearly audible (~+3 to +5 dB) at 0.5.
    //     amount 0..1. Constraint: the change stays < 0.5 dB below ~1.5 kHz
    //     (mids/bass are not muddied).
    bool  clarityEnabled;
    float clarityAmount;     // 0 .. 1

    // --- Crossfeed (headphone "surround"): delay-free Meier-style network,
    //     mono-safe by construction:
    //       lpL = LP1(L, cutoff); lpR = LP1(R, cutoff)
    //       outL = L + g·(lpR − lpL);  outR = R + g·(lpL − lpR)
    //     where g = 10^(−feedDB/20). Mono input must pass through untouched
    //     at every frequency; low-frequency side content is attenuated.
    bool  crossfeedEnabled;
    float crossfeedFeedDB;   // 2 .. 8 dB (cross level attenuation; 4.5 typical)
    float crossfeedCutoffHz; // 400 .. 1200 Hz (700 typical)

    // --- Stereo width: mid/side scaling. 100 = unchanged, 0 = mono,
    //     200 = side doubled. Applied whenever != 100.
    float widthPercent;      // 0 .. 200

    // --- Balance: -1 = full left (right muted), 0 = centered, +1 = full
    //     right. bal < 0: gL = 1, gR = 1 + bal;  bal > 0: gL = 1 − bal, gR = 1.
    float balance;           // -1 .. +1
} AEDSPParams;

// A params value with everything disabled / neutral.
AEDSPParams AEDSPParamsNeutral(void);

// Create with the render sample rate. Returns NULL on allocation failure.
AEDSPState* AEDSPCreate(double sampleRate);
void        AEDSPDestroy(AEDSPState* state);

// Control thread. Copies the params; lock-free handoff to the render thread.
void AEDSPSetParams(AEDSPState* state, const AEDSPParams* params);

// True if any effect is enabled or any neutral-by-default value is
// non-neutral (width != 100, balance != 0) — callers may skip Process when
// false, but Process itself must also be transparent in that case.
bool AEDSPIsActive(const AEDSPState* state);

// Render thread. In-place on interleaved stereo (frames × 2 floats).
void AEDSPProcess(AEDSPState* state, float* interleavedStereo, uint32_t frames);

#ifdef __cplusplus
}
#endif

#endif /* AEDSP_h */
