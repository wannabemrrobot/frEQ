// Standalone test harness for AutoEqParser + EQProfile.
// Run via scripts/run-tests.sh (no XCTest — Command Line Tools only).

import Foundation

@main
enum ParserTests {
    static func main() {

    var failures = 0

    func expect(_ condition: Bool, _ message: String) {
        if condition {
            print("  ok: \(message)")
        } else {
            print("  FAIL: \(message)")
            failures += 1
        }
    }

    func expectClose(_ a: Double, _ b: Double, _ message: String) {
        expect(abs(a - b) < 1e-9, "\(message) (got \(a), want \(b))")
    }

    // MARK: 1. Spec example

    print("case: spec example")
    let specText = """
    Preamp: -6.7 dB
    Filter 1: ON PK Fc 105 Hz Gain 4.6 dB Q 0.70
    Filter 2: ON LSC Fc 105 Hz Gain 5.2 dB Q 0.70
    Filter 3: ON HSC Fc 10000 Hz Gain -1.9 dB Q 0.70
    """
    do {
        let profile = try AutoEqParser.parse(specText, name: "Spec")
        expectClose(profile.preamp, -6.7, "preamp")
        expect(profile.bands.count == 3, "band count == 3")
        expect(profile.bands[0].type == .peaking, "band 1 is PK")
        expectClose(profile.bands[0].frequency, 105, "band 1 Fc")
        expectClose(profile.bands[0].gain, 4.6, "band 1 gain")
        expectClose(profile.bands[0].q, 0.70, "band 1 Q")
        expect(profile.bands[1].type == .lowShelf, "band 2 is LSC")
        expect(profile.bands[2].type == .highShelf, "band 3 is HSC")
        expectClose(profile.bands[2].gain, -1.9, "band 3 negative gain")
    } catch {
        expect(false, "spec example parses (\(error))")
    }

    // MARK: 2. Real AutoEq export shape (WH-1000XM4-style, 10 bands, CRLF)

    print("case: 10-band export with CRLF line endings")
    let xm4Text = [
        "Preamp: -5.8 dB",
        "Filter 1: ON LSC Fc 105 Hz Gain 5.2 dB Q 0.70",
        "Filter 2: ON PK Fc 236 Hz Gain -4.9 dB Q 1.05",
        "Filter 3: ON PK Fc 1108 Hz Gain 1.3 dB Q 1.98",
        "Filter 4: ON PK Fc 2404 Hz Gain 3.6 dB Q 2.16",
        "Filter 5: ON PK Fc 4382 Hz Gain -4.9 dB Q 3.32",
        "Filter 6: ON PK Fc 65 Hz Gain -2.5 dB Q 0.61",
        "Filter 7: ON PK Fc 5745 Hz Gain 3.05 dB Q 5.45",
        "Filter 8: ON PK Fc 8283 Hz Gain -3.0 dB Q 3.29",
        "Filter 9: ON PK Fc 641 Hz Gain 1.1 dB Q 2.02",
        "Filter 10: ON HSC Fc 10000 Hz Gain -3.1 dB Q 0.70",
    ].joined(separator: "\r\n")
    do {
        let profile = try AutoEqParser.parse(xm4Text, name: "WH-1000XM4")
        expect(profile.bands.count == 10, "band count == 10")
        expectClose(profile.preamp, -5.8, "preamp")
        expectClose(profile.bands[6].gain, 3.05, "fractional gain parses")
        expectClose(profile.bands[9].frequency, 10000, "Fc 10000")
    } catch {
        expect(false, "10-band export parses (\(error))")
    }

    // MARK: 3. OFF filters and junk lines are skipped

    print("case: OFF filters, junk lines, legacy LS/HS, missing Q")
    let mixedText = """
    Sony WH-1000XM4 — AutoEq (some header text)

    Preamp: -4.0 dB
    Filter 1: OFF PK Fc 100 Hz Gain 10.0 dB Q 1.00
    Filter 2: ON LS Fc 105 Hz Gain 2.0 dB
    Filter 3: ON HS Fc 9000 Hz Gain -1.0 dB
    random garbage line
    Filter 4: ON PK Fc 1000 Hz Gain 1.0 dB Q 2.50
    """
    do {
        let profile = try AutoEqParser.parse(mixedText, name: "Mixed")
        expect(profile.bands.count == 3, "OFF filter skipped, 3 remain")
        expect(profile.bands[0].type == .lowShelf, "legacy LS accepted")
        expectClose(profile.bands[0].q, 0.707, "missing Q defaults to 0.707")
        expect(profile.bands[1].type == .highShelf, "legacy HS accepted")
        expectClose(profile.bands[2].q, 2.5, "explicit Q kept")
    } catch {
        expect(false, "mixed input parses (\(error))")
    }

    // MARK: 4. Garbage input errors out

    print("case: garbage input")
    do {
        _ = try AutoEqParser.parse("this is not a profile\nat all", name: "junk")
        expect(false, "garbage should throw")
    } catch {
        expect(error is AutoEqParser.ParseError, "throws ParseError")
    }

    // MARK: 5. Codable round-trip (persistence path)

    print("case: profile Codable round-trip")
    do {
        let original = try AutoEqParser.parse(specText, name: "RT")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EQProfile.self, from: data)
        expect(decoded == original, "round-trip equality")
    } catch {
        expect(false, "round-trip (\(error))")
    }

    if failures > 0 {
        print("\n\(failures) FAILURE(S)")
        exit(1)
    }
    print("\nall parser tests passed")

    }
}
