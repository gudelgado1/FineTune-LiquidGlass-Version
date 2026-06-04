// FineTune/Views/MenuBarPopupView+DeviceRows.swift
import AudioToolbox
import SwiftUI

// MARK: - Device Section Views

extension MenuBarPopupView {

    @ViewBuilder
    var devicesSection: some View {
        devicesContent
    }

    var devicesContent: some View {
        VStack(spacing: 0) {
            if isEditingDevicePriority {
                // Edit mode: drag-and-drop reordering (works for both output and input)
                let defaultDeviceID = showingInputDevices
                    ? deviceVolumeMonitor.defaultInputDeviceID
                    : deviceVolumeMonitor.defaultDeviceID
                ForEach(Array(editableDeviceOrder.enumerated()), id: \.element.uid) { index, device in
                    editableDeviceRow(device: device, index: index, defaultDeviceID: defaultDeviceID)
                }

                // Paired Bluetooth devices (output tab only)
                if !showingInputDevices {
                    if !isBluetoothOn {
                        Text("Turn on Bluetooth to connect devices")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, DesignTokens.Spacing.xs)
                    } else {
                        // Filter out any device already in the output list (handles
                        // IOBluetooth/CoreAudio timing desync where both report the device).
                        let connectedNames = Set(editableDeviceOrder.map(\.name))
                        let filteredPaired = pairedDevices.filter { !connectedNames.contains($0.name) }
                        if !filteredPaired.isEmpty {
                            SectionHeader(title: "Paired")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, DesignTokens.Spacing.xs)

                            ForEach(filteredPaired) { device in
                                PairedDeviceRow(
                                    device: device,
                                    isConnecting: audioEngine.bluetoothDeviceMonitor.connectingIDs.contains(device.id),
                                    errorMessage: audioEngine.bluetoothDeviceMonitor.connectionErrors[device.id],
                                    onConnect: {
                                        audioEngine.bluetoothDeviceMonitor.connect(device: device)
                                    }
                                )
                            }
                        }
                    }
                }
            } else if showingInputDevices {
                ForEach(sortedInputDevices) { device in
                    InputDeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultInputDeviceID,
                        volume: deviceVolumeMonitor.inputVolumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.inputMuteStates[device.id] ?? false,
                        onSetDefault: {
                            audioEngine.setLockedInputDevice(device)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setInputVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.inputMuteStates[device.id] ?? false
                            deviceVolumeMonitor.setInputMute(for: device.id, to: !currentMute)
                        },
                        isFocused: hasKeyboardEngaged && selectedRow == .device(uid: device.uid)
                    )
                    .id(PopupKeyboardNavModel.RowID.device(uid: device.uid))
                }
            } else {
                ForEach(sortedDevices) { device in
                    let selection = audioEngine.getAutoEQSelection(for: device.uid)
                    let profileName: String? = {
                        guard let sel = selection else { return nil }
                        return audioEngine.autoEQProfileManager.profile(for: sel.profileID)?.name
                            ?? audioEngine.autoEQProfileManager.catalogEntry(for: sel.profileID)?.name
                    }()

                    DeviceRow(
                        device: device,
                        isDefault: device.id == deviceVolumeMonitor.defaultDeviceID,
                        volume: deviceVolumeMonitor.volumes[device.id] ?? 1.0,
                        isMuted: deviceVolumeMonitor.muteStates[device.id] ?? false,
                        volumeBackend: audioEngine.outputVolumeBackend(for: device.id),
                        onSetDefault: {
                            audioEngine.setDefaultOutputDevice(device.id)
                        },
                        onVolumeChange: { volume in
                            deviceVolumeMonitor.setVolume(for: device.id, to: volume)
                        },
                        onMuteToggle: {
                            let currentMute = deviceVolumeMonitor.muteStates[device.id] ?? false
                            deviceVolumeMonitor.setMute(for: device.id, to: !currentMute)
                        },
                        autoEQProfileName: profileName,
                        autoEQEnabled: selection?.isEnabled ?? false,
                        onAutoEQToggle: { enabled in
                            audioEngine.setAutoEQEnabled(for: device.uid, enabled: enabled)
                        },
                        autoEQProfileManager: audioEngine.autoEQProfileManager,
                        autoEQSelection: selection,
                        autoEQFavoriteIDs: audioEngine.settingsManager.favoriteAutoEQProfileIDs,
                        onAutoEQSelect: { profile in
                            audioEngine.setAutoEQProfile(for: device.uid, profileID: profile?.id)
                        },
                        onAutoEQImport: {
                            importAutoEQFile(for: device.uid)
                        },
                        onAutoEQToggleFavorite: { id in
                            if audioEngine.settingsManager.isAutoEQFavorite(id: id) {
                                audioEngine.settingsManager.unfavoriteAutoEQProfile(id: id)
                            } else {
                                audioEngine.settingsManager.favoriteAutoEQProfile(id: id)
                            }
                        },
                        autoEQImportError: autoEQImportError,
                        autoEQPreampEnabled: audioEngine.autoEQPreampEnabled,
                        onAutoEQPreampToggle: {
                            audioEngine.setAutoEQPreampEnabled(!audioEngine.autoEQPreampEnabled)
                        },
                        isFocused: hasKeyboardEngaged && selectedRow == .device(uid: device.uid),
                        // Reuse the same `expandedRowID` slot used by per-app EQ.
                        // Device UIDs and app PIDs are disjoint string spaces so
                        // there's no risk of collision — only one inspector is
                        // open at a time, which matches the popup's intent.
                        isAutoEQExpanded: expandedRowID == device.uid,
                        onAutoEQToggleExpansion: {
                            if expandedRowID == device.uid {
                                expandedRowID = nil
                            } else {
                                expandedRowID = device.uid
                            }
                        }
                    )
                    .id(PopupKeyboardNavModel.RowID.device(uid: device.uid))
                }
            }
        }
    }

    /// Sound-effects (system alert volume) row. Rendered by `mainContent` between
    /// the devices and apps sections — at that level (not inside `devicesContent`)
    /// so the dividers above and below it are symmetric section-style dividers.
    /// Output tab only, and hidden in edit mode, is enforced by the caller.
    var systemSoundsRow: some View {
        SystemSoundsRow(
            alertVolume: deviceVolumeMonitor.alertVolume,
            onAlertVolumeChange: { deviceVolumeMonitor.setAlertVolume($0) },
            devices: sortedDevices,
            selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
            isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault
        )
    }

    /// Builds a single row for the priority-edit list. Extracted from
    /// `devicesContent` because the inline expression exceeded Swift's
    /// type-check budget once hide + expand + drop-destination were combined.
    @ViewBuilder
    func editableDeviceRow(
        device: AudioDevice,
        index: Int,
        defaultDeviceID: AudioDeviceID
    ) -> some View {
        let isDeviceHidden = showingInputDevices
            ? audioEngine.settingsManager.isInputDeviceHidden(device.uid)
            : audioEngine.settingsManager.isOutputDeviceHidden(device.uid)

        DeviceEditRow(
            device: device,
            priorityIndex: index,
            isDefault: device.id == defaultDeviceID,
            isInputDevice: showingInputDevices,
            deviceCount: editableDeviceOrder.count,
            isExpanded: expandedDeviceUID == device.uid,
            isHidden: isDeviceHidden,
            onReorder: { newIndex in
                guard let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }) else { return }
                guard newIndex != fromIndex, newIndex >= 0, newIndex < editableDeviceOrder.count else { return }
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    editableDeviceOrder.move(
                        fromOffsets: IndexSet(integer: fromIndex),
                        toOffset: newIndex > fromIndex ? newIndex + 1 : newIndex
                    )
                }
            },
            onToggleExpand: {
                // Input devices have no per-device detail to show —
                // only output devices carry a volume-tier override.
                guard !showingInputDevices else { return }
                withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                    expandedDeviceUID = (expandedDeviceUID == device.uid) ? nil : device.uid
                }
            },
            onToggleHidden: {
                if showingInputDevices {
                    audioEngine.settingsManager.toggleInputDeviceHidden(uid: device.uid)
                } else {
                    audioEngine.settingsManager.toggleOutputDeviceHidden(uid: device.uid)
                }
            },
            expandedContent: {
                // Only render when actually expanded. Input devices skip
                // the expand, so this is never hit for them.
                if !showingInputDevices && expandedDeviceUID == device.uid {
                    DeviceDetailSheet(
                        device: device,
                        transportType: device.id.readTransportType(),
                        autoDetectedTier: deviceVolumeMonitor.autoDetectedOutputVolumeBackend(for: device.id),
                        currentOverride: audioEngine.settingsManager.getDeviceVolumeTierOverride(for: device.uid),
                        onOverrideChange: { newTier in
                            audioEngine.settingsManager.setDeviceVolumeTierOverride(for: device.uid, to: newTier)
                            deviceVolumeMonitor.applyTierOverrideChange(for: device.id)
                        },
                        onDismiss: {}
                    )
                }
            }
        )
        .draggable(device.uid) {
            Text(device.name)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .glassChip(in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { droppedUIDs, _ in
            guard let droppedUID = droppedUIDs.first,
                  let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == droppedUID }),
                  let toIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }),
                  fromIndex != toIndex else { return false }
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                editableDeviceOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
            return true
        }
    }

    @ViewBuilder
    var emptyStateView: some View {
        HStack {
            Spacer()
            VStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: "speaker.slash")
                    .font(.title)
                    .foregroundStyle(DesignTokens.Colors.textTertiary)
                Text("No apps playing audio")
                    .font(.callout)
                    .foregroundStyle(DesignTokens.Colors.textSecondary)

                let ignoredCount = audioEngine.settingsManager.getIgnoredAppInfo().count
                if ignoredCount > 0 {
                    Text("\(ignoredCount) ignored · edit to manage")
                        .font(DesignTokens.Typography.caption)
                        .foregroundStyle(DesignTokens.Colors.textTertiary)
                }
            }
            Spacer()
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }
}
