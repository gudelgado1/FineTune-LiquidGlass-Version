// FineTune/Shortcuts/MediaTransportController.swift
import AppKit
import os

/// Sends media-transport commands (Play/Pause, Next, Previous) to a *specific*
/// app via AppleScript, so a global hotkey can drive a chosen player (Spotify,
/// Music, …) regardless of what's frontmost.
///
/// Why AppleScript and not the system media keys: posting `NX_KEYTYPE_PLAY` (etc.)
/// routes to whatever app macOS's Now-Playing arbiter currently favors — it can't
/// be aimed at a chosen app. `tell application id "…" to playpause` targets one app
/// deterministically. The trade-off is it only works for apps that implement the
/// standard media verbs (Spotify, Music, and most scriptable players) and triggers
/// the system **Automation** permission prompt the first time FineTune controls a
/// given app.
///
/// Why a spawned `osascript` and not in-process `NSAppleScript`: the in-process API
/// silently fails under Hardened Runtime without the
/// `com.apple.security.automation.apple-events` entitlement. Spawning the
/// `osascript` binary as a child process runs outside that restriction — the same
/// approach `DeviceVolumeMonitor.setAlertVolume` uses. `Process.run()` is just
/// fork+exec (non-blocking); the termination handler fires on a background thread.
@MainActor
final class MediaTransportController {
    enum Command {
        case playPause
        case nextTrack
        case previousTrack

        /// The AppleScript verb implemented by Spotify, Music, and the common
        /// scriptable-player Sdef.
        var appleScriptVerb: String {
            switch self {
            case .playPause: return "playpause"
            case .nextTrack: return "next track"
            case .previousTrack: return "previous track"
            }
        }
    }

    private let logger = Logger(subsystem: "com.finetuneapp.FineTune", category: "MediaTransport")

    /// Sends `command` to the app with the given bundle identifier. No-op on an
    /// empty bundle ID.
    func send(_ command: Command, toBundleID bundleID: String) {
        guard !bundleID.isEmpty else { return }

        // Bundle IDs are reverse-DNS (alphanumerics, dots, hyphens) — no quotes or
        // escapes — so interpolating into the `application id "…"` form is safe.
        let source = "tell application id \"\(bundleID)\" to \(command.appleScriptVerb)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        process.terminationHandler = { [weak self] proc in
            guard proc.terminationStatus != 0 else { return }
            Task { @MainActor [weak self] in
                self?.logger.warning(
                    "osascript exited \(proc.terminationStatus) sending \(command.appleScriptVerb) to \(bundleID) — app may not be scriptable or Automation was denied"
                )
            }
        }
        do {
            try process.run()
        } catch {
            logger.warning("Failed to launch osascript for media transport: \(error.localizedDescription)")
        }
    }
}
