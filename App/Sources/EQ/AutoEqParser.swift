import Foundation

/// Parses AutoEq's "ParametricEQ" text export, e.g.:
///
///     Preamp: -6.7 dB
///     Filter 1: ON PK Fc 105 Hz Gain 4.6 dB Q 0.70
///     Filter 2: ON LSC Fc 105 Hz Gain 5.2 dB Q 0.70
///     Filter 3: ON HSC Fc 10000 Hz Gain -1.9 dB Q 0.70
///
/// Filters marked OFF are skipped. Legacy type spellings LS/HS are accepted.
/// Lines that match neither pattern are ignored so headers or comments in a
/// pasted file do not break the import.
enum AutoEqParser {

    enum ParseError: LocalizedError, Equatable {
        case noFilters

        var errorDescription: String? {
            switch self {
            case .noFilters:
                return "No parametric EQ filters found. Expected AutoEq's ParametricEQ format (lines like \"Filter 1: ON PK Fc 105 Hz Gain 4.6 dB Q 0.70\")."
            }
        }
    }

    private static let preampRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*preamp:\s*(-?\d+(?:\.\d+)?)\s*db"#)

    // Filter N: ON|OFF TYPE Fc X Hz Gain Y dB [Q Z]
    private static let filterRegex = try! NSRegularExpression(
        pattern: #"(?i)^\s*filter\s*\d*\s*:\s*(ON|OFF)\s+(PK|LSC|LS|HSC|HS)\s+Fc\s+(\d+(?:\.\d+)?)\s*Hz\s+Gain\s+(-?\d+(?:\.\d+)?)\s*dB(?:\s+Q\s+(\d+(?:\.\d+)?))?"#)

    static func parse(_ text: String, name: String = "Imported profile") throws -> EQProfile {
        var preamp = 0.0
        var bands: [EQBand] = []
        var sawFilterLine = false

        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..., in: line)

            if let match = preampRegex.firstMatch(in: line, range: range),
               let value = Double(substring(line, match.range(at: 1))) {
                preamp = value
                continue
            }

            guard let match = filterRegex.firstMatch(in: line, range: range) else { continue }
            sawFilterLine = true

            let state = substring(line, match.range(at: 1)).uppercased()
            guard state == "ON" else { continue }

            let typeToken = substring(line, match.range(at: 2)).uppercased()
            let type: EQFilterType
            switch typeToken {
            case "PK":        type = .peaking
            case "LSC", "LS": type = .lowShelf
            case "HSC", "HS": type = .highShelf
            default:          continue
            }

            guard let frequency = Double(substring(line, match.range(at: 3))),
                  let gain = Double(substring(line, match.range(at: 4))) else { continue }

            // AutoEq omits Q on some shelf exports; 0.707 is its default.
            var q = 0.707
            if match.range(at: 5).location != NSNotFound,
               let parsedQ = Double(substring(line, match.range(at: 5))), parsedQ > 0 {
                q = parsedQ
            }

            bands.append(EQBand(type: type, frequency: frequency, gain: gain, q: q))
        }

        guard sawFilterLine, !bands.isEmpty else { throw ParseError.noFilters }
        return EQProfile(name: name, preamp: preamp, bands: bands)
    }

    private static func substring(_ line: String, _ nsRange: NSRange) -> String {
        guard let range = Range(nsRange, in: line) else { return "" }
        return String(line[range])
    }
}
