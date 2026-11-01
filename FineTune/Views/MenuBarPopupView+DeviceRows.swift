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
                SectionHeader(title: "Input")
                if sortedInputDevices.isEmpty {
                    Text("No input devices available")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(sortedInputDevices) { device in
                    InputDeviceRow(
                        device: device,
                        iconOverride: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid),
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
                        isFocused: hasKeyboardEngaged && selectedRow == .device(uid: device.uid),
                        textEntry: textEntry
                    )
                    .id(PopupKeyboardNavModel.RowID.device(uid: device.uid))
                }
            } else {
                compactOutputsContent
            }
        }
    }

    var outputLayout: PopupOutputLayout {
        PopupOutputLayout(devices: sortedDevices, defaultUID: deviceVolumeMonitor.defaultDeviceUID)
    }

    var visibleOutputDevices: [AudioDevice] {
        outputLayout.visibleDevices(showingAlternatives: showingOtherOutputs)
    }

    @ViewBuilder
    var compactOutputsContent: some View {
        let layout = outputLayout
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                SectionHeader(title: layout.active == nil ? "Choose an Output" : "Current Output")
                Spacer()
                if layout.active != nil && !layout.alternatives.isEmpty {
                    Button {
                        setShowingOtherOutputs(!showingOtherOutputs)
                    } label: {
                        HStack(spacing: 4) {
                            Text(showingOtherOutputs ? "Hide Other Outputs" : "Other Outputs (\(layout.alternatives.count))")
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(showingOtherOutputs ? 180 : 0))
                                .animation(DesignTokens.Animation.disclosure, value: showingOtherOutputs)
                        }
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .help("Show or hide other outputs (⇧⌘O)")
                    .accessibilityValue(showingOtherOutputs ? "Expanded" : "Collapsed")
                    .accessibilityIdentifier("output.alternatives.toggle")
                }
            }
            if visibleOutputDevices.isEmpty {
                Text("No output devices available")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(visibleOutputDevices) { device in
                    outputDeviceRow(device)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityIdentifier("output.current.section")
    }

    func outputDeviceRow(_ device: AudioDevice) -> some View {
        let selection = audioEngine.getAutoEQSelection(for: device.uid)
        let profileName: String? = {
            guard let sel = selection else { return nil }
            return audioEngine.autoEQProfileManager.profile(for: sel.profileID)?.name
                ?? audioEngine.autoEQProfileManager.catalogEntry(for: sel.profileID)?.name
        }()

        return DeviceRow(
            device: device,
            iconOverride: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid),
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
            textEntry: textEntry,
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

    func setShowingOtherOutputs(_ show: Bool) {
        // Animate the disclosure itself, not just its chevron. Keep navigation
        // synchronous so removed rows cannot retain keyboard selection during
        // the visual collapse. The shared token also honors Reduce Motion.
        withAnimation(DesignTokens.Animation.disclosure) {
            if !show, let expandedRowID,
               outputLayout.alternatives.contains(where: { $0.uid == expandedRowID }) {
                inlineEditor.dismissCurrent()
                self.expandedRowID = nil
            }
            showingOtherOutputs = show
        }
        syncNavOrder()
    }

    /// Sound-effects row follows the apps on the compact home screen, keeping
    /// the primary output and per-app controls adjacent.
    /// Output tab only, and hidden in edit mode, is enforced by the caller.
    /// Sentinel `expandedRowID` value for the Sound Effects selector — disjoint from
    /// device UIDs and app persistence IDs, so it shares the single-open-row slot
    /// without colliding.
    static let systemSoundsRowID = "__system_sounds__"

    var systemSoundsRow: some View {
        SystemSoundsRow(
            alertVolume: deviceVolumeMonitor.alertVolume,
            onAlertVolumeChange: { deviceVolumeMonitor.setAlertVolume($0) },
            devices: sortedDevices,
            selectedDeviceUID: deviceVolumeMonitor.systemDeviceUID,
            isFollowingDefault: deviceVolumeMonitor.isSystemFollowingDefault,
            defaultDeviceUID: deviceVolumeMonitor.defaultDeviceUID,
            isExpanded: expandedRowID == Self.systemSoundsRowID,
            onToggleExpand: {
                withAnimation(DesignTokens.Animation.disclosure) {
                    expandedRowID = (expandedRowID == Self.systemSoundsRowID) ? nil : Self.systemSoundsRowID
                }
            },
            onSelectDevice: { uid in
                if let device = sortedDevices.first(where: { $0.uid == uid }) {
                    deviceVolumeMonitor.setSystemDeviceExplicit(device.id)
                }
                withAnimation(DesignTokens.Animation.disclosure) { expandedRowID = nil }
            },
            onSelectFollowDefault: {
                deviceVolumeMonitor.setSystemFollowDefault()
                withAnimation(DesignTokens.Animation.disclosure) { expandedRowID = nil }
            }
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
                withAnimation(DesignTokens.Animation.disclosure) {
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
                withAnimation(DesignTokens.Animation.disclosure) {
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
            iconOverride: audioEngine.settingsManager.getDeviceIconOverride(for: device.uid),
            onIconOverrideChange: { symbol in
                audioEngine.settingsManager.setDeviceIconOverride(for: device.uid, to: symbol)
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
                .glassChip(in: RoundedRectangle(cornerRadius: DesignTokens.Dimensions.buttonRadius))
        }
        .dropDestination(for: String.self) { droppedUIDs, _ in
            guard let droppedUID = droppedUIDs.first,
                  let fromIndex = editableDeviceOrder.firstIndex(where: { $0.uid == droppedUID }),
                  let toIndex = editableDeviceOrder.firstIndex(where: { $0.uid == device.uid }),
                  fromIndex != toIndex else { return false }
            withAnimation(DesignTokens.Animation.disclosure) {
                editableDeviceOrder.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
            }
            return true
        }
    }

    @ViewBuilder
    var emptyStateView: some View {
        let ignoredCount = audioEngine.settingsManager.getIgnoredAppInfo().count
        ContentUnavailableView {
            Label("No apps playing audio", systemImage: "speaker.slash")
                .font(.callout)
        } description: {
            if ignoredCount > 0 {
                Text("\(ignoredCount) ignored · edit to manage")
                    .font(DesignTokens.Typography.caption)
            }
        }
        .padding(.vertical, DesignTokens.Spacing.xl)
    }
}
