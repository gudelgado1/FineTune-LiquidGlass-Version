# Popup device direction — SF Symbols and selection

2026-11-02, Australia/Brisbane. The user accepted compact home item 1 and
Preview 16's Other Outputs animation, then requested SF Symbols and clarified
that the desired sliding emphasis belongs to Output/Input, not the volume bar.
No preview or visible laboratory was launched for this work.

## Findings and implementation

The old control already used SF Symbols, but hierarchical speaker rendering
reduced the wave opacity. Two plain buttons shared a custom Liquid Glass union;
hover used the same foreground emphasis as selection, with no selected segment
background. A selected state was consequently difficult to distinguish.

Replace that group with a SwiftUI segmented Picker bound to the existing
`showingInputDevices` state. Native selection appearance, hover, focus and
accessibility come from the platform control. No custom selection overlay,
nested glass, or additional highlight animation is installed. The exact shape
and motion are OS behavior; HIG does not promise a particular animation curve.

Both labels use SF Symbols in monochrome, regular weight, 14 pt and medium
image scale. Output uses speaker.wave.2; Input uses mic. Only the selected
symbol uses its fill variant. These visual settings are FineTune choices,
not HIG-mandated values. The native control manages foreground/selection
colors instead of the previous hand-tuned black/white foreground.

Labels keep descriptive Output Devices/Input Devices text for accessibility
while the displayed control is icon-only. The Picker exposes its own selection
state; custom per-button hover state and the glass namespace are removed.
The shared disclosure animation still honors Reduce Motion; this does not
claim to override the native control's own accessibility behavior.

The existing boolean selection, default-device state, navigation reconciliation,
Tab shortcut, input/output editing and accepted Other Outputs behavior remain
on their existing paths. The root row keyboard handler and native Picker focus
interaction require manual keyboard acceptance. Accessibility identifiers for
the two removed plain buttons are replaced by devices.direction.picker.

## Primary sources

- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols):
  weights/scales, rendering modes, semantic colors and variants.
- [Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls):
  related choices, visible selection, consistent segment/content sizing and labels.
- [SegmentedPickerStyle](https://developer.apple.com/documentation/swiftui/segmentedpickerstyle):
  native segmented presentation.
- [Motion](https://developer.apple.com/design/human-interface-guidelines/motion):
  purposeful, brief feedback that does not block repeated interaction.

## Acceptance boundary

Build and existing presentation/navigation tests check compilation and state
behavior, not rendered icon balance, compositor contrast or VoiceOver speech.
Manual preview review must cover visible icon-only labels, selected highlight,
hover without changing selection, click/Tab switching, row arrows/volume keys,
light/dark, Increase Contrast and Reduce Motion. No visual pass is claimed
before that review. No release is authorized.


## Local checks

Twelve existing compact-output/browser/editor/offline tests passed in run
20261102-030027-489142; optimized arm64 Release passed. A hidden hosting probe
extracted the actual header source, replacing only its animation token with nil
for still inspection. In both appearance preferences and both selected states,
it resolved to an NSSegmentedControl with two segments, expected selection,
and nonempty symbol images (19×14 and 14×16 pt). Every probe window remained
unordered. This is structural evidence, not a perceptual smoothness claim.

The hidden-view bitmap cache did not reliably draw the native/layer-backed
content, so its images are excluded from visual acceptance. Native accessibility
proxy inspection also does not certify VoiceOver labels or speech; retain that
manual check. No desktop screenshots or visible test windows were used.

Preview 16 checkpoint CI (26525fa) completed: 1033 unit test methods, 28 selected
native TSan methods and 93 DSP methods per sanitizer; Release/package passed.
Downloaded artifact CRC, strict signature, metadata and source-merge tree were
verified. That checkpoint precedes this symbol/picker change.
