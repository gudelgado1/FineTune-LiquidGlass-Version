// FineTune/Utilities/DiagnosticLog.swift
import Foundation

/// Persistent file log for audio-resilience events.
///
/// The adhoc-signed Release build's `os_log` entries are NOT retained by the
/// unified log store (verified: `log show` returns zero lines for the process,
/// even with `--info --debug`), which made every "audio died while I was away"
/// report undiagnosable. This appends timestamped lines to
/// `~/Library/Logs/FineTune/Diagnostics.log` so a failure window can be
/// reconstructed after the fact.
///
/// Usage: `DiagnosticLog.log("health: recreating tap pid=123")`.
/// Writes are serialized on a utility queue — cheap for the caller, but still
/// NEVER call this from the real-time audio callback.
// Callers reach this from every isolation domain (engine, monitors, signal-adjacent
// teardown), so the whole type is nonisolated; `queue` provides the serialization.
nonisolated enum DiagnosticLog {
    private static let queue = DispatchQueue(label: "FineTune.DiagnosticLog", qos: .utility)
    /// Rotate at ~2 MB: current file becomes `.old` (replacing any previous one),
    /// so at most ~4 MB of history is kept.
    private static let maxBytes: UInt64 = 2_000_000

    private static let logDirectory: URL = {
        FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FineTune", isDirectory: true)
    }()
    private static let logFile = logDirectory.appendingPathComponent("Diagnostics.log")

    /// Touched only on `queue`, which serializes every use. `DateFormatter` is
    /// documented as thread-safe for formatting on modern OSes, but the queue is
    /// what this relies on — never format from anywhere else.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func log(_ message: String) {
        let now = Date()
        queue.async {
            let line = "\(formatter.string(from: now)) \(message)\n"
            append(line)
        }
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        do {
            if !fm.fileExists(atPath: logDirectory.path) {
                try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            }
            if !fm.fileExists(atPath: logFile.path) {
                fm.createFile(atPath: logFile.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: logFile)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            if size > maxBytes {
                try? handle.close()
                let old = logDirectory.appendingPathComponent("Diagnostics.old.log")
                try? fm.removeItem(at: old)
                try fm.moveItem(at: logFile, to: old)
                fm.createFile(atPath: logFile.path, contents: nil)
                let fresh = try FileHandle(forWritingTo: logFile)
                defer { try? fresh.close() }
                try fresh.write(contentsOf: Data(line.utf8))
                return
            }
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            // Diagnostics must never take the app down; drop the line.
        }
    }
}
