// FineTune/Audio/Engine/CrossfadeOrchestrator.swift
import AudioToolbox
import os

/// Error types for crossfade and tap operations
enum CrossfadeError: LocalizedError {
    case tapCreationFailed(OSStatus)
    case aggregateCreationFailed(OSStatus)
    case deviceNotReady
    case secondaryTapFailed
    case noTapDescription

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed(let status):
            return "Failed to create process tap: \(status)"
        case .aggregateCreationFailed(let status):
            return "Failed to create aggregate device: \(status)"
        case .deviceNotReady:
            return "Device not ready within timeout"
        case .secondaryTapFailed:
            return "Secondary tap invalid after timeout"
        case .noTapDescription:
            return "No tap description available"
        }
    }
}

/// Per-transport tuning for the crossfade. Different physical transports have
/// very different settle characteristics — wired devices respond in
/// microseconds, USB has a small DMA buffer settle, modern BT (AAC/AptX) takes
/// ~150 ms to stabilize, legacy BT can take 400+ ms.
///
/// Picking the right profile avoids two failure modes:
///   * Crossfade too short → audible click or partial silence on slow devices
///   * Crossfade too long → switches feel sluggish on fast devices
struct CrossfadeProfile: Sendable {
    /// Equal-power fade duration in seconds. Wall-clock time the secondary
    /// callback takes to ramp from 0→1 while primary ramps 1→0.
    let crossfadeDuration: TimeInterval
    /// Pre-crossfade warmup in milliseconds. Time to allow the secondary tap
    /// to deliver buffers before we start the audible mix.
    let warmupMs: Int
    /// Extra tolerance added to the crossfade timeout to absorb device jitter
    /// (e.g. BT codec negotiation, USB descriptor resets).
    let timeoutExtraMs: Int

    /// Wired and built-in outputs: feel essentially instantaneous.
    static let wired = CrossfadeProfile(
        crossfadeDuration: 0.025,  // 25 ms
        warmupMs: 25,
        timeoutExtraMs: 80
    )

    /// USB-class audio: tiny DMA settle but still robust at 35 ms.
    static let usb = CrossfadeProfile(
        crossfadeDuration: 0.035,  // 35 ms
        warmupMs: 35,
        timeoutExtraMs: 100
    )

    /// Modern Bluetooth (AirPods/AAC/AptX): ~150 ms link-layer settle, 75 ms
    /// crossfade so the equal-power fade can do its job.
    static let bluetoothModern = CrossfadeProfile(
        crossfadeDuration: 0.075,  // 75 ms
        warmupMs: 150,
        timeoutExtraMs: 200
    )

    /// Conservative fallback for unknown / legacy BT links (SBC, older
    /// devices, BLE audio). Same numbers as the prior global default.
    static let bluetoothLegacy = CrossfadeProfile(
        crossfadeDuration: 0.050,  // 50 ms
        warmupMs: 300,
        timeoutExtraMs: 400
    )

    /// Picks the appropriate profile from a `TransportType`.
    /// - Note: BLE Audio (LE Audio on iOS 17+/macOS 14+) is treated as modern;
    ///   if the user's device negotiates poorly the timeout still has headroom.
    static func profile(for transport: TransportType?) -> CrossfadeProfile {
        switch transport {
        case .builtIn, .hdmi, .displayPort, .thunderbolt:
            return .wired
        case .usb:
            return .usb
        case .bluetooth, .bluetoothLE:
            return .bluetoothModern
        case .airPlay:
            return .bluetoothLegacy  // wireless, larger jitter
        case .virtual, .aggregate, .unknown, .none:
            return .usb              // safe middle ground
        }
    }
}

/// Configuration for crossfade behavior during device switching.
/// The crossfade overlaps audio from old and new devices using equal-power curves
/// to maintain perceived loudness during the transition.
enum CrossfadeConfig {
    /// Legacy default — kept for code paths that don't yet plumb a profile.
    /// New code should use `CrossfadeProfile.profile(for:)`.
    static let defaultDuration: TimeInterval = 0.050  // 50ms

    /// User override via UserDefaults — when present, overrides ALL profile
    /// durations. Useful for QA/regression testing.
    static var duration: TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "FineTuneCrossfadeDuration")
        return custom > 0 ? custom : defaultDuration
    }

    /// Duration for a given profile, honoring the UserDefaults override.
    static func duration(for profile: CrossfadeProfile) -> TimeInterval {
        let custom = UserDefaults.standard.double(forKey: "FineTuneCrossfadeDuration")
        return custom > 0 ? custom : profile.crossfadeDuration
    }

    static func totalSamples(at sampleRate: Double) -> Int64 {
        max(1, Int64(sampleRate * duration))
    }

    static func totalSamples(at sampleRate: Double, for profile: CrossfadeProfile) -> Int64 {
        max(1, Int64(sampleRate * duration(for: profile)))
    }
}
