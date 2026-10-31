import SwiftUI
import Observation
import QuartzCore

/// Empirical fit to the user's native macOS recording from 2026-10-31.
/// These are reconstruction parameters, not documented Apple API constants.
enum HUDMotionProfile {
    static let entryDuration: TimeInterval = 0.55
    static let exitDuration: TimeInterval = 0.4
    static let reducedFadeDuration: TimeInterval = 0.08
    static let initialScale: CGFloat = 0.9
    static let levelDuration: TimeInterval = 0.15

    static func animation(appearing: Bool) -> Animation {
        appearing
            ? .timingCurve(0.26, 0, 0.145, 1, duration: entryDuration)
            : .timingCurve(0.19, 0, 0.325, 1, duration: exitDuration)
    }

    static func timingFunction(appearing: Bool) -> CAMediaTimingFunction {
        appearing
            ? CAMediaTimingFunction(controlPoints: 0.26, 0, 0.145, 1)
            : CAMediaTimingFunction(controlPoints: 0.19, 0, 0.325, 1)
    }
}

@Observable @MainActor
final class HUDMotionState {
    var progress: Double = 1
    // The native zoom originates at the menu-bar row, ten points above the pill.
    var anchor = UnitPoint(x: 0.5, y: 30.0 / 145.0)
    var scale: CGFloat { HUDMotionProfile.initialScale + (1 - HUDMotionProfile.initialScale) * CGFloat(max(0, min(1, progress))) }
}

struct HUDMotionRoot: View {
    let content: AnyView
    let state: HUDMotionState
    var reduceMotion = false

    var body: some View {
        content.scaleEffect(reduceMotion ? 1 : state.scale, anchor: state.anchor)
    }
}
