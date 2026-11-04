// FineTune/Views/Settings/Components/CaptureRebuildRow.swift
import SwiftUI

/// Settings row that recreates FineTune's per-app audio capture.
///
/// The light-touch counterpart to the Core Audio reset: when one app's volume
/// stops responding, or an app that is playing never shows up, rebuilding the
/// taps usually fixes it — with no password prompt and without interrupting
/// audio for the rest of the system.
@MainActor
struct CaptureRebuildRow: View {
    let audioEngine: AudioEngine

    @State private var isRebuilding = false
    @State private var lastOutcome: Outcome?

    private enum Outcome: Equatable {
        case rebuilt(Int)
        /// Refused because the audio system itself isn't answering.
        case audioSystemDown
    }

    private var audioSystemResponsive: Bool {
        audioEngine.audioSystemHealth.allowsPeriodicHALWork
    }

    var body: some View {
        SettingsRow(
            "App Capture",
            description: statusDescription,
            systemImage: "arrow.clockwise.circle"
        ) {
            HStack(spacing: 10) {
                if isRebuilding {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Rebuild") {
                    Task { await rebuild() }
                }
                .controlSize(.regular)
                .disabled(isRebuilding || !audioSystemResponsive)
            }
        }
    }

    private func rebuild() async {
        isRebuilding = true
        lastOutcome = nil
        let count = await audioEngine.rebuildAllTaps()
        isRebuilding = false
        lastOutcome = count.map { Outcome.rebuilt($0) } ?? .audioSystemDown
    }

    private var statusDescription: String {
        if isRebuilding {
            return "Rebuilding capture for your apps…"
        }
        guard audioSystemResponsive else {
            return "Audio system isn't responding — reset Core Audio first."
        }
        switch lastOutcome {
        case .rebuilt(let count):
            return count == 1
                ? "Rebuilt capture for 1 app."
                : "Rebuilt capture for \(count) apps."
        case .audioSystemDown:
            return "Couldn't rebuild — the audio system stopped responding."
        case nil:
            return "Recreate per-app capture. Try this first if an app's volume stops working or it's missing from the list."
        }
    }
}
