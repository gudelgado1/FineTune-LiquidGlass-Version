import AudioToolbox
import Foundation

/// The clock used to configure the current render pipeline. Read on the control
/// thread; the wake worker receives this value, never a live tap controller.
nonisolated struct TapRenderClock: Equatable, Sendable {
    let aggregateDeviceID: AudioDeviceID
    let sampleRate: Double
}

/// Abstraction over process tap controllers for testability.
///
/// **Threading:** Intentionally NOT `@MainActor`. Concrete implementations straddle
/// the main thread (property access from AudioEngine) and the CoreAudio HAL I/O thread
/// (audio processing callbacks). Concrete implementations must synchronize shared
/// state; `nonisolated(unsafe)` alone does not provide atomic access or ownership.
protocol ProcessTapControlling: AnyObject {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }
    var renderClock: TapRenderClock? { get }

    func activate() throws
    func activate(initialDSP: TapDSPConfiguration) throws
    func invalidate()
    func invalidateAsync() async
    func updateEQSettings(_ settings: EQSettings)
    func updateAutoEQProfile(_ profile: AutoEQProfile?)
    func setAutoEQPreampEnabled(_ enabled: Bool)
    func updateLoudnessCompensation(volume: Float, enabled: Bool)
    func updateLoudnessEqualization(_ settings: LoudnessEqualizerSettings)
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?, sourceDeviceDead: Bool) async throws
    func hasRecentAudioCallback(within seconds: Double) -> Bool
    func isHealthCheckEligible(minActiveSeconds: Double) -> Bool

    /// Reads aggregate validity off control with a deadline. false means the
    /// resource is definitively gone, true means no definitive death (including
    /// transient HAL errors), nil means the read timed out or was not admitted.
    /// Catches taps killed before their first callback too.
    func checkResourceLiveness(timeout: TimeInterval) async -> Bool?

    /// Temporarily bypasses the per-callback DSP stack (EQ / AutoEQ / loudness)
    /// to shed CPU under memory/CPU pressure, reducing the chance of an IO-thread
    /// overload while the system is thrashing. Re-enabled when pressure clears.
    func setDSPBypass(_ bypass: Bool)

    var tapSourceDeviceUID: String? { get }
    var renderDiagnostics: TapRenderDiagnostics { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws
}

extension ProcessTapControlling {
    /// Compatibility path for adapters/mocks. Native taps build processors from
    /// this state before registering/starting their IO proc.
    func activate(initialDSP: TapDSPConfiguration) throws {
        updateEQSettings(initialDSP.eq)
        setAutoEQPreampEnabled(initialDSP.autoEQPreampEnabled)
        updateAutoEQProfile(initialDSP.autoEQProfile)
        updateLoudnessEqualization(initialDSP.loudnessEqualization)
        updateLoudnessCompensation(volume: initialDSP.loudnessVolume, enabled: initialDSP.loudnessCompensationEnabled)
        setDSPBypass(initialDSP.bypass)
        try activate()
    }

    var renderClock: TapRenderClock? { nil }

    /// Convenience: defaults sourceDeviceDead to false.
    func switchDevice(to newDeviceUID: String, preferredTapSourceDeviceUID: String?) async throws {
        try await switchDevice(to: newDeviceUID, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    /// Convenience: defaults sourceDeviceDead to false.
    func updateDevices(to newDeviceUIDs: [String], preferredTapSourceDeviceUID: String?) async throws {
        try await updateDevices(to: newDeviceUIDs, preferredTapSourceDeviceUID: preferredTapSourceDeviceUID, sourceDeviceDead: false)
    }

    func invalidateAsync() async {
        invalidate()
    }

    func refreshTapSource(_ preferredDeviceUID: String?) async throws {
        // Default no-op for mocks that don't override
    }

    var renderDiagnostics: TapRenderDiagnostics {
        TapRenderDiagnostics()
    }

    /// Mocks are assumed alive unless they override this.
    func checkResourceLiveness(timeout: TimeInterval) async -> Bool? { true }

    /// Default no-op for mocks that don't override.
    func setDSPBypass(_ bypass: Bool) {}
}
