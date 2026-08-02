// FineTune/Views/Settings/Components/CoreAudioResetRow.swift
import SwiftUI

/// Settings row that reports whether Core Audio is answering and offers a
/// one-click restart of the daemon.
///
/// `coreaudiod` can wedge — alive but answering nobody — which makes every
/// audio device vanish system-wide. Recovering needs a privileged restart, so
/// this row replaces "open Terminal and type `sudo killall coreaudiod`".
@MainActor
struct CoreAudioResetRow: View {
    @Bindable var service: CoreAudioResetService
    let audioEngine: AudioEngine

    @State private var showConfirmation = false

    var body: some View {
        SettingsRow(
            "Core Audio",
            description: statusDescription,
            systemImage: statusIcon
        ) {
            HStack(spacing: 10) {
                if service.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.opacity)
                }
                Button("Reset") {
                    showConfirmation = true
                }
                .controlSize(.regular)
                .disabled(service.isBusy)
            }
        }
        .task {
            // Safe on a wedged daemon: the probe runs on its own thread and this
            // view only waits on a deadline.
            await service.checkHealth()
        }
        .onChange(of: audioEngine.audioSystemHealth.state) { _, newState in
            // The engine's breaker trips from background HAL timeouts; mirror it
            // so an open Settings window shows the outage without a manual check.
            if newState == .unresponsive {
                service.noteUnresponsiveFromEngine()
            }
        }
        .confirmationDialog(
            "Restart Core Audio?",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restart Core Audio", role: .destructive) {
                Task { await service.resetCoreAudio(engine: audioEngine) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Audio stops for a moment on every app, then comes back. macOS will ask for your password. Some apps that were playing may need to be restarted.")
        }
    }

    // MARK: - Status presentation

    private var statusDescription: String {
        switch service.phase {
        case .checking:
            return "Checking if the audio system responds…"
        case .restarting:
            return "Waiting for authorization…"
        case .waitingForDaemon:
            return "Restarting the audio system…"
        case .rebuilding:
            return "Rebuilding audio for your apps…"
        case .succeeded:
            return "Audio system restarted successfully."
        case .cancelled:
            return "Restart cancelled."
        case .failed(let message):
            return "Restart failed: \(message)"
        case .idle:
            switch service.health {
            case .responsive:
                return "Responding normally. Reset if audio stops or devices disappear."
            case .unresponsive:
                return "Not responding — devices are unavailable. A reset should fix it."
            case .unknown:
                return "Restart the macOS audio system if devices disappear or audio stops."
            }
        }
    }

    private var statusIcon: String {
        switch service.phase {
        case .succeeded:
            return "checkmark.circle"
        case .failed:
            return "exclamationmark.triangle"
        default:
            switch service.health {
            case .responsive: return "waveform.circle"
            case .unresponsive: return "exclamationmark.triangle"
            case .unknown: return "waveform.circle"
            }
        }
    }
}
