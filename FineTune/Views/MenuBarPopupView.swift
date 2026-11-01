// FineTune/Views/MenuBarPopupView.swift
import AudioToolbox
import SwiftUI
import UniformTypeIdentifiers

struct MenuBarPopupView: View {
    @Bindable var audioEngine: AudioEngine
    @Bindable var deviceVolumeMonitor: DeviceVolumeMonitor
    @ObservedObject var updateManager: UpdateManager

    let permission: AudioRecordingPermission

    /// Accessibility trust state — forwarded to the Settings window for the
    /// media-keys section. Bindable so live re-renders occur when trust flips.
    @Bindable var accessibility: AccessibilityPermissionService

    /// Transient status (offline, suppressionDegraded) for the media-keys banner.
    @Bindable var mediaKeyStatus: MediaKeyStatus

    /// Shared popup visibility flag — mirrored to this service so `MediaKeyMonitor`
    /// can skip HUD display while the popup is the "HUD".
    @Bindable var popupVisibility: PopupVisibilityService

    /// Preview HUD button hook in Settings.
    let hudController: HUDWindowController

    /// Needed so the popup can reconcile the tap state when the user toggles
    /// `mediaKeyControlEnabled` inside Settings. Trust-flip reconciliation is
    /// handled globally via `AccessibilityPermissionService.onTrustChanged`
    /// wired in `FineTuneApp.init`.
    let mediaKeyMonitor: MediaKeyMonitor

    /// Optional custom settings presenter. Production uses this to open a
    /// borderless AppKit window instead of the default macOS Settings scene.
    let openSettingsOverride: (() -> Void)?

    init(
        audioEngine: AudioEngine,
        deviceVolumeMonitor: DeviceVolumeMonitor,
        updateManager: UpdateManager,
        permission: AudioRecordingPermission,
        accessibility: AccessibilityPermissionService,
        mediaKeyStatus: MediaKeyStatus,
        popupVisibility: PopupVisibilityService,
        hudController: HUDWindowController,
        mediaKeyMonitor: MediaKeyMonitor,
        openSettingsOverride: (() -> Void)? = nil
    ) {
        self.audioEngine = audioEngine
        self.deviceVolumeMonitor = deviceVolumeMonitor
        self.updateManager = updateManager
        self.permission = permission
        self.accessibility = accessibility
        self.mediaKeyStatus = mediaKeyStatus
        self.popupVisibility = popupVisibility
        self.hudController = hudController
        self.mediaKeyMonitor = mediaKeyMonitor
        self.openSettingsOverride = openSettingsOverride
    }

    // MARK: - State

    /// Memoized sorted output devices - only recomputed when device list or default changes
    @State var sortedDevices: [AudioDevice] = []

    /// Memoized sorted input devices
    @State var sortedInputDevices: [AudioDevice] = []

    /// Which device tab is selected (false = output, true = input)
    @State var showingInputDevices = false
    /// Alternatives are disclosed on demand so apps stay near the active output.
    @State var showingOtherOutputs = false

    /// Track which app has its EQ panel expanded (only one at a time)
    /// Uses DisplayableApp.id (String) to work with both active and inactive apps
    @State var expandedRowID: String?

    /// Track popup visibility to pause VU meter polling when hidden
    @State var isPopupVisible = true

    /// Error message shown when AutoEQ profile import fails
    @State var autoEQImportError: String?
    /// Task that auto-clears the import error after 3 seconds
    @State var importErrorClearTask: Task<Void, Never>?

    /// Memoized paired Bluetooth devices
    @State var pairedDevices: [PairedBluetoothDevice] = []

    /// Whether Bluetooth hardware is powered on
    @State var isBluetoothOn = false

    /// Whether edit mode is active (affects both device priority and app visibility)
    @State var isEditingDevicePriority = false

    /// Tracks which tab was active when edit mode started (for correct save on exit)
    @State var wasEditingInputDevices = false

    /// Editable copy of device order for drag-and-drop reordering
    @State var editableDeviceOrder: [AudioDevice] = []

    /// Device whose inline detail panel is expanded in edit mode (nil when
    /// collapsed). Mirrors the `expandedRowID` pattern used for per-app EQ.
    @State var expandedDeviceUID: String?

    /// Hover state for support link heart animation
    @State private var isSupportHovered = false
    /// Manual capture rebuild running (footer button). Recreating every tap is
    /// fast but not instant, so the button reports progress instead of looking
    /// like it did nothing.
    @State private var isRebuildingCapture = false

    @State private var isEditButtonHovered = false
    @State private var isSettingsButtonHovered = false

    @State var navModel = PopupKeyboardNavModel()
    /// Delivers digits typed on the keyboard-selected row to that row's editor.
    @State var textEntry = PopupTextEntryCoordinator()
    @State var inlineEditor = PopupInlineEditorContext()
    /// Logical keyboard-nav selection. Plain @State (not @FocusState) so reads
    /// and writes are synchronous within a single event handler — using
    /// @FocusState here raced with SwiftUI's auto-focus-on-key-window claim
    /// (WWDC23 "SwiftUI cookbook for focus" calls this anti-pattern). A single
    /// focusable anchor on the popup body root receives key events; rows
    /// render their selection state purely from this @State value.
    @State var selectedRow: PopupKeyboardNavModel.RowID? = nil
    /// True once the user presses any nav-vocabulary key. Gates the row-highlight
    /// visual so a fresh popup opens clean even though `selectedRow` may be set.
    @State var hasKeyboardEngaged: Bool = false
    /// `.onKeyPress` only fires when the modifier-owning view (or a focused
    /// descendant) has focus, so the body root holds a focus anchor.
    @FocusState var anchorFocused: Bool

    @Environment(\.openSettings) private var openSettings

    // MARK: - Resolved Dimensions

    private var popupDimensions: PopupDimensions {
        audioEngine.settingsManager.appSettings.popupDimensions
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(alignment: .center) {
                deviceTabsHeader
                Spacer()
                if isEditingDevicePriority {
                    Text("Drag or type a number to set priority")
                        .font(.subheadline)
                        .foregroundStyle(DesignTokens.Colors.textSecondary)
                } else {
                    defaultDevicesSummary
                }
                Spacer()
                editPriorityButton
                settingsButton
            }
            .padding(.bottom, DesignTokens.Spacing.xs)

            ScrollViewReader { proxy in
                ScrollView {
                    mainContent(scrollProxy: proxy)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: popupDimensions.maxContentHeight)
                .onChange(of: selectedRow) { _, newFocus in
                    guard let newFocus else { return }
                    withAnimation(DesignTokens.Animation.hover) {
                        proxy.scrollTo(newFocus, anchor: .center)
                    }
                }
            }
        }
        .padding(popupDimensions.contentPadding)
        .frame(width: popupDimensions.width)
        .background(
            WindowAppearanceBridge(appearance: audioEngine.settingsManager.appSettings.appearance.nsAppearance)
                .frame(width: 0, height: 0)
        )
        .darkGlassBackground(cornerRadius: DesignTokens.Dimensions.popupRadius)
        .overlay {
            RoundedRectangle(cornerRadius: DesignTokens.Dimensions.popupRadius, style: .continuous)
                .strokeBorder(DesignTokens.Colors.popupBorder, lineWidth: 0.5)
        }
        .preferredColorScheme(audioEngine.settingsManager.appSettings.appearance.swiftUIColorScheme)
        .environment(\.appearancePreference, audioEngine.settingsManager.appSettings.appearance)
        .environment(\.popupInlineEditor, inlineEditor)
        .onChange(of: inlineEditor.isPresented) { _, presented in
            if !presented && isPopupVisible { anchorFocused = true }
        }
        .onAppear {
            updateSortedDevices()
            updateSortedInputDevices()
            pairedDevices = audioEngine.bluetoothDeviceMonitor.pairedDevices
            isBluetoothOn = audioEngine.bluetoothDeviceMonitor.isBluetoothOn
            // popupVisibility.isVisible is driven by the filtered NSWindow key
            // notifications below, not by .onAppear — SwiftUI mounts this view
            // before the popup is actually shown, and setting isVisible here
            // would suppress the HUD on the first media key at cold launch.
        }
        .onChange(of: audioEngine.outputDevices) { _, _ in
            if isEditingDevicePriority && !wasEditingInputDevices {
                mergeDeviceChanges(from: audioEngine.outputDevices)
            }
            updateSortedDevices()
            syncNavOrder()
        }
        .onChange(of: audioEngine.inputDevices) { _, _ in
            if isEditingDevicePriority && wasEditingInputDevices {
                mergeDeviceChanges(from: audioEngine.inputDevices)
            }
            updateSortedInputDevices()
            syncNavOrder()
        }
        .onChange(of: showingInputDevices) { _, _ in
            exitEditModeSaving()
            syncNavOrder()
            if hasKeyboardEngaged {
                selectedRow = navModel.defaultFocus(defaultOutputUID: currentDefaultDeviceUID())
            }
        }
        .onChange(of: audioEngine.apps) { _, _ in
            syncNavOrder()
        }
        .onChange(of: isEditingDevicePriority) { _, editing in
            if editing {
                selectedRow = nil
                hasKeyboardEngaged = false
            }
            syncNavOrder()
        }
        .onChange(of: audioEngine.bluetoothDeviceMonitor.pairedDevices) { _, newValue in
            pairedDevices = newValue
        }
        .onChange(of: audioEngine.bluetoothDeviceMonitor.isBluetoothOn) { _, newValue in
            isBluetoothOn = newValue
        }
        .onChange(of: deviceVolumeMonitor.defaultDeviceID) { _, _ in
            updateSortedDevices()
            if !showingInputDevices && !isEditingDevicePriority {
                setShowingOtherOutputs(false)
            } else {
                syncNavOrder()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // Global notification — fires for every window in the process. Filter to
            // FluidMenuBarExtra's popup window so unrelated windows (the HID-tap
            // primer, NSAlert panels, etc.) don't mark the popup as visible and
            // suppress the HUD.
            guard let window = notification.object as? NSWindow,
                  String(describing: type(of: window)).contains("FluidMenuBarExtra")
            else { return }
            isPopupVisible = true
            popupVisibility.isVisible = true
            audioEngine.bluetoothDeviceMonitor.refresh()
            // No CoreAudio listener exists for alert volume — refresh on open so the
            // System Sounds row shows the live value if it changed elsewhere.
            deviceVolumeMonitor.refreshAlertVolume()
            syncNavOrder()
            hasKeyboardEngaged = false
            selectedRow = nil
            anchorFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
            guard let window = notification.object as? NSWindow,
                  String(describing: type(of: window)).contains("FluidMenuBarExtra")
            else { return }
            isPopupVisible = false
            popupVisibility.isVisible = false
            inlineEditor.dismissCurrent()
            hasKeyboardEngaged = false
            selectedRow = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            // SwiftUI Menu tracking (e.g. sample-rate picker in the device
            // inspector) makes the popup window resign key without deactivating
            // the app. Only treat app-level deactivation as a real dismiss so
            // in-popup pickers don't collapse edit mode.
            exitEditModeSaving()
        }
        // Single focus anchor on the body root. `.onKeyPress` only fires when
        // the modifier-owning view (or a focused descendant) has focus, so the
        // anchor must claim it on popup open. `.focusEffectDisabled` suppresses
        // the OS-drawn focus ring around the entire popup.
        .focusable()
        .focusEffectDisabled()
        .focused($anchorFocused)
        // [.down, .repeat] is required so holding a key keeps moving the
        // selection or adjusting volume — `.down` alone fires once per press.
        .onKeyPress(phases: [.down, .repeat]) { keyPress in
            handleKeyPress(keyPress)
        }
        .background {
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .overlay(alignment: .topLeading) {
            Text("menuBarPopup.root")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 1, height: 1)
                .accessibilityIdentifier("menuBarPopup.root")
        }
    }

    // MARK: - Header Components

    /// Edit priority button — pencil ↔ checkmark, styled to match settingsButton
    private var editPriorityButton: some View {
        Button {
            toggleDevicePriorityEdit()
        } label: {
            Image(systemName: isEditingDevicePriority ? "checkmark" : "pencil")
                .accessibilityIdentifier("devices.reorder.toggle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: isEditingDevicePriority ? .semibold : .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(isEditingDevicePriority || isEditButtonHovered
            ? DesignTokens.Colors.iconOnGlassEmphasis
            : DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
        .onHover { isEditButtonHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isEditButtonHovered)
        .animation(DesignTokens.Animation.disclosure, value: isEditingDevicePriority)
        .accessibilityLabel(isEditingDevicePriority ? "Done reordering" : "Reorder devices")
        .help(isEditingDevicePriority ? "Done reordering" : "Reorder devices")
    }

    private var settingsButton: some View {
        Button("Settings", systemImage: "gearshape.fill") {
            openSettingsWindow()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.plain)
        .font(.system(size: 15, weight: .medium))
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(isSettingsButtonHovered
            ? DesignTokens.Colors.iconOnGlassEmphasis
            : DesignTokens.Colors.interactiveDefault)
        .frame(
            minWidth: DesignTokens.Dimensions.minTouchTarget,
            minHeight: DesignTokens.Dimensions.minTouchTarget
        )
        .contentShape(Rectangle())
        .onHover { isSettingsButtonHovered = $0 }
        .animation(DesignTokens.Animation.hover, value: isSettingsButtonHovered)
    }

    /// Handles Escape key: closes EQ first, then dismisses the popup.
    /// Escape order: expanded device detail → edit mode → expanded app EQ →
    /// popup dismiss. Expanded device detail is checked before
    /// `isEditingDevicePriority` so Escape collapses the row first rather than
    /// tearing down edit mode entirely.
    private func handleEscape() {
        if inlineEditor.dismissCurrent() { return }
        if expandedDeviceUID != nil {
            withAnimation(DesignTokens.Animation.disclosure) {
                expandedDeviceUID = nil
            }
        } else if isEditingDevicePriority {
            toggleDevicePriorityEdit()
        } else if expandedRowID != nil {
            withAnimation(DesignTokens.Animation.disclosure) {
                expandedRowID = nil
            }
        } else if showingOtherOutputs && !showingInputDevices {
            setShowingOtherOutputs(false)
        } else {
            NSApp.keyWindow?.resignKey()
        }
    }

    private func openSettingsWindow() {
        exitEditModeSaving()
        NSApp.keyWindow?.resignKey()
        NSApp.activate(ignoringOtherApps: true)
        if let openSettingsOverride {
            openSettingsOverride()
        } else {
            openSettings()
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func mainContent(scrollProxy: ScrollViewProxy) -> some View {
        // Section spacing tracks the chosen popup density (compact/comfortable/spacious).
        VStack(alignment: .leading, spacing: popupDimensions.sectionSpacing) {
            devicesSection
                .padding(.bottom, DesignTokens.Spacing.sm)

            appsSection(scrollProxy: scrollProxy)

            // Keep secondary system sounds available after the main app controls.
            if !showingInputDevices && !isEditingDevicePriority
                && audioEngine.settingsManager.appSettings.showSoundEffectsRow {
                SectionHeader(title: "System")
                    .padding(.top, DesignTokens.Spacing.sm)
                systemSoundsRow
            }

            Divider()
                .padding(.vertical, DesignTokens.Spacing.xs)

            // Footer: support link + quit
            HStack {
                Button {
                    NSWorkspace.shared.open(DesignTokens.Links.support)
                } label: {
                    Label("Donate", systemImage: isSupportHovered ? "heart.fill" : "heart")
                }
                .buttonStyle(.plain)
                .font(.system(.callout, weight: .regular))
                .foregroundStyle(isSupportHovered ? Color(nsColor: .systemPink) : DesignTokens.Colors.textSecondary)
                .onHover { hovering in
                    withAnimation(DesignTokens.Animation.hover) {
                        isSupportHovered = hovering
                    }
                }
                .accessibilityLabel("Donate to FineTune")
                .help("Donate to FineTune")

                Spacer()

                rebuildCaptureButton

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(.title3, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                        .frame(
                            minWidth: DesignTokens.Dimensions.minTouchTarget,
                            minHeight: DesignTokens.Dimensions.minTouchTarget
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignTokens.Colors.interactiveDefault)
                .iconButtonStyle()
                .accessibilityLabel("Quit FineTune")
                .help("Quit FineTune (⌘Q)")
            }
        }
    }

    // MARK: - Rebuild Capture

    /// Recreates every per-app tap. Sits next to Quit because it's the fix the
    /// user reaches for when an app's volume stops responding or an app that is
    /// playing never shows up — having it here avoids a trip to Settings.
    /// Disabled while the audio system itself is unresponsive: rebuilding is all
    /// HAL work, so Settings ▸ Troubleshooting ▸ Reset Core Audio is the fix then.
    @ViewBuilder
    private var rebuildCaptureButton: some View {
        let audioSystemDown = !audioEngine.audioSystemHealth.allowsPeriodicHALWork

        Button {
            guard !isRebuildingCapture else { return }
            // Set synchronously, before the Task: `.disabled` only re-evaluates
            // after this flag flips, so flipping it inside the Task would let
            // two clicks in the same runloop turn both start a rebuild.
            isRebuildingCapture = true
            Task {
                await audioEngine.rebuildAllTaps()
                isRebuildingCapture = false
            }
        } label: {
            Group {
                if isRebuildingCapture {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(.title3, weight: .regular))
                        .symbolRenderingMode(.hierarchical)
                }
            }
            .frame(
                minWidth: DesignTokens.Dimensions.minTouchTarget,
                minHeight: DesignTokens.Dimensions.minTouchTarget
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(DesignTokens.Colors.interactiveDefault)
        .iconButtonStyle()
        .disabled(isRebuildingCapture || audioSystemDown)
        .accessibilityLabel("Rebuild app capture")
        .help(audioSystemDown
              ? "Audio system isn't responding — reset Core Audio in Settings"
              : "Rebuild app capture — use if an app's volume stops working or it's missing from the list")
    }

    // MARK: - Device Direction

    /// Configure the native tab role and capsule shape together. The control
    /// retains system selection/press artwork without an extra glass layer.
    @ViewBuilder
    private var deviceTabsHeader: some View {
        if #available(macOS 27.0, *) {
            DeviceDirectionControl(showingInput: $showingInputDevices.animation(DesignTokens.Animation.disclosure))
                .fixedSize()
        } else {
            deviceDirectionPicker.pickerStyle(.segmented)
        }
    }

    private var deviceDirectionPicker: some View {
        Picker("Device Direction", selection: $showingInputDevices.animation(DesignTokens.Animation.disclosure)) {
            Label("Output Devices", systemImage: showingInputDevices ? "speaker.wave.2" : "speaker.wave.2.fill")
                .tag(false)
            Label("Input Devices", systemImage: showingInputDevices ? "mic.fill" : "mic")
                .tag(true)
        }
        .labelsHidden()
        .labelStyle(.iconOnly)
        .imageScale(.medium)
        .symbolRenderingMode(.monochrome)
        .fixedSize()
        .help("Choose output or input devices")
        .accessibilityIdentifier("devices.direction.picker")
    }

    /// Current default devices, centered in the header.
    private var defaultDevicesSummary: some View {
        let output = sortedDevices.first { $0.uid == deviceVolumeMonitor.defaultDeviceUID }?.name
        let input = sortedInputDevices.first { $0.uid == deviceVolumeMonitor.defaultInputDeviceUID }?.name
        return HStack(spacing: DesignTokens.Spacing.xs) {
            if let output { defaultDeviceLabel(output, symbol: "speaker.wave.2.fill") }
            if output != nil, input != nil {
                Text(verbatim: "·").foregroundStyle(.tertiary)
            }
            if let input { defaultDeviceLabel(input, symbol: "mic.fill") }
        }
        .font(.caption)
        .foregroundStyle(DesignTokens.Colors.textSecondary)
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .glassChip(in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("popup.defaultDevices")
    }

    private func defaultDeviceLabel(_ name: String, symbol: String) -> some View {
        HStack(spacing: DesignTokens.Spacing.xxs) {
            Image(systemName: symbol).imageScale(.small).accessibilityHidden(true)
            Text(name).lineLimit(1).truncationMode(.middle)
        }
    }
}
