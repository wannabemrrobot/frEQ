import AVFoundation
import CoreAudio
import Foundation
import os.log

/// The full audio path: virtual-device capture → ring buffer → EQ → physical
/// output device.
///
/// Capture and render run on independent device clocks (the virtual device
/// free-runs on the host clock, the output device on its own hardware clock),
/// so the ring buffer level slowly drifts. The render side re-centers when the
/// level leaves its window: underruns emit silence and re-prefill; overruns
/// skip ahead. With ppm-level clock drift a re-center happens at most every
/// few tens of minutes and sounds like a single tiny skip, which is the
/// simplest robust behavior short of adaptive resampling.
final class AudioPipeline {

    private static let log = Logger(subsystem: "com.freq.app", category: "pipeline")

    // Consumer-side state for the source-node render block. Class instance so
    // the closure captures a stable reference; only the render thread mutates.
    private final class RenderState {
        var prefilling = true
        var targetFrames: UInt32 = 2048
        var highWaterFrames: UInt32 = 6144
        var underruns = 0
        var recenters = 0
        // Metering (written on audio threads, read on main — benign races; a
        // meter tolerates a torn Float/Int read).
        var inputPeak: Float = 0     // captured signal, before processing
        var outputPeak: Float = 0    // processed signal, near the output
        var clipHold: Int = 0        // >0 while a recent block went past 0 dBFS
        var clipPeak: Float = 0      // worst linear peak during the current clip
    }

    private let ring: OpaquePointer
    private let capture: CaptureUnit
    private var engine: AVAudioEngine?
    private var sourceNode: AVAudioSourceNode?
    private let eq = AVAudioUnitEQ(numberOfBands: EQProfile.maxBands)
    // Separate stage for Bass/Mids/Treble so tone never competes with the
    // profile for bands and can be bypassed independently when flat.
    private let toneEQ = AVAudioUnitEQ(numberOfBands: 3)

    // Effects rack, after the EQ stages: reverb → compressor → limiter.
    // Apple's own effect AUs; each is hard-bypassed when disabled.
    private let reverb = AVAudioUnitReverb()
    private let compressor = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_DynamicsProcessor,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0))
    private let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
        componentType: kAudioUnitType_Effect,
        componentSubType: kAudioUnitSubType_PeakLimiter,
        componentManufacturer: kAudioUnitManufacturer_Apple,
        componentFlags: 0, componentFlagsMask: 0))

    // Custom C DSP core (bass boost, tube, clarity, crossfeed, width,
    // balance). It runs on the interleaved samples inside the source-node
    // block, i.e. ahead of the EQ stages. That placement is deliberate: all
    // its linear effects (crossfeed/width/balance/shelf) commute with the
    // channel-symmetric EQ stages, and hosting the C code in the block we
    // already own avoids a custom AUAudioUnit. Recreated per start() at the
    // capture rate.
    private var dsp: OpaquePointer?
    private var currentEffects = EffectsSettings()
    /// Output makeup gain (dB) added into the limiter to match system loudness
    /// despite the EQ preamp. Set via setMasterMakeup(_:).
    private var masterMakeupDB: Float = 0
    private let renderState = RenderState()
    private var scratch: UnsafeMutablePointer<Float>
    private let scratchCapacityFrames = 8192
    private let channels = 2

    // Spectrum analyzers (all-band visualizer). Created per start() at the
    // capture rate; one is fed by the render thread (input), the other by the
    // metering tap (output). Mono scratch is preallocated for RT-safe downmix.
    static let spectrumBands = 28
    private var inputSpectrum: AESpectrum?
    private var outputSpectrum: AESpectrum?
    private var monoIn: UnsafeMutablePointer<Float>
    private var monoOut: UnsafeMutablePointer<Float>
    private let monoOutCapacity = 4096

    private(set) var isRunning = false

    /// Whether the render engine is actually running (health-check signal).
    var engineRunning: Bool { engine?.isRunning ?? false }

    /// Monotonic total frames captured from the virtual device — advancing
    /// means the capture AUHAL is delivering (even silence advances it).
    var capturedFrames: UInt64 { AERingBufferWritePos(ring) }

    // MARK: - Metering (read on main; benign races)

    var inputLevel: Float { renderState.inputPeak }
    var outputLevel: Float { renderState.outputPeak }
    var isClipping: Bool { renderState.clipHold > 0 }
    /// How many dB the recent clip peak went past 0 dBFS (0 if not clipping).
    var clipOverDB: Float {
        let p = renderState.clipPeak
        return p > 1.0 ? 20 * log10(p) : 0
    }
    var inputBands: [Float] { inputSpectrum?.snapshot() ?? [] }
    var outputBands: [Float] { outputSpectrum?.snapshot() ?? [] }
    var inputPeaks: [Float] { inputSpectrum?.peaksSnapshot() ?? [] }
    var outputPeaks: [Float] { outputSpectrum?.peaksSnapshot() ?? [] }

    /// A/B compare: force a flat, unprocessed signal (EQ/tone/effects/DSP off)
    /// without disturbing the user's saved settings. The limiter is left in
    /// place for clip safety. Un-bypass by re-applying profile/tone/effects.
    func bypassAllProcessing() {
        eq.bypass = true
        toneEQ.bypass = true
        reverb.bypass = true
        compressor.bypass = true
        if let dsp {
            var neutral = AEDSPParamsNeutral()
            AEDSPSetParams(dsp, &neutral)
        }
    }

    /// Force the engine's output onto a specific device, overriding
    /// AVAudioEngine's tendency to follow the system default. Must be called
    /// after the default has been pointed at the virtual device, and re-asserted
    /// because the follow can arrive asynchronously.
    func pinOutputDevice(_ id: AudioDeviceID) {
        guard let au = engine?.outputNode.audioUnit else { return }
        var dev = id
        AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev,
                             UInt32(MemoryLayout<AudioDeviceID>.size))
    }

    /// The device the render engine's output is ACTUALLY driving right now.
    /// If this is the virtual device instead of the intended physical output,
    /// the engine has followed the default → feedback loop / silence.
    var outputDeviceID: AudioDeviceID {
        guard let au = engine?.outputNode.audioUnit else { return 0 }
        var dev: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioUnitGetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
                             kAudioUnitScope_Global, 0, &dev, &size)
        return dev
    }

    init() {
        guard let rb = AERingBufferCreate(32768, 2) else {
            fatalError("could not allocate audio ring buffer")
        }
        ring = rb
        capture = CaptureUnit(ring: rb)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacityFrames * channels)
        monoIn = UnsafeMutablePointer<Float>.allocate(capacity: scratchCapacityFrames)
        monoOut = UnsafeMutablePointer<Float>.allocate(capacity: monoOutCapacity)
    }

    deinit {
        stop()
        scratch.deallocate()
        monoIn.deallocate()
        monoOut.deallocate()
        AERingBufferDestroy(ring)
    }

    // MARK: - Lifecycle

    /// Starts capture from `virtualDevice` and rendering to `outputDevice`.
    /// `captureRate` must be the virtual device's current nominal rate.
    func start(virtualDevice: AudioDeviceID,
               outputDevice: AudioDeviceID,
               captureRate: Double,
               bufferFrames: UInt32) throws {
        stop()

        renderState.targetFrames = max(1024, bufferFrames * 3)
        renderState.highWaterFrames = renderState.targetFrames + 4096
        renderState.prefilling = true
        AERingBufferReset(ring)

        // DSP core is clocked at the capture rate; rebuild it per start.
        dsp = AEDSPCreate(captureRate)

        // Spectrum analyzers for the visualizer.
        let inSpectrum = AESpectrum(bandCount: Self.spectrumBands, sampleRate: captureRate)
        let outSpectrum = AESpectrum(bandCount: Self.spectrumBands, sampleRate: captureRate)
        inputSpectrum = inSpectrum
        outputSpectrum = outSpectrum

        // --- Render side -----------------------------------------------------
        let engine = AVAudioEngine()
        self.engine = engine

        // Deinterleaved float is the canonical AVAudioEngine format; the ring
        // holds interleaved capture data, so the render block deinterleaves.
        guard let format = AVAudioFormat(standardFormatWithSampleRate: captureRate, channels: 2) else {
            throw CaptureUnit.CaptureError.osStatus("AVAudioFormat", -1)
        }

        let ring = self.ring
        let state = self.renderState
        let scratch = self.scratch
        let scratchCapacity = self.scratchCapacityFrames
        let channels = self.channels
        let dsp = self.dsp
        let monoIn = self.monoIn

        let source = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let frames = Int(frameCount)
            guard frames <= scratchCapacity, buffers.count >= 2,
                  let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else {
                for buffer in buffers { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
                return noErr
            }

            var fill = AERingBufferFill(ring)

            // After an underrun, wait for the buffer to refill to the target
            // level before resuming; otherwise we'd crackle continuously.
            if state.prefilling {
                if fill < state.targetFrames {
                    memset(left, 0, frames * 4)
                    memset(right, 0, frames * 4)
                    return noErr
                }
                state.prefilling = false
            }

            // Clock drift accumulated too much buffered audio: skip ahead.
            if fill > state.highWaterFrames {
                AERingBufferSkip(ring, fill - state.targetFrames)
                state.recenters += 1
                fill = AERingBufferFill(ring)
            }

            let got = Int(AERingBufferRead(ring, scratch, UInt32(frames)))
            if got > 0 {
                var p: Float = 0
                for i in 0..<(got * channels) { let a = abs(scratch[i]); if a > p { p = a } }
                state.inputPeak = p
                // Downmix to mono and feed the input spectrum (pre-processing).
                for f in 0..<got { monoIn[f] = 0.5 * (scratch[f * channels] + scratch[f * channels + 1]) }
                inSpectrum.process(monoIn, got)
            }
            if got > 0, let dsp, AEDSPIsActive(dsp) {
                AEDSPProcess(dsp, scratch, UInt32(got))
            }
            for frame in 0..<got {
                left[frame] = scratch[frame * channels]
                right[frame] = scratch[frame * channels + 1]
            }
            if got < frames {
                memset(left + got, 0, (frames - got) * 4)
                memset(right + got, 0, (frames - got) * 4)
                state.underruns += 1
                state.prefilling = true
            }
            return noErr
        }
        self.sourceNode = source

        engine.attach(source)
        engine.attach(eq)
        engine.attach(toneEQ)
        engine.attach(reverb)
        engine.attach(compressor)
        engine.attach(limiter)
        engine.connect(source, to: eq, format: format)
        engine.connect(eq, to: toneEQ, format: format)
        engine.connect(toneEQ, to: reverb, format: format)
        engine.connect(reverb, to: compressor, format: format)
        engine.connect(compressor, to: limiter, format: format)
        engine.connect(limiter, to: engine.mainMixerNode, format: format)
        // mainMixer → outputNode is wired implicitly at the hardware format;
        // the mixer performs any needed rate conversion.

        // Route the output AUHAL at the chosen physical device before start.
        guard let outputAU = engine.outputNode.audioUnit else {
            throw CaptureUnit.CaptureError.osStatus("outputNode.audioUnit", -1)
        }
        var outputDeviceID = outputDevice
        let status = AudioUnitSetProperty(outputAU, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0,
                                          &outputDeviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw CaptureUnit.CaptureError.osStatus("set output device", status)
        }

        // --- Capture side FIRST ---------------------------------------------
        // Open the input stream on the virtual device BEFORE starting the
        // engine's Bluetooth output. On a cold start (first capture after a
        // fresh mic grant, or the BT device idle), starting the input stream
        // while the BT output route was just brought up can wedge
        // AudioOutputUnitStart for many seconds. The virtual device has no such
        // dependency, so priming it first avoids the stall.
        let tc = Date()
        try capture.start(deviceID: virtualDevice, sampleRate: captureRate, bufferFrames: bufferFrames)
        DebugLog.log("  pipeline: capture.start OK in \(String(format: "%.2f", Date().timeIntervalSince(tc)))s")

        // Output meter + clip detection: tap the processed signal just before
        // the limiter (so the clip light reflects over-boost the limiter is
        // rescuing). One tap; peak per block.
        let st = renderState
        let monoOut = self.monoOut
        let monoOutCap = self.monoOutCapacity
        // Small tap buffer → lower latency and a faster update rate so OUT
        // tracks IN closely.
        compressor.installTap(onBus: 0, bufferSize: 512, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData else { return }
            var p: Float = 0
            let n = Int(buffer.frameLength)
            let chCount = Int(buffer.format.channelCount)
            for ch in 0..<chCount {
                let s = data[ch]
                for i in 0..<n { let a = abs(s[i]); if a > p { p = a } }
            }
            st.outputPeak = p
            // Only a true over-0-dBFS peak counts as clipping (full-scale audio
            // at exactly 0 dB is normal, not clipping). Track how far over.
            if p > 1.0 {
                st.clipHold = 40                       // ~0.9 s hold
                if p > st.clipPeak { st.clipPeak = p }
            } else if st.clipHold > 0 {
                st.clipHold -= 1
                if st.clipHold == 0 { st.clipPeak = 0 }
            }
            // Downmix to mono and feed the output spectrum.
            let m = min(n, monoOutCap)
            if chCount >= 2 {
                let l = data[0], r = data[1]
                for i in 0..<m { monoOut[i] = 0.5 * (l[i] + r[i]) }
            } else {
                let l = data[0]
                for i in 0..<m { monoOut[i] = l[i] }
            }
            outSpectrum.process(monoOut, m)
        }

        engine.prepare()
        DebugLog.log("  pipeline: engine.prepare done; starting engine (output id=\(outputDevice))…")
        let te = Date()
        try engine.start()
        DebugLog.log("  pipeline: engine.start OK in \(String(format: "%.2f", Date().timeIntervalSince(te)))s (running=\(engine.isRunning))")

        // Re-apply the whole effects rack to the fresh graph/DSP instance.
        apply(effects: currentEffects)

        isRunning = true
        Self.log.info("pipeline started: capture \(captureRate, format: .fixed(precision: 0)) Hz, buffer \(bufferFrames) frames")
    }

    func stop() {
        capture.stop()
        if let engine {
            compressor.removeTap(onBus: 0)
            engine.stop()
            if let source = sourceNode {
                engine.detach(source)
            }
            engine.detach(eq)
            engine.detach(toneEQ)
            engine.detach(reverb)
            engine.detach(compressor)
            engine.detach(limiter)
        }
        engine = nil
        sourceNode = nil
        isRunning = false
        inputSpectrum = nil
        outputSpectrum = nil
        // Safe to free only after engine.stop(): the render thread is gone.
        if let dsp {
            AEDSPDestroy(dsp)
            self.dsp = nil
        }
    }

    // MARK: - EQ

    /// Applies a profile to the AVAudioUnitEQ node. Safe to call while
    /// running; AUNBandEQ ramps parameter changes internally, so live edits
    /// do not click.
    func apply(profile: EQProfile) {
        eq.globalGain = Float(max(-96, min(24, profile.preamp)))
        let bands = profile.bands.prefix(EQProfile.maxBands)
        for (index, eqBand) in eq.bands.enumerated() {
            guard index < bands.count else {
                eqBand.bypass = true
                eqBand.gain = 0
                continue
            }
            let band = bands[bands.startIndex + index]
            switch band.type {
            case .peaking:
                eqBand.filterType = .parametric
                // AVAudioUnitEQ expresses parametric width in octaves, AutoEq
                // in Q: bw = (2/ln2)·asinh(1/(2Q)).
                eqBand.bandwidth = Float(max(0.05, min(5.0, (2.0 / M_LN2) * asinh(1.0 / (2.0 * max(0.01, band.q))))))
            case .lowShelf:
                eqBand.filterType = .lowShelf
            case .highShelf:
                eqBand.filterType = .highShelf
            }
            eqBand.frequency = Float(max(20, min(20000, band.frequency)))
            eqBand.gain = Float(max(-24, min(24, band.gain)))
            eqBand.bypass = !band.isEnabled
        }
    }

    /// Applies the Bass/Mids/Treble stage. Frequencies/shapes are classic
    /// tone-control values: shelves at the spectrum edges, a wide (2-octave)
    /// bell for mids. Boosts get automatic headroom via the stage's own
    /// globalGain so tone can never introduce clipping on top of a profile
    /// whose preamp only accounts for its own filters.
    func apply(tone: ToneControls) {
        let bands = toneEQ.bands
        guard bands.count >= 3 else { return }

        bands[0].filterType = .lowShelf
        bands[0].frequency = 105
        bands[0].gain = Float(max(-12, min(12, tone.bass)))
        bands[0].bypass = tone.bass == 0

        bands[1].filterType = .parametric
        bands[1].frequency = 1000
        bands[1].bandwidth = 2.0
        bands[1].gain = Float(max(-12, min(12, tone.mid)))
        bands[1].bypass = tone.mid == 0

        bands[2].filterType = .highShelf
        bands[2].frequency = 7500
        bands[2].gain = Float(max(-12, min(12, tone.treble)))
        bands[2].bypass = tone.treble == 0

        // No makeup/headroom reduction here: boosting a band must make that
        // band louder, not drop everything else. AVAudioEngine is 32-bit
        // float internally so +12 dB between nodes cannot clip; the master
        // limiter at the end of the chain catches the final peak. (An earlier
        // version pulled globalGain down by the largest boost, which made a
        // Bass +12 boost sound merely quieter and muddier.)
        toneEQ.globalGain = 0
        toneEQ.bypass = tone.isFlat
    }

    /// Set the loudness-match makeup (dB) and re-apply the limiter.
    func setMasterMakeup(_ dB: Float) {
        masterMakeupDB = max(0, dB)
        apply(effects: currentEffects)
    }

    /// Applies the effects rack. Safe live: the DSP core smooths its own
    /// parameters, and the Apple AUs ramp theirs.
    func apply(effects: EffectsSettings) {
        currentEffects = effects

        if let dsp {
            var p = AEDSPParamsNeutral()
            p.bassEnabled = effects.bass.enabled
            p.bassGainDB = Float(max(0, min(12, effects.bass.gainDB)))
            p.bassFrequency = Float(max(40, min(200, effects.bass.frequency)))
            p.tubeEnabled = effects.tube.enabled
            p.tubeAmount = Float(max(0, min(1, effects.tube.amount)))
            p.clarityEnabled = effects.clarity.enabled
            p.clarityAmount = Float(max(0, min(1, effects.clarity.amount)))
            p.crossfeedEnabled = effects.crossfeed.enabled
            p.crossfeedFeedDB = Float(max(2, min(8, effects.crossfeed.feedDB)))
            p.crossfeedCutoffHz = Float(max(400, min(1200, effects.crossfeed.cutoffHz)))
            p.widthPercent = Float(max(0, min(200, effects.widthPercent)))
            p.balance = Float(max(-1, min(1, effects.balance)))
            AEDSPSetParams(dsp, &p)
        }

        reverb.bypass = !effects.reverb.enabled
        if let preset = AVAudioUnitReverbPreset(rawValue: effects.reverb.preset) {
            reverb.loadFactoryPreset(preset)
        }
        reverb.wetDryMix = Float(max(0, min(100, effects.reverb.mix)))

        compressor.bypass = !effects.compressor.enabled
        let compAU = compressor.audioUnit
        AudioUnitSetParameter(compAU, kDynamicsProcessorParam_Threshold, kAudioUnitScope_Global, 0,
                              Float(max(-40, min(0, effects.compressor.thresholdDB))), 0)
        AudioUnitSetParameter(compAU, kDynamicsProcessorParam_HeadRoom, kAudioUnitScope_Global, 0,
                              Float(max(0.1, min(40, effects.compressor.headroomDB))), 0)
        AudioUnitSetParameter(compAU, kDynamicsProcessorParam_AttackTime, kAudioUnitScope_Global, 0,
                              Float(max(0.0001, min(0.2, effects.compressor.attackMS / 1000))), 0)
        AudioUnitSetParameter(compAU, kDynamicsProcessorParam_ReleaseTime, kAudioUnitScope_Global, 0,
                              Float(max(0.01, min(3, effects.compressor.releaseMS / 1000))), 0)
        AudioUnitSetParameter(compAU, kDynamicsProcessorParam_OverallGain, kAudioUnitScope_Global, 0,
                              Float(max(0, min(20, effects.compressor.makeupDB))), 0)

        // Loudness makeup (to match system loudness despite the EQ preamp) is
        // pushed into the limiter's pre-gain; the limiter then catches any
        // peaks the makeup pushes past 0 dB. When makeup is active the limiter
        // must stay on regardless of the user's toggle (it's the safety net).
        let userPre = Float(max(-10, min(10, effects.limiter.preGainDB)))
        let totalPre = max(-10, min(24, userPre + masterMakeupDB))
        limiter.bypass = !effects.limiter.enabled && masterMakeupDB <= 0.01
        let limAU = limiter.audioUnit
        AudioUnitSetParameter(limAU, kLimiterParam_PreGain, kAudioUnitScope_Global, 0, totalPre, 0)
        AudioUnitSetParameter(limAU, kLimiterParam_AttackTime, kAudioUnitScope_Global, 0, 0.012, 0)
        AudioUnitSetParameter(limAU, kLimiterParam_DecayTime, kAudioUnitScope_Global, 0, 0.024, 0)
    }

    var diagnostics: (underruns: Int, recenters: Int, fill: UInt32) {
        (renderState.underruns, renderState.recenters, AERingBufferFill(ring))
    }
}
