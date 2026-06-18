/// Abstraction over process tap controllers for testability.
///
/// **Threading:** Intentionally NOT `@MainActor`. Concrete implementations straddle
/// the main thread (property access from AudioEngine) and the CoreAudio HAL I/O thread
/// (audio processing callbacks). Thread safety for mutable properties (`volume`, `isMuted`,
/// `currentDeviceVolume`, `isDeviceMuted`) is achieved via `nonisolated(unsafe)` atomic
/// field access on the concrete type, not actor isolation.
protocol ProcessTapControlling: AnyObject {
    var app: AudioApp { get }
    var volume: Float { get set }
    var isMuted: Bool { get set }
    var currentDeviceVolume: Float { get set }
    var isDeviceMuted: Bool { get set }
    var audioLevel: Float { get }
    var currentDeviceUID: String? { get }
    var currentDeviceUIDs: [String] { get }

    func activate() throws
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

    /// True while the tap's underlying CoreAudio aggregate device is still alive
    /// server-side. Returns false when `coreaudiod` has destroyed the aggregate
    /// (restart under memory pressure, HAL reset, system overload) — the IO proc
    /// is dead and will never fire again, so the tap must be recreated. This is a
    /// *direct* resource-validity check, independent of callback timing, so it
    /// catches taps that died before ever rendering a buffer.
    var isResourceAlive: Bool { get }

    /// Temporarily bypasses the per-callback DSP stack (EQ / AutoEQ / loudness)
    /// to shed CPU under memory/CPU pressure, reducing the chance of an IO-thread
    /// overload while the system is thrashing. Re-enabled when pressure clears.
    func setDSPBypass(_ bypass: Bool)

    var tapSourceDeviceUID: String? { get }
    var renderDiagnostics: TapRenderDiagnostics { get }
    func refreshTapSource(_ preferredDeviceUID: String?) async throws
}

extension ProcessTapControlling {
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
    var isResourceAlive: Bool { true }

    /// Default no-op for mocks that don't override.
    func setDSPBypass(_ bypass: Bool) {}
}
