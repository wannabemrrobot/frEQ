import CoreAudio
import Foundation

/// A physical or virtual audio device as seen by the HAL.
struct AudioDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let outputChannelCount: Int
    let transportType: UInt32

    var isVirtualEQDevice: Bool { uid == AudioDeviceManager.virtualDeviceUID }

    /// Any userspace loopback/virtual device (our own, plus eqMac, BlackHole,
    /// Parrot, etc.). These are NOT valid EQ output targets — routing into one
    /// produces silence — so they are excluded from the picker and from
    /// automatic fallback.
    var isVirtual: Bool { transportType == kAudioDeviceTransportTypeVirtual }

    /// Bluetooth transports can't run tiny IO buffers; forcing e.g. 256 frames
    /// triggers a long A2DP renegotiation. Callers give BT outputs a roomy
    /// buffer and start them off the main thread.
    var isBluetooth: Bool {
        transportType == kAudioDeviceTransportTypeBluetooth ||
        transportType == kAudioDeviceTransportTypeBluetoothLE
    }
}

/// Thin CoreAudio HAL wrapper: device enumeration, default-device management,
/// sample rates, and change notifications. All callbacks fire on the main queue.
final class AudioDeviceManager {

    /// Must match kDevice_UID in Driver/FrEQDriver.c.
    static let virtualDeviceUID = "FrEQ_Device_UID"

    var onDevicesChanged: (() -> Void)?
    var onDefaultOutputChanged: (() -> Void)?

    private var listenerBlocks: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    // MARK: - Property helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func getValue<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, default defaultValue: T) -> T? {
        var address = addr
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        return status == noErr ? value : nil
    }

    private static func getString(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var address = addr
        var ref: Unmanaged<CFString>? = nil
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) { ptr in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let value = ref else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func getArray<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [T] {
        var address = addr
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<T>.size
        var array = [T](unsafeUninitializedCapacity: count) { _, initialized in initialized = count }
        let status = array.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw.baseAddress!)
        }
        return status == noErr ? array : []
    }

    @discardableResult
    private static func setValue<T>(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var address = addr
        var v = value
        let status = withUnsafePointer(to: &v) { ptr in
            AudioObjectSetPropertyData(objectID, &address, 0, nil, UInt32(MemoryLayout<T>.size), ptr)
        }
        return status == noErr
    }

    // MARK: - Enumeration

    func allDevices() -> [AudioDevice] {
        let ids: [AudioDeviceID] = Self.getArray(AudioObjectID(kAudioObjectSystemObject),
                                                 Self.address(kAudioHardwarePropertyDevices))
        return ids.compactMap { deviceInfo($0) }
    }

    /// Devices the EQ can render to: real (non-virtual) outputs. Excludes our
    /// own virtual device (routing to it would feed back) AND other loopback
    /// drivers like eqMac/BlackHole/Parrot (routing into them is silent), so
    /// automatic fallback can never land on a dead sink.
    func selectableOutputDevices() -> [AudioDevice] {
        allDevices().filter { $0.outputChannelCount > 0 && !$0.isVirtual }
    }

    func virtualDevice() -> AudioDevice? {
        allDevices().first { $0.isVirtualEQDevice }
    }

    func device(byUID uid: String) -> AudioDevice? {
        allDevices().first { $0.uid == uid }
    }

    func device(byID id: AudioDeviceID) -> AudioDevice? {
        allDevices().first { $0.id == id }
    }

    private func deviceInfo(_ id: AudioDeviceID) -> AudioDevice? {
        guard let uid = Self.getString(id, Self.address(kAudioDevicePropertyDeviceUID)),
              let name = Self.getString(id, Self.address(kAudioObjectPropertyName)) else { return nil }
        let transport = Self.getValue(id, Self.address(kAudioDevicePropertyTransportType), default: UInt32(0)) ?? 0
        return AudioDevice(id: id, uid: uid, name: name,
                           outputChannelCount: channelCount(id, scope: kAudioObjectPropertyScopeOutput),
                           transportType: transport)
    }

    private func channelCount(_ id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = Self.address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let ablPointer = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return ablPointer.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - Default output device

    var defaultOutputDeviceID: AudioDeviceID? {
        Self.getValue(AudioObjectID(kAudioObjectSystemObject),
                      Self.address(kAudioHardwarePropertyDefaultOutputDevice),
                      default: AudioDeviceID(0))
    }

    /// Sets both the default output (app audio) and the system output (alerts)
    /// so every sound path goes through the same device.
    @discardableResult
    func setDefaultOutputDevice(_ id: AudioDeviceID) -> Bool {
        let mainOK = Self.setValue(AudioObjectID(kAudioObjectSystemObject),
                                   Self.address(kAudioHardwarePropertyDefaultOutputDevice), id)
        Self.setValue(AudioObjectID(kAudioObjectSystemObject),
                      Self.address(kAudioHardwarePropertyDefaultSystemOutputDevice), id)
        return mainOK
    }

    // MARK: - Output volume (for level sync)

    /// Master output volume (0…1), or nil if the device exposes none. Tries the
    /// master element, then averages the first two channels.
    func outputVolume(_ id: AudioDeviceID) -> Float? {
        var master = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &master), let v: Float32 = Self.getValue(id, master, default: 0) {
            return v
        }
        var vals: [Float] = []
        for ch in [UInt32(1), UInt32(2)] {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)
            if AudioObjectHasProperty(id, &a), let v: Float32 = Self.getValue(id, a, default: 0) { vals.append(v) }
        }
        return vals.isEmpty ? nil : vals.reduce(0, +) / Float(vals.count)
    }

    /// Set the master output volume (0…1). Returns true if the device accepted
    /// it (some devices, e.g. certain digital/BT outputs, aren't settable).
    @discardableResult
    func setOutputVolume(_ id: AudioDeviceID, _ volume: Float) -> Bool {
        let v = Float32(max(0, min(1, volume)))
        var master = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &master),
           AudioObjectIsPropertySettable(id, &master, &settable) == noErr, settable.boolValue {
            return Self.setValue(id, master, v)
        }
        var ok = false
        for ch in [UInt32(1), UInt32(2)] {
            var a = Self.address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, ch)
            var s: DarwinBoolean = false
            if AudioObjectHasProperty(id, &a),
               AudioObjectIsPropertySettable(id, &a, &s) == noErr, s.boolValue {
                if Self.setValue(id, a, v) { ok = true }
            }
        }
        return ok
    }

    /// Master mute state, or nil if the device exposes no mute control. Tries
    /// the master element, then the first two channels (muted only if both are).
    func outputMute(_ id: AudioDeviceID) -> Bool? {
        var master = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &master), let v: UInt32 = Self.getValue(id, master, default: 0) {
            return v != 0
        }
        var vals: [Bool] = []
        for ch in [UInt32(1), UInt32(2)] {
            var a = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, ch)
            if AudioObjectHasProperty(id, &a), let v: UInt32 = Self.getValue(id, a, default: 0) { vals.append(v != 0) }
        }
        return vals.isEmpty ? nil : vals.allSatisfy { $0 }
    }

    /// Set the master mute state. Returns true if the device accepted it (some
    /// devices expose a read-only mute, or none at all).
    @discardableResult
    func setOutputMute(_ id: AudioDeviceID, _ muted: Bool) -> Bool {
        let v = UInt32(muted ? 1 : 0)
        var master = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &master),
           AudioObjectIsPropertySettable(id, &master, &settable) == noErr, settable.boolValue {
            return Self.setValue(id, master, v)
        }
        var ok = false
        for ch in [UInt32(1), UInt32(2)] {
            var a = Self.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput, ch)
            var s: DarwinBoolean = false
            if AudioObjectHasProperty(id, &a),
               AudioObjectIsPropertySettable(id, &a, &s) == noErr, s.boolValue {
                if Self.setValue(id, a, v) { ok = true }
            }
        }
        return ok
    }

    // MARK: - Sample rate

    func nominalSampleRate(_ id: AudioDeviceID) -> Double? {
        Self.getValue(id, Self.address(kAudioDevicePropertyNominalSampleRate), default: Float64(0))
    }

    func availableSampleRates(_ id: AudioDeviceID) -> [Double] {
        let ranges: [AudioValueRange] = Self.getArray(id, Self.address(kAudioDevicePropertyAvailableNominalSampleRates))
        return ranges.map { $0.mMinimum }
    }

    @discardableResult
    func setNominalSampleRate(_ id: AudioDeviceID, _ rate: Double) -> Bool {
        Self.setValue(id, Self.address(kAudioDevicePropertyNominalSampleRate), Float64(rate))
    }

    /// Block (briefly, on the calling thread) until a device's nominal rate
    /// actually reaches `rate`. HAL rate changes are applied asynchronously via
    /// a configuration-change handshake, so a set() followed by an immediate
    /// read can still see the old rate. Bounded by `timeout` (seconds).
    func waitForNominalSampleRate(_ id: AudioDeviceID, _ rate: Double, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let current = nominalSampleRate(id), abs(current - rate) < 1.0 { return }
            usleep(10_000)   // 10 ms
        }
    }

    /// Requests a HAL IO buffer size; smaller buffers reduce latency at the
    /// cost of more wakeups. Best-effort — devices clamp to their own limits.
    func setBufferFrameSize(_ id: AudioDeviceID, _ frames: UInt32) {
        Self.setValue(id, Self.address(kAudioDevicePropertyBufferFrameSize), frames)
    }

    // MARK: - Notifications

    func startObserving() {
        addListener(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDevices)) { [weak self] in
            self?.onDevicesChanged?()
        }
        addListener(AudioObjectID(kAudioObjectSystemObject), Self.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in
            self?.onDefaultOutputChanged?()
        }
    }

    private func addListener(_ objectID: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        var address = addr
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        AudioObjectAddPropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        listenerBlocks.append((objectID, addr, block))
    }

    deinit {
        for (objectID, addr, block) in listenerBlocks {
            var address = addr
            AudioObjectRemovePropertyListenerBlock(objectID, &address, DispatchQueue.main, block)
        }
    }
}
