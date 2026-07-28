import AVFoundation
import AppKit
import Combine
import CoreAudio
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import os.log

enum LatencyPreset: String, Codable, CaseIterable, Identifiable {
    case low, medium, high

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .low:    return "Low (~25 ms)"
        case .medium: return "Medium (~45 ms)"
        case .high:   return "High (~85 ms)"
        }
    }
    /// HAL IO buffer size; the ring-buffer target level scales from this.
    var bufferFrames: UInt32 {
        switch self {
        case .low:    return 256
        case .medium: return 512
        case .high:   return 1024
        }
    }
}

/// Everything persisted across launches.
private struct PersistedSettings: Codable {
    var isEnabled = false
    var outputDeviceUID: String?
    var profile = EQProfile.flat()
    var latency = LatencyPreset.medium
    // Optional so settings saved by builds that predate these features
    // still decode (missing key ≠ corrupt settings).
    var tone: ToneControls?
    var effects: EffectsSettings?
    var autoRules: [AutoRule]?
    var matchLoudness: Bool?
}

@MainActor
final class AppState: ObservableObject {

    // nonisolated: Logger is Sendable and is used from the off-main pipeline queue.
    nonisolated private static let log = Logger(subsystem: "com.freq.app", category: "app")
    private static let settingsKey = "settings.v1"

    // MARK: - Published state

    @Published var isEnabled = false { didSet { if oldValue != isEnabled { enabledDidChange() } } }
    @Published private(set) var outputDevices: [AudioDevice] = []
    @Published var selectedOutputUID: String? { didSet { if oldValue != selectedOutputUID { settingsDidChange() } } }
    @Published var profile = EQProfile.flat() { didSet { if oldValue != profile { profileDidChange() } } }
    @Published var tone = ToneControls() { didSet { if oldValue != tone { toneDidChange() } } }
    @Published var effects = EffectsSettings() { didSet { if oldValue != effects { effectsDidChange() } } }
    /// A/B compare: momentarily bypass all processing to hear the raw audio.
    /// Not persisted — it's a transient comparison, not a saved preference.
    @Published var compareBypass = false { didSet { if oldValue != compareBypass { applyCompareBypass() } } }
    @Published var latency = LatencyPreset.medium { didSet { if oldValue != latency { settingsDidChange() } } }
    /// Add the EQ preamp back as limiter-protected output makeup, so enabling
    /// FrEQ doesn't drop the loudness below the raw system audio.
    @Published var matchLoudness = true { didSet { if oldValue != matchLoudness { matchLoudnessDidChange() } } }
    @Published private(set) var driverInstalled = false
    @Published private(set) var micPermissionDenied = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var activeOutputName: String?
    /// Set while a (slow, off-main) pipeline start is in flight, so the UI can
    /// show an honest "Connecting to X…" instead of a frozen "Starting…".
    @Published private(set) var connectingName: String?
    /// Feedback from the last profile import (shown under the profile row).
    @Published private(set) var lastImportMessage: String?
    @Published private(set) var lastImportFailed = false
    /// User-saved presets (built-ins live in SavedPreset.factory).
    @Published private(set) var userPresets: [SavedPreset] = []
    /// Devices that auto-enable FrEQ on connect / disable on disconnect.
    @Published var autoRules: [AutoRule] = [] { didSet { if !isLoadingSettings, oldValue != autoRules { settingsDidChange() } } }

    // MARK: - Internals

    // nonisolated: these manage their own concurrency. Pipeline start/stop are
    // serialized on `pipelineQueue`; live `apply(…)` runs on main gated by
    // `pipeline.isRunning` (false during a transition). deviceManager's methods
    // are thread-safe CoreAudio pass-throughs. This lets the off-main start
    // touch them without main-actor isolation warnings.
    nonisolated(unsafe) private let deviceManager = AudioDeviceManager()
    nonisolated(unsafe) private let pipeline = AudioPipeline()
    /// Set while we are changing the default device ourselves, so the
    /// default-changed listener can tell our writes from user actions.
    private var isAdjustingDefault = false
    /// UID of the real output device that was the system default before we
    /// switched it to the virtual device. Restored on disable/quit so audio
    /// returns to exactly the device the user was on — never an arbitrary
    /// "first" device (which, on machines with other loopback drivers, can be
    /// a silent virtual sink).
    private var previousDefaultUID: String?
    /// Volume-sync bookkeeping: the physical device we set to unity, so we can
    /// restore its level on disable. Fixes the loudness mismatch between direct
    /// playback and routing through the virtual device (two volume stages).
    private var volumeSyncedUID: String?
    private var restartWorkItem: DispatchWorkItem?
    private var isLoadingSettings = false
    private var cancellables: Set<AnyCancellable> = []

    // Auto-retry budget for a single (re)enable. A Bluetooth device that was
    // just handed the default back needs a moment to renegotiate its A2DP link
    // and settle its sample rate; the virtual device's rate change is also
    // asynchronous. The first pipeline start can therefore land mid-transition
    // and produce silence — which is exactly why manually re-selecting the
    // output device (a second restart) fixes it. We automate that: on a failed
    // start or a failed post-start health check, retry a few times with an
    // increasing delay. Reset whenever the user triggers a fresh restart.
    private var restartAttempt = 0
    private static let maxRestartAttempts = 4

    // Pipeline start/stop can block for seconds on Bluetooth (A2DP link wake),
    // so they run on this serial queue instead of the main thread. Live
    // parameter changes (apply) stay on main and are gated by
    // `pipeline.isRunning`, which only becomes true once a start finishes — so
    // they never touch the graph while it is being built/torn down here.
    private let pipelineQueue = DispatchQueue(label: "com.freq.pipeline")
    /// Bumped on every (re)start/stop; a start completion whose generation is
    /// stale knows it was superseded and tears itself down.
    private var startGeneration = 0

    /// Sample rates the virtual driver supports (must match the driver).
    private static let driverSampleRates: [Double] = [44100, 48000, 88200, 96000, 176400, 192000]

    init() {
        // The UI is designed for a dark, glassy look; lock the whole app to
        // dark appearance so it doesn't wash out in Light Mode.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        DebugLog.reset()
        loadSettings()
        loadPresets()
        lastRoutingKey = "\(selectedOutputUID ?? "-")|\(latency.rawValue)"
        refreshDevices()
        // Before anything can enable and sync volume again, undo a volume sync
        // that a previous run left stranded by crashing / being force-quit /
        // killed before it could restore. Otherwise that run's "physical at
        // 100%" is read as the real volume and re-applied → loud every relaunch.
        restoreStrandedVolumeSync()
        DebugLog.log("launch: enabled=\(isEnabled) selectedUID=\(selectedOutputUID ?? "Automatic") driverInstalled=\(driverInstalled) outputs=[\(outputDevices.map { $0.name }.joined(separator: ", "))]")

        deviceManager.onDevicesChanged = { [weak self] in self?.devicesChanged() }
        deviceManager.onDefaultOutputChanged = { [weak self] in self?.defaultOutputChanged() }
        deviceManager.startObserving()

        // An engine-level configuration change (output device sample rate or
        // channel layout changed under us) requires a graph rebuild.
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                self.scheduleRestart()
            }
        }

        // Restore the user's real output device before the process dies;
        // otherwise the system is left pointing at a now-silent virtual device.
        // Run synchronously in the notification body — willTerminate is posted
        // immediately before exit, so a dispatched Task may never run.
        // AudioObjectSetPropertyData for the default device is synchronous, so
        // the restore completes before we return here.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }

        // Auto-enable if a ruled device (e.g. the headphones) is already
        // connected at launch.
        applyLaunchAutoRule()

        // Recover from a stranded default: if a previous run crashed (or was
        // force-quit) while enabled, the system default can still be our
        // virtual device with nothing draining it — silence. If we launch
        // disabled in that state, hand the default back to real hardware.
        if !isEnabled, driverInstalled,
           let virtual = deviceManager.virtualDevice(),
           deviceManager.defaultOutputDeviceID == virtual.id {
            Self.log.info("launch: default was stranded on virtual device; restoring")
            restoreDefaultOutput()
        }

        // NOTE: do NOT kick off a restart here for isEnabled==true. Assigning
        // isEnabled in loadSettings() already fired enabledDidChange(), which
        // requests microphone permission and only then starts audio. A second
        // restart here would race ahead and open the capture AUHAL while the
        // permission prompt is still pending, wedging capture.start.
    }

    // MARK: - Device bookkeeping

    private func refreshDevices() {
        outputDevices = deviceManager.selectableOutputDevices()
        driverInstalled = deviceManager.virtualDevice() != nil
    }

    private func devicesChanged() {
        let previous = outputDevices
        refreshDevices()
        // Auto-enable rules run first, and regardless of current on/off state,
        // so a ruled device connecting can switch FrEQ on.
        applyAutoRules(previous: previous)
        guard isEnabled else { return }

        if let selected = selectedOutputUID {
            let wasPresent = previous.contains { $0.uid == selected }
            let isPresent = outputDevices.contains { $0.uid == selected }
            // Selected device (dis)appeared — e.g. Bluetooth headphones
            // connecting or dropping — reroute either way.
            if wasPresent != isPresent {
                Self.log.info("selected output presence changed (present=\(isPresent)); rerouting")
                scheduleRestart()
                return
            }
        }
        if !driverInstalled {
            stopEverything(message: "Driver not installed")
        }
    }

    private func defaultOutputChanged() {
        let curID = deviceManager.defaultOutputDeviceID
        let curName = curID.flatMap { deviceManager.device(byID: $0)?.name } ?? "nil"
        DebugLog.log("defaultOutputChanged: now='\(curName)' enabled=\(isEnabled) adjusting=\(isAdjustingDefault)")
        guard isEnabled, !isAdjustingDefault, driverInstalled else { return }
        guard let currentDefault = deviceManager.defaultOutputDeviceID,
              let virtual = deviceManager.virtualDevice(), currentDefault != virtual.id else { return }
        // The user switched the default output away from the virtual device
        // (e.g. in System Settings). Adopt their choice as the EQ target and
        // take the default back — same behavior as eqMac. The isAdjustingDefault
        // flag prevents this listener from reacting to our own writes, which
        // would otherwise loop.
        if let device = deviceManager.device(byID: currentDefault), !device.isVirtual {
            Self.log.info("default output changed externally to \(device.name); adopting as EQ target")
            DebugLog.log("adopting external default '\(device.name)' as EQ target → restart")
            selectedOutputUID = device.uid
            scheduleRestart()
        }
    }

    // MARK: - Enable / disable

    private func enabledDidChange() {
        DebugLog.log("=== enable toggled → \(isEnabled) ===")
        settingsDidChange()
        if isEnabled {
            ensureMicPermission { [weak self] granted in
                guard let self else { return }
                DebugLog.log("mic permission granted=\(granted)")
                if granted {
                    self.micPermissionDenied = false
                    self.scheduleRestart()
                } else {
                    self.micPermissionDenied = true
                    self.isEnabled = false
                    self.statusMessage = "Microphone access is required to capture system audio."
                }
            }
        } else {
            stopEverything(message: nil)
        }
    }

    /// macOS treats capture from any input stream — including our virtual
    /// loopback — as microphone use, so the TCC prompt is unavoidable.
    private func ensureMicPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Main window

    // A programmatic AppKit window hosting the full SwiftUI controls. Built
    // lazily (not a declarative `Window` scene) so that an LSUIElement
    // menu-bar app launches with NO window and only shows one when the user
    // asks — a `Window` scene would auto-open at every launch on macOS 13.
    private var mainWindow: NSWindow?

    func showMainWindow() {
        if mainWindow == nil {
            let hosting = NSHostingController(rootView: MainView().environmentObject(self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "FrEQ"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 560, height: 720))
            window.contentMinSize = NSSize(width: 480, height: 500)
            window.isReleasedWhenClosed = false   // reuse across open/close
            window.appearance = NSAppearance(named: .darkAqua)
            // Translucent chrome so the Liquid Glass / material background shows.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isOpaque = false
            window.backgroundColor = .clear
            window.center()
            window.setFrameAutosaveName("FrEQMainWindow")
            mainWindow = window
        }
        // Accessory apps must activate explicitly for the window to come
        // forward and accept key input.
        NSApp.activate(ignoringOtherApps: true)
        mainWindow?.makeKeyAndOrderFront(nil)
        // Clear first responder so the first text field (band 1's frequency)
        // isn't auto-focused with its contents selected on open.
        DispatchQueue.main.async { [weak mainWindow] in
            mainWindow?.makeFirstResponder(nil)
        }
    }

    // MARK: - Routing

    /// Debounced restart: device-list churn (a Bluetooth connect fires several
    /// notifications back-to-back) collapses into one rebuild. This is the
    /// user/system-triggered entry point, so it resets the auto-retry budget.
    private func scheduleRestart() {
        restartAttempt = 0
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartAudio() }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func restartAudio() {
        refreshDevices()

        guard isEnabled else {
            pipelineQueue.async { [weak self] in self?.pipeline.stop() }
            return
        }
        guard driverInstalled, let virtual = deviceManager.virtualDevice() else {
            statusMessage = "Driver not installed. Run scripts/install-driver.sh."
            return
        }
        guard let output = preferredOutputDevice() else {
            scheduleRetryOrFail("No output device available.")
            return
        }

        // Run the virtual device at the output device's rate when it supports
        // it — the render graph then does no rate conversion at all.
        let outputRate = deviceManager.nominalSampleRate(output.id) ?? 48000
        let captureRate = Self.driverSampleRates.contains(outputRate) ? outputRate : 48000
        let ringBuffer = latency.bufferFrames
        // Bluetooth chokes on tiny IO buffers (long A2DP renegotiation, ~10 s
        // stalls); give BT outputs a roomy buffer regardless of preset.
        let outputBuffer = output.isBluetooth ? max(ringBuffer, 1024) : ringBuffer

        startGeneration += 1
        let gen = startGeneration
        let attempt = restartAttempt
        statusMessage = nil
        activeOutputName = nil
        connectingName = output.name   // UI shows "Connecting to <device>…"

        // Point the system default at the virtual device BEFORE the engine
        // exists. AVAudioEngine's output node follows the system default; if we
        // changed the default AFTER starting the engine, its output would hop
        // from the physical device onto the virtual device — feeding its own
        // capture (a feedback loop) and sending nothing to the headphones. With
        // the default already on the virtual device at engine-start time, there
        // is no later default change for the engine to follow.
        makeVirtualDeviceDefault(virtual)

        // The start can block for seconds on Bluetooth, so do it off-main and
        // report back. The generation guard discards a start that a newer
        // restart/stop has superseded.
        pipelineQueue.async { [weak self] in
            guard let self else { return }
            self.pipeline.stop()

            if self.deviceManager.nominalSampleRate(virtual.id) != captureRate {
                self.deviceManager.setNominalSampleRate(virtual.id, captureRate)
                // Rate change is applied asynchronously by the driver; wait for
                // it before opening a capture AUHAL at that rate.
                self.deviceManager.waitForNominalSampleRate(virtual.id, captureRate, timeout: 0.4)
            }
            self.deviceManager.setBufferFrameSize(output.id, outputBuffer)
            Self.log.info("restart attempt \(attempt): output=\(output.name, privacy: .public) rate=\(captureRate, format: .fixed(precision: 0)) bt=\(output.isBluetooth) buffer=\(outputBuffer)")
            DebugLog.log("restart attempt \(attempt): output='\(output.name)' id=\(output.id) rate=\(Int(captureRate)) bt=\(output.isBluetooth) buffer=\(outputBuffer) virtualRate=\(Int(self.deviceManager.nominalSampleRate(virtual.id) ?? 0))")

            let t0 = Date()
            var startError: String?
            do {
                try self.pipeline.start(virtualDevice: virtual.id,
                                        outputDevice: output.id,
                                        captureRate: captureRate,
                                        bufferFrames: ringBuffer)
            } catch {
                startError = error.localizedDescription
            }
            DebugLog.log("pipeline.start returned after \(String(format: "%.2f", Date().timeIntervalSince(t0)))s error=\(startError ?? "none") engineRunning=\(self.pipeline.engineRunning)")

            DispatchQueue.main.async {
                // Superseded by a newer start/stop: tear down whatever we built.
                guard self.startGeneration == gen else {
                    self.pipelineQueue.async { self.pipeline.stop() }
                    return
                }
                guard self.isEnabled else {
                    self.pipelineQueue.async { self.pipeline.stop() }
                    self.restoreDefaultOutput()
                    self.connectingName = nil
                    return
                }
                if let startError {
                    self.pipelineQueue.async { self.pipeline.stop() }
                    self.restoreDefaultOutput()
                    self.connectingName = nil
                    Self.log.error("pipeline start failed: \(startError, privacy: .public)")
                    self.scheduleRetryOrFail("Audio engine error: \(startError)")
                    return
                }
                self.pipeline.apply(profile: self.profile)
                self.pipeline.apply(tone: self.tone)
                self.pipeline.apply(effects: self.effects)
                if self.compareBypass { self.pipeline.bypassAllProcessing() }
                // Default is already virtual (set before start). Force the
                // engine output onto the physical device and re-assert it a few
                // times, because the "follow the default" can arrive late.
                let targetOutput = output.id
                self.pipeline.pinOutputDevice(targetOutput)
                for delay in [0.2, 0.6, 1.2] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self, self.startGeneration == gen, self.pipeline.isRunning else { return }
                        if self.pipeline.outputDeviceID != targetOutput {
                            DebugLog.log("re-pin: engineOut drifted to \(self.pipeline.outputDeviceID), forcing back to \(targetOutput)")
                            self.pipeline.pinOutputDevice(targetOutput)
                        }
                    }
                }
                self.syncVolumeOnEnable(output: output, virtual: virtual)
                self.updateLoudnessMakeup()
                self.activeOutputName = output.name
                self.connectingName = nil
                self.scheduleMonitorTick()
                let nowDefault = self.deviceManager.defaultOutputDeviceID
                DebugLog.log("start OK: systemDefault=\(nowDefault.map { String($0) } ?? "nil")(want virtual \(virtual.id)) engineOut=\(self.pipeline.outputDeviceID)(want \(output.id)) capturedFrames=\(self.pipeline.capturedFrames)")
                self.scheduleHealthCheck(virtual: virtual, output: output.name)
            }
        }
    }

    /// Retry a failed (re)start a few times with increasing delay, then give
    /// up with a clear message. Automates the "toggle again / reselect device"
    /// workaround for transient Bluetooth/rate-settling failures.
    private func scheduleRetryOrFail(_ message: String) {
        guard restartAttempt < Self.maxRestartAttempts else {
            statusMessage = message + " — toggle off/on to retry."
            activeOutputName = nil
            Self.log.error("giving up after \(Self.maxRestartAttempts) attempts: \(message, privacy: .public)")
            return
        }
        restartAttempt += 1
        let delay = 0.4 * Double(restartAttempt)
        Self.log.error("\(message, privacy: .public) — retry \(self.restartAttempt) in \(delay, format: .fixed(precision: 2))s")
        restartWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.restartAudio() }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Periodic diagnostic while running (no-op unless FREQ_DEBUG=1):
    /// confirms where the engine is outputting. Self-terminates when stopped.
    private func scheduleMonitorTick() {
        guard DebugLog.enabled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isEnabled, self.pipeline.isRunning else { return }
            let inMax = self.pipeline.inputBands.max() ?? -1
            let outMax = self.pipeline.outputBands.max() ?? -1
            DebugLog.log("monitor: capturedFrames=\(self.pipeline.capturedFrames) inBandMax=\(String(format: "%.2f", inMax)) outBandMax=\(String(format: "%.2f", outMax)) inPeak=\(String(format: "%.3f", self.pipeline.inputLevel))")
            self.scheduleMonitorTick()
        }
    }

    /// After a start, confirm the routing actually took: the virtual device is
    /// the system default and the engine is running. If not (a transient that
    /// a manual restart would have fixed), retry automatically.
    private func scheduleHealthCheck(virtual: AudioDevice, output: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.isEnabled, self.pipeline.isRunning else { return }
            let defaultIsVirtual = self.deviceManager.defaultOutputDeviceID == virtual.id
            let engineRunning = self.pipeline.engineRunning
            let frames = self.pipeline.capturedFrames
            DebugLog.log("health check @0.6s: default==virtual=\(defaultIsVirtual) engineRunning=\(engineRunning) engineOutputDevice=\(self.pipeline.outputDeviceID) capturedFrames=\(frames)")
            if defaultIsVirtual && engineRunning {
                self.restartAttempt = 0
                Self.log.info("health ok: routing to \(output, privacy: .public)")
            } else {
                Self.log.error("health FAIL (default==virtual: \(defaultIsVirtual), engine: \(engineRunning)); retrying")
                self.scheduleRetryOrFail("Routing didn't take")
            }
        }
    }

    /// Move the volume onto the virtual device and set the physical device to
    /// unity, so audio passes through a single volume stage (matching direct
    /// playback). If the physical device can't be set to unity, keep the
    /// virtual device at unity instead so we don't double-attenuate.
    private func syncVolumeOnEnable(output: AudioDevice, virtual: AudioDevice) {
        restoreVolumeSync()   // undo any previous sync first
        guard let physVol = deviceManager.outputVolume(output.id) else { return }
        deviceManager.setOutputVolume(virtual.id, physVol)
        let unity = deviceManager.setOutputVolume(output.id, 1.0)
        if unity {
            volumeSyncedUID = output.uid
            // Persist the pre-sync volume so an unclean exit can be undone at
            // the next launch (see restoreStrandedVolumeSync).
            persistVolumeSyncRecord(uid: output.uid, savedVolume: physVol)
            DebugLog.log("volume sync: virtual←\(String(format: "%.2f", physVol)), \(output.name)←1.0")
        } else {
            // Couldn't set the physical to unity — avoid double attenuation by
            // leaving the virtual device at unity (physical keeps the volume).
            deviceManager.setOutputVolume(virtual.id, 1.0)
            clearVolumeSyncRecord()   // physical untouched; nothing to restore
            DebugLog.log("volume sync: \(output.name) volume not settable; virtual←1.0")
        }
    }

    /// Restore the physical device's volume to the current perceived level
    /// (the virtual device's), so loudness is continuous when we stand down.
    private func restoreVolumeSync() {
        guard let uid = volumeSyncedUID, let dev = deviceManager.device(byUID: uid) else { return }
        let level = deviceManager.virtualDevice().flatMap { deviceManager.outputVolume($0.id) } ?? 1.0
        deviceManager.setOutputVolume(dev.id, level)
        DebugLog.log("volume sync restored: \(dev.name)←\(String(format: "%.2f", level))")
        volumeSyncedUID = nil
        clearVolumeSyncRecord()
    }

    // MARK: Crash-safe volume-sync bookkeeping
    //
    // Volume sync sets the physical device to unity (100%) while enabled and
    // restores it on disable/quit. If the app dies before that clean restore
    // (crash, force-quit, `pkill`), the device is left at 100%; the next launch
    // would read that as the user's real volume and re-apply it — so loudness
    // ratchets to full on every relaunch. To make it crash-safe we persist the
    // pre-sync volume and hand it back at the next launch.
    private static let volSyncUIDKey = "volumeSync.deviceUID"
    private static let volSyncVolKey = "volumeSync.savedVolume"

    private func persistVolumeSyncRecord(uid: String, savedVolume: Float) {
        UserDefaults.standard.set(uid, forKey: Self.volSyncUIDKey)
        UserDefaults.standard.set(Double(savedVolume), forKey: Self.volSyncVolKey)
    }

    private func clearVolumeSyncRecord() {
        UserDefaults.standard.removeObject(forKey: Self.volSyncUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.volSyncVolKey)
    }

    /// If a previous run set a device to unity for volume sync and then died
    /// before restoring, hand the saved volume back now — before anything can
    /// enable and re-sync — so the device isn't stranded loud.
    private func restoreStrandedVolumeSync() {
        guard let uid = UserDefaults.standard.string(forKey: Self.volSyncUIDKey),
              UserDefaults.standard.object(forKey: Self.volSyncVolKey) != nil else { return }
        let vol = Float(UserDefaults.standard.double(forKey: Self.volSyncVolKey))
        if let dev = deviceManager.device(byUID: uid) {
            deviceManager.setOutputVolume(dev.id, vol)
            DebugLog.log("launch: restored stranded volume \(dev.name)←\(String(format: "%.2f", vol)) (unclean exit)")
        }
        clearVolumeSyncRecord()
    }

    private func makeVirtualDeviceDefault(_ virtual: AudioDevice) {
        guard deviceManager.defaultOutputDeviceID != virtual.id else { return }
        // Remember the real device we are taking over so we can hand it back
        // exactly on disable. Only record a real (non-virtual) device — never
        // the virtual device or another loopback sink.
        if let id = deviceManager.defaultOutputDeviceID,
           let device = deviceManager.device(byID: id), !device.isVirtual {
            previousDefaultUID = device.uid
        }
        isAdjustingDefault = true
        deviceManager.setDefaultOutputDevice(virtual.id)
        // The listener fires asynchronously on main; lower the flag after the
        // notifications from our own write have drained.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isAdjustingDefault = false
        }
    }

    /// The real output device to render to / restore to, in priority order.
    /// `outputDevices` already excludes all virtual/loopback devices, so every
    /// candidate here is real hardware — automatic fallback can never resolve
    /// to a silent sink.
    private func preferredOutputDevice() -> AudioDevice? {
        // 1. The user's explicit choice, if still present.
        if let uid = selectedOutputUID, let device = outputDevices.first(where: { $0.uid == uid }) {
            return device
        }
        // 2. The exact real device we took over from.
        if let uid = previousDefaultUID, let device = outputDevices.first(where: { $0.uid == uid }) {
            return device
        }
        // 3. The current system default, if it is real hardware.
        if let id = deviceManager.defaultOutputDeviceID,
           let device = deviceManager.device(byID: id), !device.isVirtual, device.outputChannelCount > 0 {
            return device
        }
        // 4. Any real output.
        return outputDevices.first
    }

    private func stopEverything(message: String?) {
        startGeneration += 1      // invalidate any in-flight start
        restartWorkItem?.cancel()
        restoreVolumeSync()       // hand the volume back to the physical device
        statusMessage = message
        activeOutputName = nil
        connectingName = nil
        compareBypass = false     // reset the transient A/B state
        pipelineQueue.async { [weak self] in self?.pipeline.stop() }
        restoreDefaultOutput()
    }

    /// Puts the default output back on the real device the user was on so audio
    /// keeps playing (un-EQ'd) when we stand down. Only acts while the virtual
    /// device is the current default (don't fight a choice the user already
    /// made).
    private func restoreDefaultOutput() {
        guard let virtual = deviceManager.virtualDevice(),
              deviceManager.defaultOutputDeviceID == virtual.id else { return }
        guard let target = preferredOutputDevice() else {
            Self.log.error("restore: no real output device available to fall back to")
            return
        }
        isAdjustingDefault = true
        let ok = deviceManager.setDefaultOutputDevice(target.id)
        Self.log.info("restored default output to \(target.name, privacy: .public)")
        DebugLog.log("restoreDefaultOutput → '\(target.name)' (setDefault ok=\(ok)); systemDefault now=\(deviceManager.defaultOutputDeviceID.map { String($0) } ?? "nil")")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isAdjustingDefault = false
        }
    }

    func shutdown() {
        // Called from willTerminate — must be synchronous (the process is about
        // to exit). Restoring the system default to the real device is the only
        // thing that matters here; the engine is torn down by process exit. We
        // deliberately do NOT call pipeline.stop() on main (it could race a
        // start still running on pipelineQueue). Bump the generation so any
        // in-flight start's completion no-ops.
        startGeneration += 1
        restartWorkItem?.cancel()
        restoreVolumeSync()
        restoreDefaultOutput()
    }

    // MARK: - EQ intents

    private func profileDidChange() {
        settingsDidChange()
        if pipeline.isRunning {
            pipeline.apply(profile: profile)
            updateLoudnessMakeup()   // preamp changed → makeup changes
        }
    }

    private func matchLoudnessDidChange() {
        settingsDidChange()
        updateLoudnessMakeup()
    }

    /// When loudness-match is on, add back the preamp attenuation as
    /// limiter-protected output gain so on/off loudness are comparable.
    private func updateLoudnessMakeup() {
        guard pipeline.isRunning else { return }
        pipeline.setMasterMakeup(matchLoudness ? Float(max(0, -profile.preamp)) : 0)
    }

    private func toneDidChange() {
        settingsDidChange()
        if pipeline.isRunning {
            pipeline.apply(tone: tone)
        }
    }

    func resetTone() {
        tone = ToneControls()
    }

    private func effectsDidChange() {
        settingsDidChange()
        if pipeline.isRunning {
            pipeline.apply(effects: effects)
        }
    }

    func resetEffects() {
        effects = EffectsSettings()
    }

    // MARK: - Presets

    private static let presetsKey = "userPresets.v1"

    private func loadPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.presetsKey),
              let list = try? JSONDecoder().decode([SavedPreset].self, from: data) else { return }
        userPresets = list
    }

    private func savePresets() {
        if let data = try? JSONEncoder().encode(userPresets) {
            UserDefaults.standard.set(data, forKey: Self.presetsKey)
        }
    }

    /// Load a preset (built-in or saved) — replaces EQ, tone and effects.
    func applyPreset(_ preset: SavedPreset) {
        profile = preset.profile
        tone = preset.tone
        effects = preset.effects
    }

    func deletePreset(_ preset: SavedPreset) {
        userPresets.removeAll { $0.id == preset.id }
        savePresets()
    }

    /// Prompt (NSAlert with a text field — reliable from any context) for a
    /// name, then save the current EQ + tone + effects as a user preset.
    func savePresetPrompt() {
        let alert = NSAlert()
        alert.messageText = "Save Preset"
        alert.informativeText = "Save the current EQ, tone and effects under a name."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Preset name"
        field.stringValue = (profile.name == "Flat" || profile.name.isEmpty) ? "My Preset" : profile.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        var snapshot = profile
        snapshot.name = name
        userPresets.append(SavedPreset(name: name, profile: snapshot, tone: tone, effects: effects))
        savePresets()
        profile.name = name
    }

    private func applyCompareBypass() {
        guard pipeline.isRunning else { return }
        if compareBypass {
            pipeline.bypassAllProcessing()
        } else {
            pipeline.apply(profile: profile)
            pipeline.apply(tone: tone)
            pipeline.apply(effects: effects)
        }
    }

    // MARK: - Metering (for the level meters)

    var inputLevel: Float { pipeline.inputLevel }
    var outputLevel: Float { pipeline.outputLevel }
    var isClipping: Bool { pipeline.isClipping }
    var clipOverDB: Float { pipeline.clipOverDB }
    var isRunningActive: Bool { pipeline.isRunning }
    var inputBands: [Float] { pipeline.inputBands }
    var outputBands: [Float] { pipeline.outputBands }
    var inputPeaks: [Float] { pipeline.inputPeaks }
    var outputPeaks: [Float] { pipeline.outputPeaks }

    // MARK: - Auto-enable rules

    func isAutoRuled(_ uid: String) -> Bool { autoRules.contains { $0.uid == uid } }

    func setAutoRule(for device: AudioDevice, on: Bool) {
        if on {
            if !isAutoRuled(device.uid) { autoRules.append(AutoRule(uid: device.uid, name: device.name)) }
        } else {
            autoRules.removeAll { $0.uid == device.uid }
        }
    }

    func removeAutoRule(uid: String) { autoRules.removeAll { $0.uid == uid } }

    /// Rules whose device isn't currently connected (shown greyed so the user
    /// can still remove them).
    var disconnectedRules: [AutoRule] {
        autoRules.filter { rule in !outputDevices.contains { $0.uid == rule.uid } }
    }

    private func ruledDevicePresent(in devices: [AudioDevice]) -> Bool {
        let ruled = Set(autoRules.map { $0.uid })
        return devices.contains { ruled.contains($0.uid) }
    }

    /// React to a ruled device connecting/disconnecting.
    private func applyAutoRules(previous: [AudioDevice]) {
        guard driverInstalled, !autoRules.isEmpty else { return }
        let now = ruledDevicePresent(in: outputDevices)
        let before = ruledDevicePresent(in: previous)
        if now && !before {
            let ruled = Set(autoRules.map { $0.uid })
            if let device = outputDevices.first(where: { ruled.contains($0.uid) }) {
                selectedOutputUID = device.uid
            }
            if !isEnabled {
                Self.log.info("auto-rule: ruled device connected → enabling")
                isEnabled = true
            }
        } else if before && !now {
            if isEnabled {
                Self.log.info("auto-rule: ruled device disconnected → disabling")
                isEnabled = false
            }
        }
    }

    /// At launch, auto-enable if a ruled device is already connected (we don't
    /// force-disable here, so manual use on other devices still works).
    private func applyLaunchAutoRule() {
        guard driverInstalled, !autoRules.isEmpty, !isEnabled else { return }
        guard ruledDevicePresent(in: outputDevices) else { return }
        let ruled = Set(autoRules.map { $0.uid })
        if let device = outputDevices.first(where: { ruled.contains($0.uid) }) {
            selectedOutputUID = device.uid
        }
        Self.log.info("auto-rule: ruled device present at launch → enabling")
        isEnabled = true
    }

    func importProfile(text: String, name: String) throws {
        var imported = try AutoEqParser.parse(text, name: name)
        var note = ""
        if imported.bands.count > EQProfile.maxBands {
            imported.bands = Array(imported.bands.prefix(EQProfile.maxBands))
            note = " (kept first \(EQProfile.maxBands) filters)"
        }
        profile = imported

        // Autosave the imported profile as a preset the first time it's seen,
        // so it's recallable from Presets later. Deduped by name so re-importing
        // the same headphone doesn't create duplicates.
        var savedNote = ""
        if !userPresets.contains(where: { $0.name == imported.name }) {
            userPresets.append(SavedPreset(name: imported.name, profile: imported, tone: tone, effects: effects))
            savePresets()
            savedNote = " · saved to Presets"
        }

        lastImportMessage = String(format: "Imported %d bands, preamp %+.1f dB%@%@",
                                   imported.bands.count, imported.preamp, note, savedNote)
        lastImportFailed = false
    }

    func importProfile(fileURL: URL) throws {
        let needsAccess = fileURL.startAccessingSecurityScopedResource()
        defer { if needsAccess { fileURL.stopAccessingSecurityScopedResource() } }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        // "Sony WH-1000XM4 ParametricEQ.txt" → "Sony WH-1000XM4"
        var name = fileURL.deletingPathExtension().lastPathComponent
        if name.hasSuffix(" ParametricEQ") {
            name = String(name.dropLast(" ParametricEQ".count))
        }
        try importProfile(text: text, name: name)
    }

    /// File import via NSOpenPanel. SwiftUI's .fileImporter (and .sheet) do
    /// not present reliably from a MenuBarExtra window, so AppKit is used
    /// directly. For an LSUIElement app the panel must run modally at a
    /// raised level after activating the app — a nonmodal begin() panel
    /// opens behind other apps' windows (or never becomes key) because an
    /// accessory app has no regular windows to anchor it.
    func importFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose an AutoEq ParametricEQ .txt export"
        panel.level = .modalPanel
        NSApp.activate(ignoringOtherApps: true)
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            try importProfile(fileURL: url)
        } catch {
            lastImportMessage = error.localizedDescription
            lastImportFailed = true
        }
    }

    /// Clipboard import: copy the profile text on autoeq.app, click import —
    /// no paste sheet needed (sheets don't present from MenuBarExtra windows).
    func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastImportMessage = "Clipboard is empty — copy the ParametricEQ text first."
            lastImportFailed = true
            return
        }
        do {
            try importProfile(text: text, name: "Clipboard profile")
        } catch {
            lastImportMessage = error.localizedDescription
            lastImportFailed = true
        }
    }

    func resetToFlat() {
        profile = .flat()
    }

    func addBand() {
        guard profile.bands.count < EQProfile.maxBands else { return }
        profile.bands.append(EQBand())
    }

    func removeBand(_ band: EQBand) {
        profile.bands.removeAll { $0.id == band.id }
    }

    var diagnosticsText: String {
        let d = pipeline.diagnostics
        return "buffer \(d.fill) frames · underruns \(d.underruns) · re-centers \(d.recenters)"
    }

    // MARK: - Persistence

    private func loadSettings() {
        isLoadingSettings = true
        defer { isLoadingSettings = false }
        guard let data = UserDefaults.standard.data(forKey: Self.settingsKey),
              let settings = try? JSONDecoder().decode(PersistedSettings.self, from: data) else { return }
        isEnabled = settings.isEnabled
        selectedOutputUID = settings.outputDeviceUID
        profile = settings.profile
        latency = settings.latency
        tone = settings.tone ?? ToneControls()
        effects = settings.effects ?? EffectsSettings()
        autoRules = settings.autoRules ?? []
        matchLoudness = settings.matchLoudness ?? true
    }

    private func settingsDidChange() {
        guard !isLoadingSettings else { return }
        let settings = PersistedSettings(isEnabled: isEnabled,
                                         outputDeviceUID: selectedOutputUID,
                                         profile: profile,
                                         latency: latency,
                                         tone: tone,
                                         effects: effects,
                                         autoRules: autoRules,
                                         matchLoudness: matchLoudness)
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.settingsKey)
        }
        if pipeline.isRunning, oldRoutingChanged() {
            scheduleRestart()
        }
    }

    /// Latency and output selection require a pipeline rebuild; EQ edits don't.
    private var lastRoutingKey = ""
    private func oldRoutingChanged() -> Bool {
        let key = "\(selectedOutputUID ?? "-")|\(latency.rawValue)"
        defer { lastRoutingKey = key }
        return key != lastRoutingKey
    }
}
