import SwiftUI

// MARK: - Menu-bar dropdown (compact)

/// The menu-bar popover. Intentionally minimal — status, master toggle, and a
/// button to open the full controls window. The rich UI lives in a resizable
/// window (MainView), because a menu-bar popover is height-constrained and
/// can't show a large effects rack usably.
struct MenuBarContent: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Circle().fill(state.statusColor).frame(width: 10, height: 10)
                Text("FrEQ").font(.headline)
                Spacer()
                Toggle("", isOn: $state.isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!state.driverInstalled)
            }

            Text(state.statusText)
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)

            if !state.driverInstalled {
                Label("Driver not installed. Run scripts/install-driver.sh.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            } else if state.micPermissionDenied {
                Button("Grant microphone access") { state.openMicrophoneSettings() }
                    .glassButton()
                    .controlSize(.small)
            }
            if let message = state.statusMessage {
                Text(message).font(.caption2).foregroundStyle(.orange).lineLimit(2)
            }

            Button {
                state.showMainWindow()
            } label: {
                Label("Open Controls…", systemImage: "slider.horizontal.3")
                    .frame(maxWidth: .infinity)
            }
            .glassButton(prominent: true)
            .controlSize(.large)

            HStack {
                Text(state.profile.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 270)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Main window (full controls)

/// Status colour shared across the headers.
extension AppState {
    var statusColor: Color {
        if activeOutputName != nil { return .green }
        if connectingName != nil || isEnabled { return .orange }
        return .secondary.opacity(0.5)
    }
    var statusText: String {
        if let active = activeOutputName { return "EQ active → \(active)" }
        if let connecting = connectingName { return "Connecting to \(connecting)…" }
        if isEnabled { return "Starting…" }
        return "Off — audio passes through untouched"
    }
}

/// The full controls window: native tabs, resizable, scrolls properly.
struct MainView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            windowHeader
            // Driven by a @Published value so the strip reliably appears when
            // audio goes active (a computed pipeline flag doesn't re-render).
            if state.activeOutputName != nil { meterStrip }
            TabView {
                EQTab()
                    .tabItem { Label("Equalizer", systemImage: "waveform") }
                EffectsTab()
                    .tabItem { Label("Effects", systemImage: "dial.high") }
                OutputTab()
                    .tabItem { Label("Output", systemImage: "hifispeaker") }
            }
        }
        .padding(16)
        .frame(minWidth: 480, minHeight: 500)
        .preferredColorScheme(.dark)
        .background {
            // Frosted translucency, plus a light dark scrim so the wallpaper
            // colour bleeds through less and the glass stays legible on any
            // background.
            ZStack {
                VisualEffectBackground()
                Color.black.opacity(0.18)
            }
            .ignoresSafeArea()
        }
    }

    private var windowHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(state.statusColor.opacity(0.22)).frame(width: 34, height: 34)
                Image(systemName: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.statusColor)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("FrEQ").font(.title3).fontWeight(.semibold)
                Text(state.statusText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if !state.driverInstalled {
                Label("Driver not installed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            } else if state.micPermissionDenied {
                Button("Grant mic access") { state.openMicrophoneSettings() }
                    .glassButton()
                    .controlSize(.small)
            } else {
                // Little neon tagline beside the toggle (derived from the
                // user's line "made for ears that hear tiny details").
                Text("For ears that hear the tiny details")
                    .font(.custom("BradleyHandITCTT-Bold", size: 15))
                    // Bright when the EQ is on, muted when the master is off.
                    .foregroundStyle(.white.opacity(state.isEnabled ? 0.92 : 0.32))
                    .shadow(color: .black.opacity(state.isEnabled ? 0.45 : 0.2), radius: 2)
                    .fixedSize()
                    .padding(.trailing, 4)
                    .animation(.easeInOut(duration: 0.25), value: state.isEnabled)
            }
            Toggle("", isOn: $state.isEnabled)
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(!state.driverInstalled)
                .help(state.isEnabled ? "Disable — restore normal output" : "Enable system-wide EQ")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard(20)
    }

    /// Live input/output meters, a clip light, and the Processed/Original
    /// compare switch.
    private var meterStrip: some View {
        HStack(spacing: 14) {
            // IN and OUT side by side (left | right), each its own panel.
            HStack(spacing: 12) {
                WaveformView(label: "IN", bands: { state.inputBands }, peaks: { state.inputPeaks })
                    .frame(maxWidth: .infinity)
                Rectangle().fill(.white.opacity(0.08)).frame(width: 1, height: 44)
                WaveformView(label: "OUT", bands: { state.outputBands }, peaks: { state.outputPeaks })
                    .frame(maxWidth: .infinity)
            }
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)

            // Clip indicator — animates on its own timer so it lights promptly.
            TimelineView(.periodic(from: .now, by: 1.0 / 20.0)) { _ in
                let clip = state.isClipping
                let over = state.clipOverDB
                HStack(spacing: 5) {
                    Circle()
                        .fill(clip ? Color.red : Color.secondary.opacity(0.3))
                        .frame(width: 8, height: 8)
                    Text("CLIP")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(clip ? .red : .secondary)
                }
                .contentShape(Rectangle())
                .help(clip
                      ? String(format: "Clipping: peaking +%.1f dB past 0 dB. The limiter is catching it (no distortion), but for cleaner sound lower the Preamp by about %.0f dB, or reduce a boosted band/effect.", over, max(1, ceil(Double(over))))
                      : "No clipping. Lights only when your EQ/effects push the signal past 0 dB — normal full-scale audio no longer trips it.")
            }

            // A/B compare, stated plainly: hear your settings vs. the raw sound.
            Picker("", selection: $state.compareBypass) {
                Text("Processed").tag(false)
                Text("Original").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Compare: “Processed” is your EQ + effects; “Original” bypasses everything so you hear the untouched audio. Flip between them to judge the difference.")

            InfoButton(title: "Meters & Compare", markdown: meterHelpText)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassCard(16)
    }
}

private let meterHelpText = """
**IN** — level of the audio coming in, before any processing.

**OUT** — level after your EQ, tone and effects.

**CLIP** — lights red when processing pushes the signal past 0 dB (maximum). The limiter stops it from distorting, but for cleaner sound lower the **Preamp** or ease a boost.

**Processed / Original** — an A/B compare switch. **Original** bypasses all EQ and effects so you hear the raw audio; **Processed** is your settings. Flip between them to hear exactly what FrEQ is doing.
"""

// MARK: - Shared controls

/// Label + slider + value readout on one row.
struct ParamSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0
    var format: String = "%+.1f dB"
    /// Multiplier applied to the readout only (e.g. 100 to show 0…1 as %).
    var scale: Double = 1

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.callout)
                .frame(width: 74, alignment: .leading)
            // Always continuous — a stepped Slider draws tick marks (the "ugly
            // bar" under the control); we snap the displayed value instead.
            Slider(value: $value, in: range)
            Text(String(format: format, displayValue))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .trailing)
        }
    }

    private var displayValue: Double {
        let v = value * scale
        return step > 0 ? (v / (step * scale)).rounded() * (step * scale) : v
    }
}

/// Titled box with an enable toggle and an ⓘ explainer; content dims when off.
struct EffectBox<Content: View>: View {
    let title: String
    @Binding var enabled: Bool
    var info: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title).font(.subheadline).fontWeight(.semibold)
                if let info { InfoButton(title: title, markdown: info) }
                Spacer()
                Toggle("", isOn: $enabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            content
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.4)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(14)
    }
}

/// ⓘ button that shows an explanatory popover (and a hover tooltip). Sized as a
/// proper glass chip so it's easy to see and click.
struct InfoButton: View {
    let title: String
    let markdown: String
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassCircle()
        .help(title)
        .popover(isPresented: $show, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(.init(markdown))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(width: 330)
        }
    }
}

private let bandsHelpText = """
Each row is one filter in the parametric EQ:

**On** — enable or bypass this band.

**Type** — the filter shape:
• **PK** — *Peaking*: a bell that boosts/cuts around **Freq**; width set by **Q**.
• **LSC** — *Low Shelf*: lifts/lowers everything **below** Freq.
• **HSC** — *High Shelf*: lifts/lowers everything **above** Freq.

**Freq** — center (PK) or corner (shelf) frequency, in Hz.

**Q** — bandwidth for Peaking filters (higher = narrower). Ignored for shelves.

**Gain** — boost (+) or cut (−), in dB.

**Preamp** (above) is applied before all bands so boosts don't clip.
"""

private let autoEqHelpText = """
Load a headphone-correction profile from **AutoEq**:

1. Open **autoeq.app** (or the AutoEq GitHub *results* folder).
2. Select your headphone model.
3. **Pick the Parametric EQ export** — on autoeq.app set the equalizer app to **“EqualizerAPO / ParametricEq”**; on GitHub download the file ending in **`ParametricEQ.txt`**.
4. Come back here → **Import AutoEq → From clipboard** (after copying the text) or **Choose .txt file…**.

**Supported:** the parametric text format — lines like `Filter 1: ON PK Fc 105 Hz Gain 4.6 dB Q 0.70`, plus the `Preamp:` line.

**Not supported:** GraphicEQ (127-point), Convolution / impulse-response (.wav), or fixed-band app presets (Spotify, Wavelet, etc.).
"""

// MARK: - EQ tab

private struct EQTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            profileRow
            ParamSlider(label: "Preamp", value: $state.profile.preamp, range: -20...10, step: 0.1)
                .help("Overall gain applied before the bands, so boosted bands don't clip. AutoEq sets this automatically.")
            Divider()
            HStack(spacing: 6) {
                Text("Bands").font(.headline)
                InfoButton(title: "EQ Bands", markdown: bandsHelpText)
                Spacer()
                Button {
                    state.addBand()
                } label: {
                    Label("Add band", systemImage: "plus")
                }
                .glassButton()
                .controlSize(.regular)
                .disabled(state.profile.bands.count >= EQProfile.maxBands)
            }
            bandColumnHeaders
            ScrollView {
                VStack(spacing: 6) {
                    ForEach($state.profile.bands) { $band in
                        BandRow(band: $band) { state.removeBand(band) }
                    }
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    /// Column labels aligned with BandRow's fields.
    private var bandColumnHeaders: some View {
        HStack(spacing: 8) {
            Text("On").frame(width: 20, alignment: .leading)
            Text("Type").frame(width: 66, alignment: .leading)
            Text("Freq·Hz").frame(width: 62, alignment: .leading)
            Text("Q").frame(width: 50, alignment: .leading)
            Text("Gain · dB").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var profileRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Profile").font(.callout).foregroundStyle(.secondary)
                Text(state.profile.name).font(.callout).fontWeight(.semibold).lineLimit(1)
                Spacer()
                InfoButton(title: "Presets & AutoEq import", markdown: autoEqHelpText)
                presetMenu
            }
            if let message = state.lastImportMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(state.lastImportFailed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
        }
    }

    private var presetMenu: some View {
        Menu {
            Section("Built-in") {
                ForEach(SavedPreset.factory) { preset in
                    Button(preset.name) { state.applyPreset(preset) }
                }
            }
            if !state.userPresets.isEmpty {
                Section("My presets") {
                    ForEach(state.userPresets) { preset in
                        Button(preset.name) { state.applyPreset(preset) }
                    }
                }
            }
            Divider()
            Button("Save current…") { state.savePresetPrompt() }
            if !state.userPresets.isEmpty {
                Menu("Delete preset") {
                    ForEach(state.userPresets) { preset in
                        Button(preset.name, role: .destructive) { state.deletePreset(preset) }
                    }
                }
            }
            Divider()
            Menu("Import AutoEq") {
                Button("From clipboard") { state.importFromClipboard() }
                Button("Choose .txt file…") { state.importFromFile() }
            }
            Button("Reset to Flat") { state.resetToFlat() }
        } label: {
            Label("Presets", systemImage: "square.stack.3d.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Built-in presets, your saved presets, Save current…, and AutoEq import")
    }
}

/// One row of the band editor: enable, type, Fc, Q, gain slider, delete.
private struct BandRow: View {
    @Binding var band: EQBand
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $band.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .frame(width: 20, alignment: .leading)
                .help("Enable or bypass this band")

            Picker("", selection: $band.type) {
                ForEach(EQFilterType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .labelsHidden()
            .frame(width: 66)
            .help("Filter type — PK: peak/bell · LSC: low shelf · HSC: high shelf")

            TextField("Hz", value: $band.frequency, format: .number.precision(.fractionLength(0)))
                .modifier(NumberField(width: 54))
                .help("Center (PK) or corner (shelf) frequency, in Hz")

            TextField("Q", value: $band.q, format: .number.precision(.fractionLength(2)))
                .modifier(NumberField(enabled: band.type == .peaking, width: 42))
                .disabled(band.type != .peaking)
                .help(band.type == .peaking
                      ? "Q — bandwidth of the peak (higher = narrower)"
                      : "Q applies to Peak filters only")

            Slider(value: $band.gain, in: -15...15)
                .help("Gain — boost (+) or cut (−) in dB")

            Text(String(format: "%+.1f", band.gain))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            CircleIconButton(systemName: "minus", tint: .red, size: 24, dark: true,
                             help: "Remove this band") { onDelete() }
        }
        .opacity(band.isEnabled ? 1 : 0.5)
    }
}

/// A compact numeric entry field that matches the dark glass UI. The default
/// `.roundedBorder` style renders a bright/light bezel that clashes with the
/// dark theme, so we draw our own subtle dark chip instead. `enabled: false`
/// dims it (used for the Q field on shelf filters, where Q doesn't apply).
///
/// The system focus ring is drawn just outside the control's bounds, where the
/// chip's background/padding clips it — so it looked cut off. We suppress that
/// ring and instead light the chip's own border blue while the field is
/// focused, which reads clearly and never gets hidden.
private struct NumberField: ViewModifier {
    var enabled: Bool = true
    var width: CGFloat
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let field = content
            .textFieldStyle(.plain)
            .font(.callout.monospacedDigit())
            .multilineTextAlignment(.center)
            .focused($focused)
            .frame(width: width)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.white.opacity(focused ? 0.10 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(focused ? Color.accentColor : .white.opacity(0.12),
                              lineWidth: focused ? 2 : 1))
            .opacity(enabled ? 1 : 0.45)
            .animation(.easeInOut(duration: 0.12), value: focused)

        // Hide the clipped system focus ring where the API exists (macOS 14+);
        // the blue border above stands in for it on every version.
        return Group {
            if #available(macOS 14.0, *) { field.focusEffectDisabled() }
            else { field }
        }
    }
}

// MARK: - Effects help text

private let toneHelpText = """
Quick **Bass / Mids / Treble** tone shaping, layered on top of the correction profile:

• **Bass** — low shelf at 105 Hz
• **Mids** — wide bell at 1 kHz
• **Treble** — high shelf at 7.5 kHz

±12 dB each, with automatic headroom so boosts don't clip. **Flat** resets these three.
"""

private let bassHelpText = """
A dedicated **low-shelf bass boost**, separate from Tone → Bass so you can stack a deeper sub-bass lift.

• **Strength** — how much low end to add (0–12 dB).
• **Below** — corner frequency; everything under it is lifted.
"""

private let clarityHelpText = """
A **presence / brilliance exciter** (~4 kHz and up). Adds detail, air and sparkle to vocals and cymbals.

• **Amount** — strength of the lift. It stays clear of the low mids, so it brightens without muddying.
"""

private let tubeHelpText = """
Subtle **tube-style saturation** — gentle even-order harmonics for analog warmth. Output is level-matched, so it colours the tone without changing loudness.

• **Amount** — drive into the saturator.
"""

private let crossfeedHelpText = """
**Headphone crossfeed** — mixes a little of each channel into the other (like speakers heard in a room), relaxing the hard left/right split headphones exaggerate.

• **Feed** — cross level; **lower = stronger** blend.
• **Cutoff** — how much of the bass is blended.

4.5 dB / 700 Hz is the classic natural setting. Only meaningful on headphones.
"""

private let soundstageHelpText = """
Stereo-image controls:

• **Width** — 0 % = mono, 100 % = unchanged, 200 % = extra-wide (mid/side processing).
• **Balance** — shift the mix left (−) or right (+).
"""

private let reverbHelpText = """
Adds **room ambience** to everything.

• **Room** — the simulated space (small room → cathedral).
• **Mix** — wet/dry blend (how much reverb you hear).
"""

private let compressorHelpText = """
An **automatic-gain / compressor** that evens out loudness — tames peaks, lifts quiet parts.

• **Threshold** — level where compression starts.
• **Knee** — headroom above threshold (smaller = harder).
• **Attack / Release** — how fast it reacts and recovers.
• **Makeup** — gain added back afterwards.
"""

private let limiterHelpText = """
A **safety limiter** at the very end of the chain — catches peaks so nothing clips, no matter how much you boost elsewhere. Best left on.

• **Pre-gain** — drive into the limiter.
"""

// MARK: - Effects tab

private struct EffectsTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    toneBox
                    bassBox
                    clarityBox
                    tubeBox
                    crossfeedBox
                    soundstageBox
                    reverbBox
                    compressorBox
                    limiterBox
                }
                .padding(.trailing, 4)
            }
            .frame(maxHeight: .infinity)
            HStack {
                Spacer()
                Button("Reset all effects") {
                    state.resetTone()
                    state.resetEffects()
                }
                .glassButton()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private var toneBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Tone").font(.subheadline).fontWeight(.semibold)
                InfoButton(title: "Tone", markdown: toneHelpText)
                Spacer()
                Button("Flat") { state.resetTone() }
                    .controlSize(.small)
                    .disabled(state.tone.isFlat)
            }
            ParamSlider(label: "Bass", value: $state.tone.bass, range: -12...12, step: 0.5)
            ParamSlider(label: "Mids", value: $state.tone.mid, range: -12...12, step: 0.5)
            ParamSlider(label: "Treble", value: $state.tone.treble, range: -12...12, step: 0.5)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(14)
    }

    private var bassBox: some View {
        EffectBox(title: "Bass Boost", enabled: $state.effects.bass.enabled, info: bassHelpText) {
            ParamSlider(label: "Strength", value: $state.effects.bass.gainDB, range: 0...12, step: 0.5)
            ParamSlider(label: "Below", value: $state.effects.bass.frequency, range: 40...200, step: 5, format: "%.0f Hz")
        }
    }

    private var clarityBox: some View {
        EffectBox(title: "Clarity", enabled: $state.effects.clarity.enabled, info: clarityHelpText) {
            ParamSlider(label: "Amount", value: $state.effects.clarity.amount, range: 0...1, step: 0.05, format: "%.0f %%", scale: 100)
        }
    }

    private var tubeBox: some View {
        EffectBox(title: "Tube Warmth", enabled: $state.effects.tube.enabled, info: tubeHelpText) {
            ParamSlider(label: "Amount", value: $state.effects.tube.amount, range: 0...1, step: 0.05, format: "%.0f %%", scale: 100)
        }
    }

    private var crossfeedBox: some View {
        EffectBox(title: "Crossfeed", enabled: $state.effects.crossfeed.enabled, info: crossfeedHelpText) {
            ParamSlider(label: "Feed", value: $state.effects.crossfeed.feedDB, range: 2...8, step: 0.5)
            ParamSlider(label: "Cutoff", value: $state.effects.crossfeed.cutoffHz, range: 400...1200, step: 50, format: "%.0f Hz")
        }
    }

    private var soundstageBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Soundstage").font(.subheadline).fontWeight(.semibold)
                InfoButton(title: "Soundstage", markdown: soundstageHelpText)
                Spacer()
            }
            ParamSlider(label: "Width", value: $state.effects.widthPercent, range: 0...200, step: 5, format: "%.0f %%")
            ParamSlider(label: "Balance", value: $state.effects.balance, range: -1...1, step: 0.05, format: "%+.2f")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(14)
    }

    private var reverbBox: some View {
        EffectBox(title: "Reverb", enabled: $state.effects.reverb.enabled, info: reverbHelpText) {
            Picker("Room", selection: $state.effects.reverb.preset) {
                ForEach(EffectsSettings.reverbPresets, id: \.raw) { preset in
                    Text(preset.name).tag(preset.raw)
                }
            }
            .font(.caption)
            ParamSlider(label: "Mix", value: $state.effects.reverb.mix, range: 0...100, step: 1, format: "%.0f %%")
        }
    }

    private var compressorBox: some View {
        EffectBox(title: "Compressor / AGC", enabled: $state.effects.compressor.enabled, info: compressorHelpText) {
            ParamSlider(label: "Threshold", value: $state.effects.compressor.thresholdDB, range: -40...0, step: 1)
            ParamSlider(label: "Knee", value: $state.effects.compressor.headroomDB, range: 0.5...40, step: 0.5)
            ParamSlider(label: "Attack", value: $state.effects.compressor.attackMS, range: 0.1...200, step: 0.1, format: "%.1f ms")
            ParamSlider(label: "Release", value: $state.effects.compressor.releaseMS, range: 10...3000, step: 10, format: "%.0f ms")
            ParamSlider(label: "Makeup", value: $state.effects.compressor.makeupDB, range: 0...20, step: 0.5)
        }
    }

    private var limiterBox: some View {
        EffectBox(title: "Master Limiter", enabled: $state.effects.limiter.enabled, info: limiterHelpText) {
            ParamSlider(label: "Pre-gain", value: $state.effects.limiter.preGainDB, range: -10...10, step: 0.5)
        }
    }
}

// MARK: - Output tab

private struct OutputTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Output device").font(.subheadline).fontWeight(.semibold)
                    InfoButton(title: "Output device", markdown: outputDeviceHelpText)
                    Spacer()
                }
                Picker("", selection: Binding(
                    get: { state.selectedOutputUID ?? "" },
                    set: { state.selectedOutputUID = $0.isEmpty ? nil : $0 })) {
                    Text("Automatic").tag("")
                    ForEach(state.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(14)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Latency").font(.subheadline).fontWeight(.semibold)
                    InfoButton(title: "Latency", markdown: latencyHelpText)
                    Spacer()
                }
                Picker("", selection: $state.latency) {
                    ForEach(LatencyPreset.allCases) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if state.activeOutputName != nil {
                    Text(state.diagnosticsText)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(14)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Toggle(isOn: $state.matchLoudness) {
                        Text("Match system loudness").font(.subheadline).fontWeight(.semibold)
                    }
                    .toggleStyle(.switch)
                    InfoButton(title: "Match system loudness", markdown: matchLoudnessHelpText)
                    Spacer()
                }
                Text("Adds the EQ preamp back as limiter-protected output gain, so turning FrEQ on doesn't make things quieter.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(14)

            autoEnableCard

            Text("All system audio routes through the FrEQ virtual device while enabled. Toggling off restores your normal output instantly.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.top, 6)
    }

    private var autoEnableCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Auto-enable").font(.subheadline).fontWeight(.semibold)
                InfoButton(title: "Auto-enable rules", markdown: autoRuleHelpText)
                Spacer()
            }
            if state.outputDevices.isEmpty && state.disconnectedRules.isEmpty {
                Text("No output devices found.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(state.outputDevices) { device in
                Toggle(isOn: Binding(
                    get: { state.isAutoRuled(device.uid) },
                    set: { state.setAutoRule(for: device, on: $0) })) {
                    Text(device.name).font(.callout)
                }
                .toggleStyle(.checkbox)
            }
            ForEach(state.disconnectedRules) { rule in
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.square.fill").foregroundStyle(.secondary)
                    Text("\(rule.name)  —  disconnected")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        state.removeAutoRule(uid: rule.uid)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this rule")
                }
            }
            Text("FrEQ turns on automatically when a checked device connects, and off when it disconnects.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(14)
    }
}

private let autoRuleHelpText = """
Make FrEQ switch itself on/off based on which device is connected.

Check a device (e.g. your **Sony WH-1000XM4**) and:

• When it **connects**, FrEQ turns on and routes to it.
• When it **disconnects**, FrEQ turns off so your other outputs play normally.

Rules for devices that aren't currently connected are shown greyed — remove them with the ✕. You can still toggle FrEQ by hand at any time between connect/disconnect events.
"""

private let matchLoudnessHelpText = """
Correction profiles apply a negative **Preamp** so their boosts don't clip — which makes FrEQ quieter than the raw system audio.

With this on, that preamp is added back as **output gain into the master limiter**, so switching FrEQ on (or Processed ↔ Original) keeps roughly the **same loudness** as your system volume. The limiter cleanly catches any peaks the makeup pushes past 0 dB.

Turn it **off** for pristine, headroom-preserving output (quieter, but no limiting of boosted peaks). Either way, your volume keys still work normally.
"""

private let outputDeviceHelpText = """
Where FrEQ sends the processed audio — your headphones or speakers.

• **Automatic** — follows whatever you pick as the Mac's output (in Control Centre / System Settings). FrEQ adopts it and keeps applying EQ. Best for most people.
• **A specific device** — pins output to that device regardless of the system default.

Other virtual/loopback devices are hidden here, since routing into one would be silent.
"""

private let latencyHelpText = """
The trade-off between delay and stability.

• **Low** — least delay; best for video/gaming, but more sensitive to glitches.
• **Medium** — balanced (recommended).
• **High** — most robust against dropouts; a bit more delay.

Bluetooth already adds its own delay, so **Medium/High** are smoothest on wireless headphones. When active, live buffer stats show below.
"""
