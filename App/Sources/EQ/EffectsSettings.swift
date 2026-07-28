import Foundation

/// The ViPER4FX-style effects rack. Enhancers/spatial effects run in the
/// custom C DSP core (AEDSP); reverb, compressor and limiter are Apple
/// effect AudioUnits downstream of the EQ stages.
struct EffectsSettings: Codable, Equatable {

    struct BassBoost: Codable, Equatable {
        var enabled = false
        var gainDB: Double = 5        // 0 … +12
        var frequency: Double = 80    // 40 … 200 Hz
    }

    struct Tube: Codable, Equatable {
        var enabled = false
        var amount: Double = 0.3      // 0 … 1
    }

    struct Clarity: Codable, Equatable {
        var enabled = false
        var amount: Double = 0.3      // 0 … 1
    }

    struct Crossfeed: Codable, Equatable {
        var enabled = false
        var feedDB: Double = 4.5      // 2 … 8 (lower = stronger cross signal)
        var cutoffHz: Double = 700    // 400 … 1200
    }

    struct Reverb: Codable, Equatable {
        var enabled = false
        /// AVAudioUnitReverbPreset raw value.
        var preset: Int = 1           // .mediumRoom
        var mix: Double = 12          // wet/dry percent 0 … 100
    }

    struct Compressor: Codable, Equatable {
        var enabled = false
        var thresholdDB: Double = -20 // -40 … 0
        var headroomDB: Double = 5    // 0.1 … 40 (smaller = harder ratio)
        var attackMS: Double = 5      // 0.1 … 200
        var releaseMS: Double = 100   // 10 … 3000
        var makeupDB: Double = 0      // 0 … 20
    }

    struct Limiter: Codable, Equatable {
        var enabled = true            // safety net: on by default
        var preGainDB: Double = 0     // -10 … +10
    }

    var bass = BassBoost()
    var tube = Tube()
    var clarity = Clarity()
    var crossfeed = Crossfeed()
    var widthPercent: Double = 100    // 0 … 200 (100 = unchanged)
    var balance: Double = 0           // -1 … +1
    var reverb = Reverb()
    var compressor = Compressor()
    var limiter = Limiter()

    static let reverbPresets: [(name: String, raw: Int)] = [
        ("Small Room", 0), ("Medium Room", 1), ("Large Room", 2),
        ("Medium Hall", 3), ("Large Hall", 4), ("Plate", 5),
        ("Medium Chamber", 6), ("Large Chamber", 7), ("Cathedral", 8),
    ]
}
