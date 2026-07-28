import Foundation

/// Plain-file diagnostic log at a fixed, world-readable path so it can be read
/// with `cat` regardless of `log show` permissions. Always on; cheap; writes
/// on a background queue. Read with:  cat /tmp/freq-debug.log
enum DebugLog {
    static let path = "/tmp/freq-debug.log"
    /// Off by default; enable by launching with FREQ_DEBUG=1 in the
    /// environment. Keeps the shared release quiet while leaving the
    /// instrumentation one env var away for future troubleshooting.
    static let enabled = ProcessInfo.processInfo.environment["FREQ_DEBUG"] == "1"
    private static let queue = DispatchQueue(label: "com.freq.debuglog")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Truncate at launch so each session starts clean.
    static func reset() {
        guard enabled else { return }
        queue.async {
            let header = "=== FrEQ session started \(formatter.string(from: Date())) ===\n"
            try? header.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    static func log(_ message: String) {
        guard enabled else { return }
        let stamped = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            guard let data = stamped.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? stamped.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }
}
