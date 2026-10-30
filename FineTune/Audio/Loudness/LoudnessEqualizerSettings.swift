// Leveler defaults tuned upstream (ronitsingh10/FineTune #304) to stop audible
// volume pumping. The long analysis window/hop align the detector with BS.1770
// momentary loudness metering; the pumping itself is cured by the slower gain
// release. Lower max boost and a higher noise floor keep quiet passages from
// being dragged up.
nonisolated struct LoudnessEqualizerSettings: Codable, Equatable, Sendable {
    var targetLoudnessDb: Float = -12
    var maxBoostDb: Float = 6
    var maxCutDb: Float = 4
    var compressionThresholdOffsetDb: Float = 6
    var compressionRatio: Float = 1.6
    var compressionKneeDb: Float = 8

    var analysisWindowMs: Float = 400
    var analysisHopMs: Float = 100

    var detectorAttackMs: Float = 25
    var detectorReleaseMs: Float = 600

    var gainAttackMs: Float = 250
    var gainReleaseMs: Float = 3000

    var noiseFloorThresholdDb: Float = -40
    var lowLevelMaxBoostDb: Float = 0.5

    var enabled: Bool = false
}
