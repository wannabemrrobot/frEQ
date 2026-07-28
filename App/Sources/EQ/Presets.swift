import Foundation

/// An auto-enable rule: turn FrEQ on when this output device connects, and
/// off when it disconnects. `name` is kept for display while the device is
/// absent.
struct AutoRule: Codable, Equatable, Identifiable {
    var uid: String
    var name: String
    var id: String { uid }
}

/// A saved snapshot of the whole sound: the EQ profile plus tone and effects.
/// Built-in presets ship with the app; user presets are saved to UserDefaults.
struct SavedPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var builtIn = false
    var profile: EQProfile
    var tone = ToneControls()
    var effects = EffectsSettings()
}

extension SavedPreset {
    /// Standard 10-band graphic-EQ frequencies used by the built-in presets.
    private static let bandFrequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    /// Build an EQ-only built-in preset from per-band gains (dB).
    private static func eq(_ name: String, preamp: Double, _ gains: [Double]) -> SavedPreset {
        let bands = zip(bandFrequencies, gains).map {
            EQBand(type: .peaking, frequency: $0.0, gain: $0.1, q: 1.41)
        }
        return SavedPreset(name: name, builtIn: true,
                           profile: EQProfile(name: name, preamp: preamp, bands: bands))
    }

    /// Ready-made curves so the app is useful as a generic EQ without AutoEq.
    /// Preamp is set negative to leave headroom for the boosts.
    static let factory: [SavedPreset] = [
        eq("Flat",         preamp:  0, [ 0,  0,  0,  0,  0,  0,  0,  0,  0,  0]),
        eq("Bass Boost",   preamp: -6, [ 6,  5,  4,  2,  0,  0,  0,  0,  0,  0]),
        eq("Treble Boost", preamp: -6, [ 0,  0,  0,  0,  0,  0,  2,  3,  5,  6]),
        eq("V-Shaped",     preamp: -6, [ 5,  4,  2,  0, -2, -2,  0,  2,  4,  5]),
        eq("Vocal Boost",  preamp: -4, [-3, -2,  0,  1,  2,  3,  3,  2,  1,  0]),
        eq("Loudness",     preamp: -7, [ 6,  5,  3,  0, -1, -1,  0,  2,  4,  5]),
        eq("Podcast",      preamp: -3, [-6, -4, -1,  1,  2,  3,  3,  1,  0, -1]),
    ]
}
