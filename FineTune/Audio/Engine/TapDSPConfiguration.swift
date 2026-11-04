import Foundation

/// Complete control-side configuration captured before a new tap starts IO.
/// A missing AutoEQ profile means correction is unavailable; a later successful
/// fetch can replace it, while local EQ/loudness and gain are ready at startup.
struct TapDSPConfiguration {
    var eq: EQSettings = .flat
    var autoEQProfile: AutoEQProfile?
    var autoEQPreampEnabled = true
    var loudnessEqualization = LoudnessEqualizerSettings()
    var loudnessVolume: Float = 1
    var loudnessCompensationEnabled = false
    var bypass = false

    func makeProcessors(sampleRate: Double) -> TapDSPProcessors {
        let eqProcessor = EQProcessor(sampleRate: sampleRate)
        eqProcessor.updateSettings(eq)
        let autoEQ = AutoEQProcessor(sampleRate: sampleRate)
        autoEQ.setPreampEnabled(autoEQPreampEnabled)
        autoEQ.updateProfile(autoEQProfile)
        let compensator = LoudnessCompensator(sampleRate: sampleRate)
        if loudnessCompensationEnabled { compensator.updateForVolume(loudnessVolume) }
        return TapDSPProcessors(
            eq: eqProcessor, autoEQ: autoEQ,
            equalizer: LoudnessEqualizer(settings: loudnessEqualization, sampleRate: Float(sampleRate)),
            compensator: compensator
        )
    }
}

struct TapDSPProcessors {
    let eq: EQProcessor
    let autoEQ: AutoEQProcessor
    let equalizer: LoudnessEqualizer
    let compensator: LoudnessCompensator
}
