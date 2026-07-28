import AudioToolbox
import CoreAudio
import Foundation

/// Captures the loopback input stream of the FrEQ virtual device with a raw
/// AUHAL AudioUnit and writes interleaved Float32 frames into the ring buffer.
///
/// A raw AUHAL is used instead of AVAudioEngine's inputNode tap because taps
/// deliver large (~100 ms) buffers; the AUHAL input callback runs at the
/// device's IO buffer size (256–1024 frames), keeping added latency low.
final class CaptureUnit {

    enum CaptureError: LocalizedError {
        case osStatus(String, OSStatus)
        var errorDescription: String? {
            if case let .osStatus(stage, status) = self { return "\(stage) failed (OSStatus \(status))" }
            return nil
        }
    }

    private var audioUnit: AudioUnit?
    private let ring: OpaquePointer
    private var renderBuffer: UnsafeMutablePointer<Float>
    private let renderBufferCapacityFrames: Int = 8192
    private let channels: UInt32 = 2

    private(set) var sampleRate: Double = 0

    init(ring: OpaquePointer) {
        self.ring = ring
        renderBuffer = UnsafeMutablePointer<Float>.allocate(capacity: renderBufferCapacityFrames * Int(channels))
    }

    deinit {
        stop()
        renderBuffer.deallocate()
    }

    func start(deviceID: AudioDeviceID, sampleRate: Double, bufferFrames: UInt32) throws {
        stop()
        self.sampleRate = sampleRate

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw CaptureError.osStatus("AudioComponentFindNext", -1)
        }

        var unit: AudioUnit?
        try check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &unit))
        guard let au = unit else { throw CaptureError.osStatus("AudioComponentInstanceNew", -1) }
        audioUnit = au

        // Input on element 1 on, output on element 0 off — capture-only AUHAL.
        var enable: UInt32 = 1
        try check("EnableIO(input)", AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Input, 1, &enable, UInt32(MemoryLayout<UInt32>.size)))
        var disable: UInt32 = 0
        try check("EnableIO(output)", AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO,
            kAudioUnitScope_Output, 0, &disable, UInt32(MemoryLayout<UInt32>.size)))

        var device = deviceID
        try check("SetCurrentDevice", AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &device, UInt32(MemoryLayout<AudioDeviceID>.size)))

        // Client-side format on the output scope of the input element:
        // interleaved Float32 at the device rate (AUHAL input cannot
        // rate-convert, so the rate must match the device's nominal rate).
        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 32,
            mReserved: 0)
        try check("SetStreamFormat", AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Output, 1, &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))

        var maxFrames: UInt32 = UInt32(renderBufferCapacityFrames)
        try check("SetMaximumFramesPerSlice", AudioUnitSetProperty(au, kAudioUnitProperty_MaximumFramesPerSlice,
            kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size)))

        // Ask the HAL for a small IO buffer on the virtual device.
        var frames = bufferFrames
        var bufferAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyBufferFrameSize,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(deviceID, &bufferAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        var callback = AURenderCallbackStruct(
            inputProc: captureCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check("SetInputCallback", AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback,
            kAudioUnitScope_Global, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))

        DebugLog.log("    capture: props set (device=\(deviceID)); AudioUnitInitialize…")
        let ti = Date()
        try check("AudioUnitInitialize", AudioUnitInitialize(au))
        DebugLog.log("    capture: AudioUnitInitialize done in \(String(format: "%.2f", Date().timeIntervalSince(ti)))s; AudioOutputUnitStart…")
        let ts = Date()
        try check("AudioOutputUnitStart", AudioOutputUnitStart(au))
        DebugLog.log("    capture: AudioOutputUnitStart done in \(String(format: "%.2f", Date().timeIntervalSince(ts)))s")
    }

    func stop() {
        guard let au = audioUnit else { return }
        AudioOutputUnitStop(au)
        AudioUnitUninitialize(au)
        AudioComponentInstanceDispose(au)
        audioUnit = nil
    }

    private func check(_ stage: String, _ status: OSStatus) throws {
        if status != noErr {
            stop()
            throw CaptureError.osStatus(stage, status)
        }
    }

    // Called on the capture IO thread. Real-time constraints apply: no locks,
    // no allocation, no Objective-C/Swift runtime calls that can block.
    fileprivate func handleInput(_ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                                 _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
                                 _ inBusNumber: UInt32,
                                 _ inNumberFrames: UInt32) -> OSStatus {
        guard let au = audioUnit, inNumberFrames <= renderBufferCapacityFrames else { return noErr }

        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: channels,
                mDataByteSize: inNumberFrames * 4 * channels,
                mData: UnsafeMutableRawPointer(renderBuffer)))

        let status = AudioUnitRender(au, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, &bufferList)
        if status == noErr {
            AERingBufferWrite(ring, renderBuffer, inNumberFrames)
        }
        return status
    }
}

// C-convention trampoline for the AUHAL input callback.
private func captureCallback(inRefCon: UnsafeMutableRawPointer,
                             ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                             inTimeStamp: UnsafePointer<AudioTimeStamp>,
                             inBusNumber: UInt32,
                             inNumberFrames: UInt32,
                             ioData: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let capture = Unmanaged<CaptureUnit>.fromOpaque(inRefCon).takeUnretainedValue()
    return capture.handleInput(ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames)
}
