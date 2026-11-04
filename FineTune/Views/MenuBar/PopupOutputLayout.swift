import Foundation

/// Visible output rows for the compact home screen. A missing default is a
/// device-change state: expose every available choice instead of guessing one.
struct PopupOutputLayout {
    let active: AudioDevice?
    let alternatives: [AudioDevice]

    init(devices: [AudioDevice], defaultUID: String?) {
        let resolved = defaultUID.flatMap { uid in devices.first { $0.uid == uid } }
        active = resolved
        alternatives = devices.filter { $0.uid != resolved?.uid }
    }

    func visibleDevices(showingAlternatives: Bool) -> [AudioDevice] {
        guard let active else { return alternatives }
        return [active] + (showingAlternatives ? alternatives : [])
    }
}
