// FineTune/Views/Rows/AppRowControls.swift
import SwiftUI

/// Shared controls for app rows: mute button, volume slider, percentage, VU meter, device picker, EQ button.
/// Used by both AppRow (active apps) and InactiveAppRow (pinned inactive apps).
struct AppRowControls: View {
    let volume: Float
    let isMuted: Bool
    let devices: [AudioDevice]
    let selectedDeviceUID: String
    let selectedDeviceUIDs: Set<String>
    let isFollowingDefault: Bool
    let defaultDeviceUID: String?
    let deviceSelectionMode: DeviceSelectionMode
    let boost: BoostLevel
    let isEQExpanded: Bool
    /// Passed from the parent row (AppRow / InactiveAppRow) which owns the
    /// ExpandableGlassRow hover. This ensures the full row hit-area triggers
    /// the percentage reveal — not just the narrow controls HStack.
    let isParentHovered: Bool
    let onVolumeChange: (Float) -> Void
    let onMuteChange: (Bool) -> Void
    let onBoostChange: (BoostLevel) -> Void
    let onDeviceSelected: (String) -> Void
    let onDevicesSelected: (Set<String>) -> Void
    let onDeviceModeChange: (DeviceSelectionMode) -> Void
    let onSelectFollowDefault: () -> Void
    // EQ toggle is now triggered by tapping the app name in the parent row
    // (matching the AutoEQ pattern), so we no longer need the closure here.

    @State private var dragOverrideValue: Double?
    @State private var isSliderDragging = false
    @State private var isPercentageEditing = false

    /// Trailing-edge throttling for slider commits.
    /// Slider events fire at display refresh (up to 120 Hz on ProMotion); each
    /// `onVolumeChange` mutates `@Observable VolumeState`, triggering a row
    /// re-render. Coalescing to ~one frame (8 ms) keeps the audio path responsive
    /// (the 30 ms RT volume ramp absorbs the tiny extra latency) while preventing
    /// 120 redraws/sec during a drag.
    @State private var pendingCommitTask: Task<Void, Never>?
    @State private var lastCommittedTime: ContinuousClock.Instant?
    private static let volumeThrottleInterval: Duration = .milliseconds(8)

    private var showPercentage: Bool {
        isParentHovered || isSliderDragging || isPercentageEditing
    }

    private var sliderValue: Double {
        dragOverrideValue ?? VolumeMapping.gainToSlider(volume)
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { sliderValue },
            set: { newValue in
                // Visual feedback is instant via local override — no throttling needed.
                dragOverrideValue = newValue
                let gain = VolumeMapping.sliderToGain(newValue)
                commitVolume(gain)
                if isMuted {
                    onMuteChange(false)
                }
            }
        )
    }

    /// Coalesces volume commits to one per ~frame.
    /// First event in a quiet window fires immediately (leading edge);
    /// subsequent events within `volumeThrottleInterval` reschedule the
    /// trailing commit so the latest value always reaches the engine.
    /// On drag-end we call this with `force: true` to flush the final value.
    private func commitVolume(_ gain: Float, force: Bool = false) {
        pendingCommitTask?.cancel()
        let now = ContinuousClock.now
        if force, let last = lastCommittedTime, now - last < Self.volumeThrottleInterval {
            // Forced commit but inside throttle window — fire now, ignore window.
        }
        let inWindow = lastCommittedTime.map { now - $0 < Self.volumeThrottleInterval } ?? false
        if force || !inWindow {
            onVolumeChange(gain)
            lastCommittedTime = now
            return
        }
        // Trailing commit: schedule the latest value to fire when the window expires.
        let elapsed = now - (lastCommittedTime ?? now)
        let delay = Self.volumeThrottleInterval - elapsed
        pendingCommitTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            onVolumeChange(gain)
            lastCommittedTime = ContinuousClock.now
        }
    }

    /// The displayed percentage value, matching EditablePercentage's formula.
    private var displayedPercentage: Int { Int(round(sliderValue * 100)) }

    /// Show muted icon when muted OR displayed volume is 0%.
    /// Uses percentage threshold (not exact sliderValue == 0) because the x² volume
    /// mapping round-trip can leave sliderValue at tiny non-zero values (e.g. 0.003)
    /// that display as "0%" but fail exact Double equality.
    private var showMutedIcon: Bool { isMuted || displayedPercentage == 0 }

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            // Mute button
            MuteButton(isMuted: showMutedIcon, levelFraction: sliderValue) {
                if showMutedIcon {
                    if displayedPercentage == 0 {
                        onVolumeChange(1.0)
                    }
                    onMuteChange(false)
                } else {
                    onMuteChange(true)
                }
            }

            // Volume slider
            LiquidGlassSlider(
                value: sliderBinding,
                showUnityMarker: false,
                onEditingChanged: { editing in
                    withAnimation(DesignTokens.Animation.hover) { isSliderDragging = editing }
                    if !editing {
                        // Flush any pending throttled commit so the final
                        // slider position is guaranteed to land on the engine
                        // before we drop the local override.
                        if let override = dragOverrideValue {
                            commitVolume(VolumeMapping.sliderToGain(override), force: true)
                        }
                        dragOverrideValue = nil
                    }
                }
            )
            .frame(width: DesignTokens.Dimensions.sliderWidth)
            .opacity(showMutedIcon ? 0.5 : 1.0)
            .scrollWheelStep(sliderBinding, in: 0.0...1.0)

            // Editable volume percentage — collapses to zero width when hidden,
            // expands + fades in on row hover/drag/edit. No layout gap at rest.
            EditablePercentage(
                percentage: Binding(
                    get: {
                        Int(round(sliderValue * 100))
                    },
                    set: { newPercentage in
                        let sliderPos = Double(newPercentage) / 100.0
                        let gain = VolumeMapping.sliderToGain(sliderPos)
                        onVolumeChange(gain)
                    }
                ),
                range: 0...100,
                onEditingChanged: { editing in
                    withAnimation(DesignTokens.Animation.hover) { isPercentageEditing = editing }
                }
            )
            .opacity(showPercentage ? 1 : 0)
            .frame(width: showPercentage ? DesignTokens.Dimensions.percentageWidth : 0)
            .clipped()
            .animation(DesignTokens.Animation.hover, value: showPercentage)

            // Boost chevrons
            BoostChevrons(level: boost, onTap: { onBoostChange(boost.next) })

            DevicePicker(
                devices: devices,
                selectedDeviceUID: selectedDeviceUID,
                selectedDeviceUIDs: selectedDeviceUIDs,
                isFollowingDefault: isFollowingDefault,
                defaultDeviceUID: defaultDeviceUID,
                mode: deviceSelectionMode,
                onModeChange: onDeviceModeChange,
                onDeviceSelected: onDeviceSelected,
                onDevicesSelected: onDevicesSelected,
                onSelectFollowDefault: onSelectFollowDefault,
                showModeToggle: true,
                triggerWidth: 0,
                triggerStyle: .iconOnly
            )

        }
        .fixedSize()
    }
}
