// FineTune/Views/MenuBarPopupView+KeyboardNavigation.swift
import AppKit
import SwiftUI

// MARK: - Keyboard Navigation

extension MenuBarPopupView {

    /// True while a text field holds the key window's first responder — i.e. the
    /// user is typing into an `EditablePercentage` editor. The popup root's
    /// `.onKeyPress` sits *above* that focused field in the responder chain, so
    /// without this guard a Return keypress meant to commit the typed percentage
    /// is instead consumed here as "activate the selected row" — which calls
    /// `resignKey()` and dismisses the popup before the edit commits (the reported
    /// bug: popup vanishes, volume unchanged). Arrow keys would likewise hijack
    /// caret movement. Bailing out lets Return/arrows/etc. reach the field editor.
    var isEditingText: Bool {
        // The SwiftUI TextField's field editor is an NSTextView (subclass of NSText).
        NSApp.keyWindow?.firstResponder is NSText
    }

    func syncNavOrder() {
        let activeDevices = showingInputDevices ? sortedInputDevices : sortedDevices
        navModel.syncOrder(
            activeDevices: activeDevices,
            appPersistenceIDs: audioEngine.displayableApps.map(\.id),
            isEditingPriority: isEditingDevicePriority
        )
    }

    func currentDefaultDeviceUID() -> String? {
        showingInputDevices
            ? deviceVolumeMonitor.defaultInputDeviceUID
            : deviceVolumeMonitor.defaultDeviceUID
    }

    func handleKeyPress(_ keyPress: KeyPress) -> KeyPress.Result {
        // While editing a text field (e.g. the percentage editor), let Return /
        // arrows / etc. flow to the field editor instead of driving row nav — see
        // `isEditingText`. Fixes: typing a value + Enter closed the popup without
        // applying the value.
        if isEditingText { return .ignored }

        let mods = keyPress.modifiers
        let isM = keyPress.key == KeyEquivalent("m")
        let isRecognized: Bool = {
            switch keyPress.key {
            case .upArrow, .downArrow, .leftArrow, .rightArrow, .return, .space, .tab:
                return true
            default:
                return isM
            }
        }()
        // Wake gate: compute target locally so first-press actions never read a
        // stale selection. ↑/↓ wake without moving; action keys wake and act on
        // the default in the same press.
        let target: PopupKeyboardNavModel.RowID?
        let wokeUp: Bool
        if !hasKeyboardEngaged && isRecognized {
            hasKeyboardEngaged = true
            target = navModel.defaultFocus(defaultOutputUID: currentDefaultDeviceUID())
            selectedRow = target
            wokeUp = true
        } else {
            target = selectedRow
            wokeUp = false
        }
        switch keyPress.key {
        case .upArrow:
            if wokeUp { return target == nil ? .ignored : .handled }
            if let next = navModel.previous(before: target) {
                selectedRow = next
                return .handled
            }
            return .ignored
        case .downArrow:
            if wokeUp { return target == nil ? .ignored : .handled }
            if let next = navModel.next(after: target) {
                selectedRow = next
                return .handled
            }
            return .ignored
        case .leftArrow:
            return adjustVolume(at: target, direction: -1, shift: mods.contains(.shift))
        case .rightArrow:
            return adjustVolume(at: target, direction: +1, shift: mods.contains(.shift))
        case .return, .space:
            return activate(target)
        case .tab:
            guard case .device = target else { return .ignored }
            toggleDeviceTab()
            return .handled
        default:
            return isM ? toggleMute(for: target) : .ignored
        }
    }

    func adjustVolume(at target: PopupKeyboardNavModel.RowID?, direction: Int, shift: Bool) -> KeyPress.Result {
        guard let target else { return .ignored }
        let baseStep = audioEngine.settingsManager.appSettings.volumeHotkeyStep.sliderDelta
        let step = shift ? baseStep * 2.0 : baseStep
        let delta = step * Double(direction)
        switch target {
        case .app(let persistenceID):
            if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == persistenceID }) {
                applyAppVolumeStep(
                    currentGain: audioEngine.currentVolume(for: app),
                    currentMute: audioEngine.isMuted(for: app),
                    direction: direction,
                    delta: delta,
                    setGain: { audioEngine.setVolume(for: app, to: $0) },
                    setMute: { audioEngine.setMute(for: app, to: $0) }
                )
                return .handled
            }
            applyAppVolumeStep(
                currentGain: audioEngine.getVolumeForInactive(identifier: persistenceID),
                currentMute: audioEngine.getMuteForInactive(identifier: persistenceID),
                direction: direction,
                delta: delta,
                setGain: { audioEngine.setVolumeForInactive(identifier: persistenceID, to: $0) },
                setMute: { audioEngine.setMuteForInactive(identifier: persistenceID, to: $0) }
            )
            return .handled
        case .device(let uid):
            if showingInputDevices {
                guard let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = Double(deviceVolumeMonitor.inputVolumes[device.id] ?? 1.0)
                let next = Float(max(0.0, min(1.0, current + delta)))
                deviceVolumeMonitor.setInputVolume(for: device.id, to: next)
            } else {
                guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = Double(deviceVolumeMonitor.volumes[device.id] ?? 1.0)
                let next = Float(max(0.0, min(1.0, current + delta)))
                deviceVolumeMonitor.setVolume(for: device.id, to: next)
            }
            return .handled
        }
    }

    /// Mirrors `ShortcutsRegistry.adjustTargetVolume`'s mute-edge semantics for
    /// both active and pinned-inactive app rows.
    func applyAppVolumeStep(
        currentGain: Float,
        currentMute: Bool,
        direction: Int,
        delta: Double,
        setGain: (Float) -> Void,
        setMute: (Bool) -> Void
    ) {
        let currentSlider = VolumeMapping.gainToSlider(currentGain)
        let nextSlider = max(0.0, min(1.0, currentSlider + delta))
        let nextGain = VolumeMapping.sliderToGain(nextSlider)
        let willBeSilent = nextSlider <= 0.001
        if direction > 0 {
            if currentMute { setMute(false) }
        } else if currentMute && !willBeSilent {
            setMute(false)
        } else if !currentMute && willBeSilent {
            setMute(true)
        }
        setGain(nextGain)
    }

    func toggleMute(for target: PopupKeyboardNavModel.RowID?) -> KeyPress.Result {
        guard let target else { return .ignored }
        switch target {
        case .app(let persistenceID):
            if let app = audioEngine.apps.first(where: { $0.persistenceIdentifier == persistenceID }) {
                audioEngine.toggleMute(for: app)
                return .handled
            }
            let current = audioEngine.getMuteForInactive(identifier: persistenceID)
            audioEngine.setMuteForInactive(identifier: persistenceID, to: !current)
            return .handled
        case .device(let uid):
            if showingInputDevices {
                guard let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = deviceVolumeMonitor.inputMuteStates[device.id] ?? false
                deviceVolumeMonitor.setInputMute(for: device.id, to: !current)
            } else {
                guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                let current = deviceVolumeMonitor.muteStates[device.id] ?? false
                deviceVolumeMonitor.setMute(for: device.id, to: !current)
            }
            return .handled
        }
    }

    func activate(_ target: PopupKeyboardNavModel.RowID?) -> KeyPress.Result {
        guard let target else { return .ignored }
        switch target {
        case .device(let uid):
            if showingInputDevices {
                guard let device = sortedInputDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                audioEngine.setLockedInputDevice(device)
            } else {
                guard let device = sortedDevices.first(where: { $0.uid == uid }) else {
                    return .ignored
                }
                audioEngine.setDefaultOutputDevice(device.id)
            }
            NSApp.keyWindow?.resignKey()
            return .handled
        case .app(let persistenceID):
            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                expandedRowID = (expandedRowID == persistenceID) ? nil : persistenceID
            }
            return .handled
        }
    }

    func toggleDeviceTab() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            showingInputDevices.toggle()
        }
    }
}
