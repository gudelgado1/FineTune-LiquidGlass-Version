// FineTune/Audio/Extensions/AudioDeviceID+Info.swift
import AudioToolbox
import Foundation

// MARK: - Device Information

extension AudioDeviceID {
    nonisolated func readDeviceName() throws -> String {
        try readString(kAudioObjectPropertyName)
    }

    nonisolated func readDeviceUID() throws -> String {
        try readString(kAudioDevicePropertyDeviceUID)
    }

    nonisolated func readNominalSampleRate() throws -> Float64 {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(48000))
    }

    nonisolated func readTransportType() -> TransportType {
        let raw = (try? read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
        return TransportType(rawValue: raw)
    }
}

// MARK: - Tap Properties

extension AudioObjectID {
    nonisolated func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }
}

// MARK: - Process Properties

extension AudioObjectID {
    nonisolated func readProcessPID() throws -> pid_t {
        try read(kAudioProcessPropertyPID, defaultValue: pid_t(0))
    }

    nonisolated func readProcessIsRunning() -> Bool {
        (try? readBool(kAudioProcessPropertyIsRunning)) ?? false
    }

    nonisolated func readProcessBundleID() -> String? {
        try? readString(kAudioProcessPropertyBundleID)
    }
}
