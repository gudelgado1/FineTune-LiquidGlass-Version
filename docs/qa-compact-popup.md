# Compact popup home — item 1

2026-11-02, effort High. The user selected only the first redesign proposal:
active output and volume at the top, applications immediately below. No visible
laboratory or automatic preview launch is permitted. Release remains deferred.

## Behavior

- The header uses a short FineTune title instead of repeating output/input names.
- Current Output shows the actual default output with the existing volume, mute
  and AutoEQ controls. Other Outputs discloses the remaining device rows, retaining
  their volume controls, correction controls and selection actions.
- Selecting a new default returns the output section to its compact state. If a
  default is temporarily unavailable, all connected choices remain visible under
  Choose an Output; no arbitrary device is labeled active.
- The Apps section immediately follows the output section. Sound Effects follows
  Apps when its existing preference is enabled. Priority editing and input controls
  remain available, with an explicit empty-input message replacing the old badge.
- The navigation model receives only visible output rows. Collapsing alternatives
  reconciles keyboard selection and closes an inspector that would become hidden.
  Shift-Command-O toggles alternatives; Escape closes an inspector first, then the
  disclosed alternatives, before dismissing the popup.

The existing DeviceRow callbacks are shared by active and alternative rows.
There are no changes to capture, DSP, routing or volume backend implementations.
No new editor pages, detached windows, material system or menus were introduced.

## Validation

Isolated run `20261102-021046-136018`: **12 tests passed**, zero failures/skips.
Six new presentation tests cover active-first ordering, disclosure, missing/default
UIDs, no devices, current CoreAudio IDs after reconnection, visible keyboard order
and a changed default. The other six cover browser request cancellation, editor
ownership and cached-catalog failure recovery. No visible test windows or labs
were opened for this stage. These tests do not certify the visual layout.

Manual preview acceptance is pending: initial output/apps order; reveal other
outputs, switch between two outputs and confirm collapse/new active control;
volume/mute on active and alternative rows; Shift-Command-O and arrow navigation;
input and priority-edit access; keyboard controls after disconnect/reconnect.
The Preview 13 white-flash fix is inherited and still needs physical acceptance.

## Design basis

This layout is a FineTune product choice guided by task focus and progressive
disclosure, not an Apple-mandated audio panel layout:
[Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers),
[Layout](https://developer.apple.com/design/human-interface-guidelines/layout).
