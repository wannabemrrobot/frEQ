# FrEQ architecture note

## Components and audio path

```
┌─────────────────────────────────────────────────────────────────────┐
│ coreaudiod (system audio server)                                    │
│                                                                     │
│   all app audio ──mix──► FrEQ virtual device (AudioServerPlugIn)  │
│                              │ WriteMix: volume/mute applied,       │
│                              │ samples stored in a 16384-frame      │
│                              │ ring buffer indexed by sample time   │
│                              │                                      │
│                              ▼ ReadInput: same ring, read at the    │
│                                input sample time, zeroed after read │
└──────────────────────────────┬──────────────────────────────────────┘
                               │ loopback input stream (HAL capture)
┌──────────────────────────────▼──────────────────────────────────────┐
│ FrEQ.app                                                          │
│                                                                     │
│  CaptureUnit (AUHAL, input-only)                                    │
│      │  interleaved Float32 @ virtual-device rate                   │
│      ▼                                                              │
│  AERingBuffer (lock-free SPSC, C11 atomics, 32768 frames)           │
│      │  drift window: prefill / skip-ahead re-centering             │
│      ▼                                                              │
│  AVAudioEngine:                                                     │
│    AVAudioSourceNode ─► AVAudioUnitEQ ─► mainMixer ─► outputNode    │
│                         (≤16 bands +      (rate       (physical     │
│                          globalGain       convert)     device)      │
│                          preamp)                                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Driver ↔ app transport (IPC)

There is no custom IPC. The driver publishes a second, *input* stream on the
virtual device and loops the output mix back to it through a ring buffer that
lives inside the plug-in (in `coreaudiod`'s address space). The app is a
plain HAL capture client of that input stream, so all actual data transport
is Core Audio's own zero-copy IO machinery. This is the same pattern
BlackHole uses and was chosen over a bespoke shared-memory channel because:

- `coreaudiod` sandboxes its plug-ins; publishing custom shared memory from
  inside the sandbox is fragile across macOS releases.
- The HAL capture path is battle-tested, survives `coreaudiod` restarts, and
  needs no protocol versioning.

Cost of that choice: macOS classifies the capture as microphone use, so the
app needs the one-time mic-permission grant (handled in the UI, explained to
the user).

### Ring-buffer correctness inside the driver

`WriteMix` (system mix in) and `ReadInput` (capture out) are both indexed by
**device sample time modulo ring size**. Both cursors derive from the same
device clock, so they cannot drift relative to each other; the input time
coreaudiod asks for trails the output time by the IO scheduling offset,
which is far smaller than the 16384-frame ring. `ReadInput` zeroes frames
after copying them so that when playback stops, the reader never re-hears
stale audio once the ring wraps. Consequence: exactly one capture client is
supported — which is the design (the FrEQ app).

The driver's zero-timestamp clock is synthesized from `mach_absolute_time`
(`GetZeroTimeStamp` returns one timestamp per ring period), i.e. the virtual
device free-runs on the host clock.

## Clock drift between capture and render

The virtual device ticks on the host clock; the physical output device ticks
on its own hardware clock. The app's ring buffer between them absorbs the
mismatch, and the render side enforces a level window:

- **Underrun** (physical clock faster): emit silence, then *prefill* back to
  the target level before resuming — avoids a continuous crackle.
- **Overrun** (host clock faster): skip ahead to the target level.

With realistic drift (tens of ppm) a re-center happens at most every few
tens of minutes and is a single, tiny discontinuity. This was chosen over
adaptive resampling (async SRC) for simplicity and bit-transparency in the
steady state; the buffer window (≥3× the IO buffer) sets the app-side
latency of ~25–85 ms depending on the preset.

## Sample-rate strategy

On (re)start the app reads the output device's nominal rate and, when the
driver supports it (44.1/48/88.2/96/176.4/192 kHz), sets the virtual device
to the same rate — the graph then runs conversion-free end to end. If the
output device uses a rate the driver doesn't offer, capture runs at 48 kHz
and `AVAudioEngine`'s mixer performs the conversion. Rate changes requested
through the HAL (by us or anyone else) go through the mandatory
`RequestDeviceConfigurationChange` → `PerformDeviceConfigurationChange`
handshake in the driver; the app reacts to
`AVAudioEngineConfigurationChange` and rebuilds its graph.

## Device management policy

- Enabling: capture + render start **first**, then the virtual device is
  made default output (and default *system* output, for alerts) — no gap.
- The user changing the default output externally is adopted as the new EQ
  target, then the default is taken back (re-entrancy guarded).
- Selected device disappearing (Bluetooth drop) falls back to the previous
  default/any physical output; reappearing switches back. All device-list
  events are debounced 300 ms because a single Bluetooth connect fires
  several HAL notifications.
- The virtual device is excluded from the output picker and refuses to be a
  default *input* device (driver-side), preventing feedback loops and
  conferencing apps grabbing the loopback as a mic.
- Disable/quit restores the physical device as default output
  (`applicationWillTerminate`); a crash can leave the system pointing at the
  virtual device — documented in Troubleshooting.

## EQ engine

`AVAudioUnitEQ` (AUNBandEQ) with 16 bands allocated at graph build:

- AutoEq `PK` → `.parametric`. AutoEq specifies Q; AUNBandEQ takes bandwidth
  in octaves: `bw = (2/ln 2)·asinh(1/(2Q))`.
- `LSC`/`HSC` → `.lowShelf`/`.highShelf` (fixed-slope shelves; AutoEq's
  Q 0.70 shelves match this slope).
- Profile `Preamp` → `globalGain` (headroom for boosted bands).
- Unused bands are bypassed. Parameter updates ramp inside the AU, so live
  edits are click-free; profiles apply without engine restarts.

A second 3-band `AVAudioUnitEQ` ("tone stage": Bass low shelf @ 105 Hz, wide
Mids bell @ 1 kHz, Treble high shelf @ 7.5 kHz) sits after the profile EQ.
Keeping it separate means tone never consumes profile band slots, composes
with any imported profile, carries its own automatic headroom
(`globalGain = -max(0, boosts)`), and is fully bypassed when flat.

## Effects rack

Full render chain:

```
sourceNode (ring read + AEDSP C core) → profile EQ → tone EQ
    → reverb (AVAudioUnitReverb) → compressor (DynamicsProcessor AU)
    → limiter (PeakLimiter AU) → mainMixer → output
```

**AEDSP** (`App/Sources/Audio/AEDSP.c`) implements the custom effects —
bass-boost shelf, tube saturator, clarity exciter, Meier crossfeed,
mid/side width, balance — in C inside the source-node render block. Two
non-obvious choices:

- *Placement before the EQ stages*: the linear effects (shelf, crossfeed,
  width, balance) commute with the channel-symmetric EQ stages, so order is
  mathematically irrelevant for them; only the subtle saturators are
  order-sensitive, and hosting the C code in the render block we already
  own avoids the complexity of a custom `AUAudioUnit`.
- *Parameter handoff*: the control thread writes a double-buffered params
  snapshot guarded by an atomic version counter; the render thread detects
  the change at block start, recomputes filter coefficients once, and
  smooths gain-like values with ~10 ms one-pole ramps (no locks, no
  allocation, click-free live edits).

Reverb/compressor/limiter are Apple effect AUs (`AVAudioUnitReverb`,
`kAudioUnitSubType_DynamicsProcessor`, `kAudioUnitSubType_PeakLimiter`),
hard-bypassed via `AVAudioUnitEffect.bypass` when disabled. The limiter
sits last and defaults to on, so no combination of boosts can clip the DAC.

## Real-time safety

The capture callback and the source-node render block do no allocation, no
locking, no Objective-C messaging: they only move samples through
`AERingBuffer`, a single-producer/single-consumer lock-free ring using C11
acquire/release atomics (in C because Swift lacks stdlib atomics at our
deployment target). Control-plane changes (device switches, EQ parameters,
rate changes) all happen on the main thread and never touch the IO path
mid-cycle; structural changes stop and rebuild the graph instead.
