import Foundation

enum EQFilterType: String, Codable, CaseIterable, Identifiable {
    case peaking   = "PK"
    case lowShelf  = "LSC"
    case highShelf = "HSC"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .peaking:   return "Peak"
        case .lowShelf:  return "Low Shelf"
        case .highShelf: return "High Shelf"
        }
    }
}

struct EQBand: Codable, Identifiable, Hashable {
    var id = UUID()
    var type: EQFilterType = .peaking
    var frequency: Double = 1000   // Hz
    var gain: Double = 0           // dB
    var q: Double = 1.41
    var isEnabled: Bool = true
}

/// Simple tone controls layered on top of the correction profile — the
/// profile flattens the headphone, these adjust to taste.
struct ToneControls: Codable, Equatable {
    var bass: Double = 0     // dB, low shelf @ 105 Hz
    var mid: Double = 0      // dB, wide peak @ 1 kHz
    var treble: Double = 0   // dB, high shelf @ 7.5 kHz

    var isFlat: Bool { bass == 0 && mid == 0 && treble == 0 }
}

struct EQProfile: Codable, Equatable {
    /// AVAudioUnitEQ band count is fixed at node creation; 16 covers AutoEq's
    /// standard 10-band exports with headroom.
    static let maxBands = 16

    var name: String = "Flat"
    var preamp: Double = 0         // dB, applied via AVAudioUnitEQ.globalGain
    var bands: [EQBand] = []

    static func flat() -> EQProfile {
        let frequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        return EQProfile(name: "Flat", preamp: 0,
                         bands: frequencies.map { EQBand(frequency: $0, gain: 0, q: 1.41) })
    }
}
