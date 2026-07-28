import Accelerate
import Foundation

/// Real-time spectrum analyzer: turns a stream of mono samples into a set of
/// log-spaced frequency-band magnitudes (0…1) for the UI spectrum display.
///
/// Fed from one audio thread per instance (no cross-instance sharing). All
/// scratch is preallocated so `process` never allocates or locks on the audio
/// thread. `smoothed` is a raw pointer so the UI can snapshot it without
/// triggering an Array copy-on-write allocation back on the audio thread; the
/// resulting read is a benign race, which a visual meter tolerates.
final class AESpectrum {
    let bandCount: Int
    private let n = 1024
    private let fs: Double
    private let log2n: vDSP_Length
    private let setup: FFTSetup

    private var window: [Float]
    private var frame: [Float]        // most-recent n samples
    private var haveSamples = 0
    private var windowed: [Float]
    private var realp: [Float]
    private var imagp: [Float]
    private var mags: [Float]
    private var bandLo: [Int]
    private var bandHi: [Int]
    private let smoothed: UnsafeMutablePointer<Float>
    private let peaks: UnsafeMutablePointer<Float>   // slow-falling peak-hold

    init(bandCount: Int, sampleRate: Double) {
        self.bandCount = bandCount
        self.fs = sampleRate
        log2n = vDSP_Length(log2(Double(n)))
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!

        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        frame = [Float](repeating: 0, count: n)
        windowed = [Float](repeating: 0, count: n)
        realp = [Float](repeating: 0, count: n / 2)
        imagp = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
        smoothed = .allocate(capacity: bandCount)
        smoothed.initialize(repeating: 0, count: bandCount)
        peaks = .allocate(capacity: bandCount)
        peaks.initialize(repeating: 0, count: bandCount)

        // Log-spaced band edges, ~30 Hz … 16 kHz.
        bandLo = [Int](repeating: 0, count: bandCount)
        bandHi = [Int](repeating: 0, count: bandCount)
        let fLow = 30.0
        let fHigh = min(16000.0, sampleRate / 2 - 1)
        let binHz = sampleRate / Double(n)
        for b in 0..<bandCount {
            let f0 = fLow * pow(fHigh / fLow, Double(b) / Double(bandCount))
            let f1 = fLow * pow(fHigh / fLow, Double(b + 1) / Double(bandCount))
            let lo = max(1, Int(f0 / binHz))
            bandLo[b] = min(lo, n / 2 - 1)
            bandHi[b] = max(bandLo[b], min(n / 2 - 1, Int(f1 / binHz)))
        }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        smoothed.deallocate()
        peaks.deallocate()
    }

    /// Append mono samples and recompute the band magnitudes. RT-safe.
    func process(_ x: UnsafePointer<Float>, _ count: Int) {
        guard count > 0 else { return }
        // Keep the last n samples in `frame`.
        frame.withUnsafeMutableBufferPointer { fb in
            let f = fb.baseAddress!
            if count >= n {
                memcpy(f, x + (count - n), n * MemoryLayout<Float>.size)
            } else {
                memmove(f, f + count, (n - count) * MemoryLayout<Float>.size)
                memcpy(f + (n - count), x, count * MemoryLayout<Float>.size)
            }
        }
        haveSamples = min(haveSamples + count, n)
        guard haveSamples >= n else { return }

        vDSP_vmul(frame, 1, window, 1, &windowed, 1, vDSP_Length(n))

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wb in
                    wb.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { cp in
                        vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &mags, 1, vDSP_Length(n / 2))
            }
        }

        // Time-based smoothing so the response is identical regardless of how
        // many frames arrive per call (IN gets ~512-frame chunks, the OUT tap
        // ~1024) — otherwise OUT would fall at half speed and look sluggish /
        // stuck at peak.
        let dt = Float(count) / Float(fs)
        let atk = 1 - exp(-dt / 0.020)     // ~20 ms rise
        let dec = 1 - exp(-dt / 0.220)     // ~220 ms fall
        let peakFall = 0.6 * dt            // peak caps fall ~0.6 / s

        for b in 0..<bandCount {
            let lo = bandLo[b], hi = bandHi[b]
            var sum: Float = 0
            for bin in lo...hi { sum += mags[bin] }
            let avg = sum / Float(hi - lo + 1)
            let db = 20 * log10(max(avg, 1e-6) / Float(n))
            var norm = (db + 68) / 68          // ~ −68…0 dB → 0…1
            norm = min(1, max(0, norm))
            let prev = smoothed[b]
            let coeff: Float = norm > prev ? atk : dec
            let sv = prev + (norm - prev) * coeff
            smoothed[b] = sv
            peaks[b] = sv > peaks[b] ? sv : max(0, peaks[b] - peakFall)
        }
    }

    /// Snapshot of the current band magnitudes (0…1) for the UI.
    func snapshot() -> [Float] {
        [Float](unsafeUninitializedCapacity: bandCount) { buf, cnt in
            for i in 0..<bandCount { buf[i] = smoothed[i] }
            cnt = bandCount
        }
    }

    /// Snapshot of the slow-falling peak-hold values.
    func peaksSnapshot() -> [Float] {
        [Float](unsafeUninitializedCapacity: bandCount) { buf, cnt in
            for i in 0..<bandCount { buf[i] = peaks[i] }
            cnt = bandCount
        }
    }
}
