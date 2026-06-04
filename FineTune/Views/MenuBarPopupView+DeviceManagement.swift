// FineTune/Views/MenuBarPopupView+DeviceManagement.swift
import SwiftUI

// MARK: - Device Priority Edit Management

extension MenuBarPopupView {

    func toggleDevicePriorityEdit() {
        if isEditingDevicePriority {
            // Exiting edit mode: persist to the correct priority list and
            // collapse any expanded device detail (the inline body only lives
            // inside edit mode, so it must collapse when the mode does).
            persistEditableOrder()
            isEditingDevicePriority = false
            expandedDeviceUID = nil
            if wasEditingInputDevices {
                updateSortedInputDevices()
            } else {
                updateSortedDevices()
            }
        } else {
            // Entering edit mode: use the full (unfiltered) device list so hidden devices are also shown.
            wasEditingInputDevices = showingInputDevices
            editableDeviceOrder = showingInputDevices
                ? audioEngine.prioritySortedInputDevices
                : audioEngine.prioritySortedOutputDevices
            isEditingDevicePriority = true
        }
    }

    /// Persists the editable order to the correct priority list, preserving disconnected device positions.
    func persistEditableOrder() {
        let connectedOrder = editableDeviceOrder.map(\.uid)
        if wasEditingInputDevices {
            audioEngine.settingsManager.mergeInputDevicePriorityOrder(
                oldPriority: audioEngine.settingsManager.inputDevicePriorityOrder,
                connectedOrder: connectedOrder
            )
        } else {
            audioEngine.settingsManager.mergeDevicePriorityOrder(
                oldPriority: audioEngine.settingsManager.devicePriorityOrder,
                connectedOrder: connectedOrder
            )
        }
    }

    /// Exits edit mode, saving the current order. Called on edge cases like device changes.
    func exitEditModeSaving() {
        guard isEditingDevicePriority else { return }
        persistEditableOrder()
        isEditingDevicePriority = false
        expandedDeviceUID = nil
    }

    /// Merges device list changes into `editableDeviceOrder` while preserving the user's reordering.
    /// Existing devices are refreshed (CoreAudio may reassign AudioDeviceIDs), removed devices are
    /// dropped, and reconnecting devices are inserted at their saved priority position.
    func mergeDeviceChanges(from latest: [AudioDevice]) {
        let latestByUID = Dictionary(latest.map { ($0.uid, $0) }, uniquingKeysWith: { _, new in new })
        let priorityOrder = wasEditingInputDevices
            ? audioEngine.settingsManager.inputDevicePriorityOrder
            : audioEngine.settingsManager.devicePriorityOrder

        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            // Remove devices that disappeared
            editableDeviceOrder.removeAll { latestByUID[$0.uid] == nil }

            // Refresh existing devices in case AudioDeviceID changed
            for i in editableDeviceOrder.indices {
                if let updated = latestByUID[editableDeviceOrder[i].uid] {
                    editableDeviceOrder[i] = updated
                }
            }

            // Insert reconnecting devices at their saved priority position
            let existingUIDs = Set(editableDeviceOrder.map(\.uid))
            let newDevices = latest.filter { !existingUIDs.contains($0.uid) }
            for device in newDevices {
                let index = Self.priorityInsertionIndex(
                    for: device.uid,
                    in: editableDeviceOrder.map(\.uid),
                    priorityOrder: priorityOrder
                )
                editableDeviceOrder.insert(device, at: index)
            }
        }
    }

    /// Finds the best insertion index for a reconnecting device based on saved priority order.
    ///
    /// Walks `priorityOrder` to find the UIDs that come before and after `uid`, then
    /// places the device between them in `currentOrder`. Falls back to appending at the end
    /// if the device isn't in the priority list or no neighbors are present.
    ///
    /// - Parameters:
    ///   - uid: The device UID to insert.
    ///   - currentOrder: The current list of device UIDs.
    ///   - priorityOrder: The saved full priority list.
    /// - Returns: The index at which to insert the device.
    static func priorityInsertionIndex(for uid: String, in currentOrder: [String], priorityOrder: [String]) -> Int {
        guard let priorityIndex = priorityOrder.firstIndex(of: uid) else {
            // Brand new device not in priority list — append at end
            return currentOrder.count
        }

        // Find the closest priority neighbor that exists in currentOrder and comes AFTER uid in priority.
        // Insert before that neighbor so uid takes its correct position.
        for i in (priorityIndex + 1)..<priorityOrder.count {
            let successor = priorityOrder[i]
            if let currentIndex = currentOrder.firstIndex(of: successor) {
                return currentIndex
            }
        }

        // No successor found — insert at end
        return currentOrder.count
    }
}

// MARK: - Device List Helpers

extension MenuBarPopupView {

    /// Recomputes sorted output devices, filtering hidden ones.
    /// The current default output device is always kept visible even if hidden.
    /// Falls back to the unfiltered list if the filter produces an empty
    /// result — `defaultDeviceUID` can be briefly nil during device switchover
    /// and we don't want the main view to show zero rows in that window.
    func updateSortedDevices() {
        let all = audioEngine.prioritySortedOutputDevices
        let defaultUID = deviceVolumeMonitor.defaultDeviceUID
        let filtered = all.filter { device in
            device.uid == defaultUID || !audioEngine.settingsManager.isOutputDeviceHidden(device.uid)
        }
        sortedDevices = filtered.isEmpty ? all : filtered
    }

    /// Recomputes sorted input devices, filtering hidden ones.
    /// The current default input device is always kept visible even if hidden.
    /// Empty-filter fallback mirrors `updateSortedDevices`.
    func updateSortedInputDevices() {
        let all = audioEngine.prioritySortedInputDevices
        let defaultUID = deviceVolumeMonitor.defaultInputDeviceUID
        let filtered = all.filter { device in
            device.uid == defaultUID || !audioEngine.settingsManager.isInputDeviceHidden(device.uid)
        }
        sortedInputDevices = filtered.isEmpty ? all : filtered
    }
}
