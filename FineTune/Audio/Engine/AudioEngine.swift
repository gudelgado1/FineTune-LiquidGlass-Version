// FineTune/Audio/Engine/AudioEngine.swift
import AudioToolbox
import Foundation
import os
import UserNotifications

@Observable
@MainActor
final class AudioEngine {
    let processMonitor: any AudioProcessMonitoring
    let deviceMonitor: any AudioDeviceProviding
    let bluetoothDeviceMonitor: BluetoothDeviceMonitor
    let deviceVolumeMonitor: any DeviceVolumeProviding
    let volumeState: VolumeState
    let settingsManager: SettingsManager
    let autoEQProfileManager: AutoEQProfileManager
    let permission: AudioRecordingPermission

    #if !APP_STORE
    let ddcController: DDCController
    #endif

    var taps: [pid_t: any ProcessTapControlling] = [:]

    /// Factory for creating tap controllers. Overridable for testing.
    let tapFactory: @MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling

    /// Closure to check if a device is alive. Overridable for testing.
    let isAliveCheck: (AudioDeviceID) -> Bool

    /// One-shot HAL listeners for devices that were present but not alive during priority resolution.
    /// Keyed by AudioDeviceID. Each entry holds the device UID, listener block, and a timeout task.
    var aliveWatchers: [AudioDeviceID: (uid: String, block: AudioObjectPropertyListenerBlock, timeout: Task<Void, Never>)] = [:]

    /// Number of pending alive watchers (exposed for testing).
    var pendingAliveWatcherCount: Int { aliveWatchers.count }

    var appliedPIDs: Set<pid_t> = []
    var appDeviceRouting: [pid_t: String] = [:]  // pid → deviceUID (always explicit)
    var followsDefault: Set<pid_t> = []  // Apps that follow system default
    /// The last output default confirmed by FineTune (user change or programmatic switch).
    /// Used to restore after macOS auto-switches to a lower-priority device.
    var lastConfirmedDefaultUID: String?
    /// Timestamp of the last auto-switch override. Used to distinguish rapid BT auto-switches
    /// (< 1s apart) from deliberate user changes (> 1s after last override).
    var lastAutoSwitchOverrideTime: Date?
    var pendingCleanup: [pid_t: Task<Void, Never>] = [:]  // Grace period for stale tap cleanup
    /// Centralized scheduler for non-RT periodic/delayed work. Replaces the
    /// prior ad-hoc `Task<Void, Never>?` properties for staleCleanup and
    /// healthMonitor. Cancelling the scheduler (in `deinit`/teardown) cancels
    /// every in-flight task in one call — no more forgotten orphans.
    let taskScheduler = AudioTaskScheduler()
    var tapRecoveryCooldownUntil: [pid_t: Date] = [:]  // Prevents tap recreation thrashing
    var diagnostics = AudioEngineDiagnostics()
    let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FineTune", category: "AudioEngine")

    // MARK: - Priority State Machine

    /// Tracks whether we're waiting for macOS to potentially auto-switch after a device connect.
    enum PriorityState {
        case stable
        case pendingAutoSwitch(connectedDeviceUID: String, timeoutTask: Task<Void, Never>)
    }

    var outputPriorityState: PriorityState = .stable
    var inputPriorityState: PriorityState = .stable

    /// Grace period for auto-switch detection (wired devices)
    let autoSwitchGracePeriod: TimeInterval = 2.0

    /// Extended grace period for Bluetooth devices (firmware handshake takes longer)
    let btAutoSwitchGracePeriod: TimeInterval = 5.0

    // MARK: - Echo Suppression

    let outputEchoTracker = EchoTracker(label: "Output")
    let inputEchoTracker = EchoTracker(label: "Input")

    var outputDevices: [AudioDevice] {
        deviceMonitor.outputDevices
    }

    func outputVolumeBackend(for deviceID: AudioDeviceID) -> VolumeControlTier {
        deviceVolumeMonitor.outputVolumeBackend(for: deviceID)
    }

    var inputDevices: [AudioDevice] {
        deviceMonitor.inputDevices
    }



    init(
        permission: AudioRecordingPermission? = nil,
        settingsManager: SettingsManager? = nil,
        autoEQProfileManager: AutoEQProfileManager? = nil,
        deviceProvider: (any AudioDeviceProviding)? = nil,
        processMonitor: (any AudioProcessMonitoring)? = nil,
        deviceVolumeMonitor: (any DeviceVolumeProviding)? = nil,
        tapFactory: (@MainActor (AudioApp, [String], String?) throws -> any ProcessTapControlling)? = nil,
        isAlive: ((AudioDeviceID) -> Bool)? = nil,
        startMonitorsAutomatically: Bool = true
    ) {
        self.permission = permission ?? AudioRecordingPermission()
        let manager = settingsManager ?? SettingsManager()
        self.settingsManager = manager
        self.autoEQProfileManager = autoEQProfileManager ?? AutoEQProfileManager()
        self.volumeState = VolumeState(settingsManager: manager)
        self.isAliveCheck = isAlive ?? { $0.isDeviceAlive() }

        // If a custom deviceProvider is given, use it directly.
        // Otherwise create a real AudioDeviceMonitor (needed by DeviceVolumeMonitor and default tap factory).
        let realDeviceMonitor: AudioDeviceMonitor?
        if let provider = deviceProvider {
            realDeviceMonitor = provider as? AudioDeviceMonitor
            self.deviceMonitor = provider
        } else {
            let monitor = AudioDeviceMonitor()
            realDeviceMonitor = monitor
            self.deviceMonitor = monitor
        }
        self.processMonitor = processMonitor ?? AudioProcessMonitor()
        self.bluetoothDeviceMonitor = BluetoothDeviceMonitor()

        #if !APP_STORE
        let ddc = DDCController(settingsManager: manager)
        self.ddcController = ddc
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager, ddcController: ddc)
        }
        #else
        if let dvMonitor = deviceVolumeMonitor {
            self.deviceVolumeMonitor = dvMonitor
        } else {
            guard let realDeviceMonitor else {
                preconditionFailure("AudioEngine: must provide deviceVolumeMonitor when deviceProvider is not AudioDeviceMonitor")
            }
            self.deviceVolumeMonitor = DeviceVolumeMonitor(deviceMonitor: realDeviceMonitor, settingsManager: manager)
        }
        #endif

        // Tap factory: use provided factory or default to ProcessTapController
        if let factory = tapFactory {
            self.tapFactory = factory
        } else {
            self.tapFactory = { app, deviceUIDs, preferredSource in
                if deviceUIDs.count == 1 {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUID: deviceUIDs[0],
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                } else {
                    return ProcessTapController(
                        app: app,
                        targetDeviceUIDs: deviceUIDs,
                        deviceMonitor: realDeviceMonitor,
                        preferredTapSourceDeviceUID: preferredSource
                    )
                }
            }
        }

        outputEchoTracker.onTimeout = { [weak self] _ in
            self?.restoreConfirmedDefault()
        }
        inputEchoTracker.onTimeout = { [weak self] _ in
            guard let self, self.settingsManager.appSettings.lockInputDevice else { return }
            self.restoreLockedInputDevice()
        }

        // Wire callbacks — needed for both test and production mode
        wireCallbacks()

        if startMonitorsAutomatically {
            Task { @MainActor in
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                }
                self.deviceMonitor.start()

                // Delay Bluetooth startup to avoid IOBluetooth permission dialog
                // and framework initialisation stalling the main thread at launch.
                // The monitor starts 1.5 s after the first frame is drawn.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(1.5))
                    self?.bluetoothDeviceMonitor.start()
                }

                #if !APP_STORE
                ddc.onProbeCompleted = { [weak self] in
                    self?.deviceVolumeMonitor.refreshAfterDDCProbe()
                    self?.refreshAllTapOutputStates()
                }
                ddc.start()
                #endif

                // Start device volume monitor AFTER deviceMonitor.start() populates devices
                self.deviceVolumeMonitor.start()

                self.applyPersistedSettings()
                self.registerNewDevicesInPriority()
                // Seed the confirmed default from whatever macOS has at startup
                self.lastConfirmedDefaultUID = self.deviceVolumeMonitor.defaultDeviceUID
                if manager.appSettings.lockInputDevice {
                    self.restoreLockedInputDevice()
                }
            }
        }

        // Start process monitor when permission is granted
        if startMonitorsAutomatically && permission?.status != .authorized {
            observePermissionGranted()
        }
    }

    private func observePermissionGranted() {
        withObservationTracking {
            _ = self.permission.status
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.permission.status == .authorized {
                    self.processMonitor.start()
                    self.applyPersistedSettings()
                    self.startHealthMonitor()
                    self.logger.info("Audio capture authorized — process monitor started")
                } else {
                    self.observePermissionGranted()
                }
            }
        }
    }

    /// Wire all event callbacks from monitors to AudioEngine handlers.
    private func wireCallbacks() {
        // Sync device volume changes to taps for VU meter accuracy
        deviceVolumeMonitor.onVolumeChanged = { [weak self] deviceID, newVolume in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            let loudnessEnabled = self.settingsManager.appSettings.loudnessCompensationEnabled
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.currentDeviceVolume = newVolume
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                    tap.updateLoudnessCompensation(
                        volume: self.effectiveLoudnessVolume(for: tap),
                        enabled: loudnessEnabled
                    )
                }
            }
        }

        deviceVolumeMonitor.onMuteChanged = { [weak self] deviceID, isMuted in
            guard let self else { return }
            guard let deviceUID = self.deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid else { return }
            for (_, tap) in self.taps {
                if tap.currentDeviceUID == deviceUID {
                    tap.isDeviceMuted = isMuted
                    if tap.currentDeviceUIDs.count == 1,
                       self.outputVolumeBackend(for: deviceID) == .software {
                        tap.volume = self.effectiveVolume(for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
                    }
                }
            }
        }

        processMonitor.onAppsChanged = { [weak self] apps in
            self?.applyPersistedSettings()
            self?.scheduleStaleCleanup()
        }

        // Priority order closures — only for concrete AudioDeviceMonitor
        if let realMonitor = deviceMonitor as? AudioDeviceMonitor {
            realMonitor.outputPriorityOrder = { [weak self] in
                self?.settingsManager.devicePriorityOrder ?? []
            }
            realMonitor.inputPriorityOrder = { [weak self] in
                self?.settingsManager.inputDevicePriorityOrder ?? []
            }
        }

        deviceMonitor.onDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceDisconnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.refresh()
        }

        deviceMonitor.onDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.handleDeviceConnected(deviceUID, name: deviceName)
            self?.bluetoothDeviceMonitor.notifyDeviceAppearedInCoreAudio()
        }

        deviceMonitor.onInputDeviceDisconnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device disconnected: \(deviceName) (\(deviceUID))")
            self?.handleInputDeviceDisconnected(deviceUID)
        }

        deviceMonitor.onInputDeviceConnected = { [weak self] deviceUID, deviceName in
            self?.logger.info("Input device connected: \(deviceName) (\(deviceUID))")
            self?.settingsManager.ensureInputDeviceInPriority(deviceUID)
            self?.handleInputDeviceConnected(deviceUID, name: deviceName)
        }

        deviceVolumeMonitor.onDefaultDeviceChanged = { [weak self] newDefaultUID in
            self?.handleDefaultDeviceChanged(newDefaultUID)
        }

        deviceVolumeMonitor.onDefaultInputDeviceChanged = { [weak self] newDefaultInputUID in
            Task { @MainActor [weak self] in
                self?.handleDefaultInputDeviceChanged(newDefaultInputUID)
            }
        }
    }

    /// Get audio level for a specific app
    func getAudioLevel(for app: AudioApp) -> Float {
        taps[app.id]?.audioLevel ?? 0.0
    }

    func start() {
        // Monitors have internal guards against double-starting
        if permission.status == .authorized {
            processMonitor.start()
        }
        deviceMonitor.start()
        applyPersistedSettings()
        if permission.status == .authorized {
            startHealthMonitor()
        }

        // Restore locked input device if feature is enabled
        if settingsManager.appSettings.lockInputDevice {
            restoreLockedInputDevice()
        }

        logger.info("AudioEngine started")
    }

    func stop() {
        stopHealthMonitor()
        processMonitor.stop()
        deviceMonitor.stop()
        for tap in taps.values {
            tap.invalidate()
        }
        taps.removeAll()
        logger.info("AudioEngine stopped")
    }

    /// Explicit shutdown for app termination. Ensures all listeners are cleaned up.
    /// Call from applicationWillTerminate or equivalent lifecycle hook.
    /// Note: For menu bar apps, process exit cleans up resources anyway, so this is optional.
    func shutdown() {
        stop()
        deviceVolumeMonitor.stop()
        logger.info("AudioEngine shutdown complete")
    }

    // MARK: - Settings Reset

    /// Resets all persisted settings and synchronizes in-memory engine state.
    /// Active taps are kept alive but reverted to defaults (unity volume, unmuted, flat EQ).
    func handleSettingsReset() {
        // 1. Clear persisted state
        settingsManager.resetAllSettings()

        // 2. Clear in-memory routing and tracking state
        appliedPIDs.removeAll()
        appDeviceRouting.removeAll()
        followsDefault.removeAll()

        // 3. Clear cached per-app audio state
        volumeState.resetAll()

        // 4. Refresh output state caches so software-backed devices reset to defaults.
        deviceVolumeMonitor.refreshOutputDeviceStates()

        // 5. Push defaults to all active taps
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
            tap.updateEQSettings(.flat)
            tap.updateAutoEQProfile(nil)
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: false)
        }

        // 6. Re-apply from clean settings (re-establishes routing to system default)
        applyPersistedSettings()

        logger.info("Settings reset: engine state synchronized")
    }

    func setVolume(for app: AudioApp, to volume: Float) {
        volumeState.setVolume(for: app.id, to: volume, identifier: app.persistenceIdentifier)
        if let deviceUID = appDeviceRouting[app.id] {
            ensureTapExists(for: app, deviceUID: deviceUID)
        }
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
            if settingsManager.appSettings.loudnessCompensationEnabled {
                tap.updateLoudnessCompensation(
                    volume: effectiveLoudnessVolume(for: tap),
                    enabled: true
                )
            }
        }
    }

    func getVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    // MARK: - Boost

    func setBoost(for app: AudioApp, to boost: BoostLevel) {
        volumeState.setBoost(for: app.id, to: boost, identifier: app.persistenceIdentifier)
        if let tap = taps[app.id] {
            tap.volume = effectiveVolume(for: app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func getBoost(for app: AudioApp) -> BoostLevel {
        volumeState.getBoost(for: app.id)
    }

    /// Effective gain for ProcessTapController: app volume × boost, plus optional
    /// single-device software output gain for software-backed devices.
    /// Single-device-routed apps on `.software`-backed devices always receive the
    /// device's software gain; multi-destination routing keeps `appGain` alone
    /// because per-device software gain has no unambiguous meaning across fan-out.
    func effectiveVolume(for pid: pid_t, deviceUIDs: [String]? = nil) -> Float {
        let appGain = volumeState.getVolume(for: pid) * volumeState.getBoost(for: pid).rawValue

        guard let resolvedUIDs = deviceUIDs, resolvedUIDs.count == 1,
              let primaryUID = resolvedUIDs.first,
              let device = deviceMonitor.device(for: primaryUID),
              outputVolumeBackend(for: device.id) == .software else {
            return appGain
        }

        return appGain * deviceVolumeMonitor.outputProcessingGain(for: device.id)
    }

    /// Estimated listening level for loudness compensation: device volume × per-app slider.
    /// Does not include boost (intentional amplification beyond reference).
    /// The compensator's phon estimation clamps to [0,1] so values > 1 are treated as reference.
    func effectiveLoudnessVolume(for tap: any ProcessTapControlling) -> Float {
        tap.currentDeviceVolume * volumeState.getVolume(for: tap.app.id)
    }

    func applyTapOutputState(to tap: any ProcessTapControlling, for pid: pid_t, deviceUIDs: [String]? = nil) {
        let resolvedUIDs = deviceUIDs ?? tap.currentDeviceUIDs
        tap.volume = effectiveVolume(for: pid, deviceUIDs: resolvedUIDs)
        tap.isMuted = volumeState.getMute(for: pid)

        if let primaryUID = resolvedUIDs.first,
           let device = deviceMonitor.device(for: primaryUID) {
            tap.currentDeviceVolume = deviceVolumeMonitor.volumes[device.id] ?? 1.0
            tap.isDeviceMuted = deviceVolumeMonitor.muteStates[device.id] ?? false
        } else {
            tap.currentDeviceVolume = 1.0
            tap.isDeviceMuted = false
        }
    }

    func refreshAllTapOutputStates() {
        for tap in taps.values {
            applyTapOutputState(to: tap, for: tap.app.id, deviceUIDs: tap.currentDeviceUIDs)
        }
    }

    func toggleMute(for app: AudioApp) {
        let current = volumeState.getMute(for: app.id)
        setMute(for: app, to: !current)
    }

    func currentVolume(for app: AudioApp) -> Float {
        volumeState.getVolume(for: app.id)
    }

    func isMuted(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    func isAudibleNow(bundleID: String) -> Bool {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else {
            return false
        }
        return app.processObjectIDs.contains { $0.readProcessIsRunning() }
    }

    func setMute(for app: AudioApp, to muted: Bool) {
        volumeState.setMute(for: app.id, to: muted, identifier: app.persistenceIdentifier)
        taps[app.id]?.isMuted = muted
    }

    func getMute(for app: AudioApp) -> Bool {
        volumeState.getMute(for: app.id)
    }

    /// Update EQ settings for an app
    func setEQSettings(_ settings: EQSettings, for app: AudioApp) {
        guard let tap = taps[app.id] else { return }
        tap.updateEQSettings(settings)
        settingsManager.setEQSettings(settings, for: app.persistenceIdentifier)
    }

    /// Get EQ settings for an app
    func getEQSettings(for app: AudioApp) -> EQSettings {
        return settingsManager.getEQSettings(for: app.persistenceIdentifier)
    }

    // MARK: - Per-Device AutoEQ

    func getAutoEQProfile(for deviceUID: String) -> AutoEQProfile? {
        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return nil }
        return autoEQProfileManager.profile(for: selection.profileID)
    }

    func setAutoEQProfile(for deviceUID: String, profileID: String?) {
        if let profileID {
            settingsManager.setAutoEQSelection(for: deviceUID, to: AutoEQSelection(profileID: profileID, isEnabled: true))
        } else {
            settingsManager.setAutoEQSelection(for: deviceUID, to: nil)
        }
        applyAutoEQToTaps(for: deviceUID)
    }

    func setAutoEQEnabled(for deviceUID: String, enabled: Bool) {
        guard var selection = settingsManager.getAutoEQSelection(for: deviceUID) else { return }
        selection.isEnabled = enabled
        settingsManager.setAutoEQSelection(for: deviceUID, to: selection)
        applyAutoEQToTaps(for: deviceUID)
    }

    func getAutoEQSelection(for deviceUID: String) -> AutoEQSelection? {
        settingsManager.getAutoEQSelection(for: deviceUID)
    }

    var autoEQPreampEnabled: Bool {
        settingsManager.autoEQPreampEnabled
    }

    func setAutoEQPreampEnabled(_ enabled: Bool) {
        settingsManager.autoEQPreampEnabled = enabled
        for tap in taps.values {
            tap.setAutoEQPreampEnabled(enabled)
        }
    }

    func setLoudnessCompensationEnabled(_ enabled: Bool) {
        for tap in taps.values {
            tap.updateLoudnessCompensation(volume: effectiveLoudnessVolume(for: tap), enabled: enabled)
        }
    }

    func setLoudnessEqualizationEnabled(_ enabled: Bool) {
        var settings = LoudnessEqualizerSettings()
        settings.enabled = enabled
        for tap in taps.values {
            tap.updateLoudnessEqualization(settings)
        }
    }

    /// Apply AutoEQ profile to all taps currently routed to the given device.
    func applyAutoEQToTaps(for deviceUID: String) {
        for tap in taps.values {
            guard tap.currentDeviceUID == deviceUID else { continue }
            applyAutoEQToTap(tap)
        }
    }

    /// Apply the correct AutoEQ profile to a single tap based on its current device.
    /// Skips AutoEQ entirely for devices that don't support it (speakers, HDMI, etc.).
    /// If the profile isn't loaded yet, triggers an async fetch and applies when ready.
    func applyAutoEQToTap(_ tap: any ProcessTapControlling) {
        guard let deviceUID = tap.currentDeviceUID else { return }

        // Need the device record for logging only — the user is free to
        // apply a profile to any connected output (speaker, HDMI, etc.).
        // The previous `supportsAutoEQ` gate was removed so the audio actually
        // matches what the UI shows in the inline inspector.
        guard let device = deviceMonitor.device(for: deviceUID) else {
            logger.debug("AutoEQ skip for \(tap.app.name): device \(deviceUID) not found in monitor")
            return
        }

        guard let selection = settingsManager.getAutoEQSelection(for: deviceUID),
              selection.isEnabled else {
            tap.updateAutoEQProfile(nil)
            logger.debug("AutoEQ skip for \(tap.app.name): no selection or disabled for \(device.name)")
            return
        }

        // Try in-memory first (instant)
        if let profile = autoEQProfileManager.profile(for: selection.profileID) {
            tap.updateAutoEQProfile(profile)
            return
        }

        // Profile not loaded yet — fetch asynchronously
        tap.updateAutoEQProfile(nil)
        Task { @MainActor in
            guard let profile = await autoEQProfileManager.resolveProfile(for: selection.profileID) else { return }
            // Verify tap still exists and is still routed to the same device
            guard tap.currentDeviceUID == deviceUID else { return }
            guard let latestSelection = settingsManager.getAutoEQSelection(for: deviceUID),
                  latestSelection.profileID == selection.profileID,
                  latestSelection.isEnabled else { return }
            tap.updateAutoEQProfile(profile)
        }
    }

    /// Sets the system default output device, routes followsDefault apps, and registers
    /// an echo so the resulting CoreAudio callback is consumed rather than treated as
    /// an external change.
    /// UI code should call this instead of `deviceVolumeMonitor.setDefaultDevice` directly.
    @discardableResult
    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard deviceVolumeMonitor.setDefaultDevice(deviceID) else { return false }
        if let uid = deviceMonitor.outputDevices.first(where: { $0.id == deviceID })?.uid {
            outputEchoTracker.increment(uid)
            lastConfirmedDefaultUID = uid
            routeFollowsDefaultApps(to: uid)
        }
        return true
    }

    /// Sets the output device for an app.
    /// - Parameters:
    ///   - app: The app to route
    ///   - deviceUID: The device UID to route to, or nil to follow system default
    func setDevice(for app: AudioApp, deviceUID: String?) {
        if let deviceUID = deviceUID {
            // Explicit device selection - stop following default
            followsDefault.remove(app.id)
            // Defensive: re-persist routing even if in-memory state matches,
            // to guard against settings file corruption or incomplete prior writes
            settingsManager.setDeviceRouting(for: app.persistenceIdentifier, deviceUID: deviceUID)

            // If transitioning from follows-default to explicit and tap has a stream-specific
            // source, refresh to mixdown so it won't go stale when the default changes later.
            if let tap = taps[app.id], tap.tapSourceDeviceUID != nil {
                Task {
                    do {
                        try await tap.refreshTapSource(nil)
                        self.applyTapOutputState(to: tap, for: app.id)
                    } catch {
                        self.logger.error("Failed to refresh tap source for \(app.name): \(error)")
                    }
                }
            }

            guard appDeviceRouting[app.id] != deviceUID else { return }
            appDeviceRouting[app.id] = deviceUID
        } else {
            // "System Audio" selected - follow default
            followsDefault.insert(app.id)
            settingsManager.setFollowDefault(for: app.persistenceIdentifier)

            // Route to current default (if available)
            guard let defaultUID = deviceVolumeMonitor.defaultDeviceUID else {
                // No default available yet - routing will happen when default becomes available
                // via handleDefaultDeviceChanged callback
                logger.warning("No default device available for \(app.name), will route when available")
                return
            }
            guard appDeviceRouting[app.id] != defaultUID else { return }
            appDeviceRouting[app.id] = defaultUID
        }

        // Switch tap if needed
        guard let targetUID = appDeviceRouting[app.id] else { return }
        let preferredTapSourceUID = preferredTapSourceDeviceUID(forOutputUIDs: [targetUID], isFollowsDefault: followsDefault.contains(app.id))
        if let tap = taps[app.id] {
            Task {
                do {
                    try await tap.switchDevice(to: targetUID, preferredTapSourceDeviceUID: preferredTapSourceUID)
                    self.applyTapOutputState(to: tap, for: app.id, deviceUIDs: [targetUID])
                    self.applyAutoEQToTap(tap)
                    self.logger.debug("Switched \(app.name) to device: \(targetUID)")
                } catch {
                    self.logger.error("Failed to switch device for \(app.name): \(error.localizedDescription)")
                }
            }
        } else {
            ensureTapExists(for: app, deviceUID: targetUID)
        }
    }

    func getDeviceUID(for app: AudioApp) -> String? {
        appDeviceRouting[app.id]
    }

    /// Returns true if the app follows system default device
    func isFollowingDefault(for app: AudioApp) -> Bool {
        followsDefault.contains(app.id)
    }

    // MARK: - Multi-Device Selection

    /// Gets the device selection mode for an app
    func getDeviceSelectionMode(for app: AudioApp) -> DeviceSelectionMode {
        volumeState.getDeviceSelectionMode(for: app.id)
    }

    /// Sets the device selection mode for an app.
    /// Triggers tap reconfiguration when mode changes.
    func setDeviceSelectionMode(for app: AudioApp, to mode: DeviceSelectionMode) {
        let previousMode = volumeState.getDeviceSelectionMode(for: app.id)
        volumeState.setDeviceSelectionMode(for: app.id, to: mode, identifier: app.persistenceIdentifier)

        guard previousMode != mode else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }

    /// Gets the selected device UIDs for multi-mode
    func getSelectedDeviceUIDs(for app: AudioApp) -> Set<String> {
        volumeState.getSelectedDeviceUIDs(for: app.id)
    }

    /// Sets the selected device UIDs for multi-mode.
    /// Triggers tap reconfiguration when in multi mode.
    func setSelectedDeviceUIDs(for app: AudioApp, to uids: Set<String>) {
        let previousUIDs = volumeState.getSelectedDeviceUIDs(for: app.id)
        volumeState.setSelectedDeviceUIDs(for: app.id, to: uids, identifier: app.persistenceIdentifier)

        guard previousUIDs != uids,
              getDeviceSelectionMode(for: app) == .multi else { return }

        Task {
            await updateTapForCurrentMode(for: app)
        }
    }
}

// MARK: - URLHandlerEngine Conformance

extension AudioEngine: URLHandlerEngine {}
