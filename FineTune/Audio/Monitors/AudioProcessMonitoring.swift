@MainActor
protocol AudioProcessMonitoring: AnyObject {
    var activeApps: [AudioApp] { get }
    var onAppsChanged: (([AudioApp]) -> Void)? { get set }

    func start()
    func stop()

    /// Forces an immediate re-read of the audio process list, bypassing the
    /// periodic timer and the notification throttle. Used by the manual capture
    /// rebuild so it acts on what the HAL reports *now* — otherwise an app that
    /// is playing but missing from the last published list would be skipped by
    /// the very action meant to fix it.
    func refreshNow()
}

extension AudioProcessMonitoring {
    /// Test doubles publish `activeApps` directly and have nothing to re-read.
    func refreshNow() {}
}
