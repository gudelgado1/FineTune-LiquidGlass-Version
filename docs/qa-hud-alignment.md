# HUD alignment and native menu-bar highlight

2026-10-31. This revision changes placement and menu-bar integration. Capsule size,
track, icon, material and tint are unchanged from Glass Preview3.

## Reference and evidence boundary

The user confirmed the reference HUD was invoked with volume keys. Subsequent
screenshots show the macOS volume icon moved to two positions, with the capsule
center following the icon and the icon highlighted. The user selected the same
behavior for FineTune's **own** menu-bar item.

Static target: `/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter`,
SHA-256 `78e729cc88503073c448a3ba8e832416aecd791e99971c514e4ce5b4043a868d`.
REA evidence was exported before closing the session.

- `MenuPositionCoordinator`, `0x1000f0a18`, evidence
  `ev_11ab37e9560784280bf2c416baeed7795aa606098df6bce348b2fc2a7a213119`,
  reads an anchor/screen and repositions a window with `setFrameTopLeftPoint:`.
- Its observer registration, `0x1000efccc`, evidence
  `ev_7be919db5789ff0d8a7d199f87f240325fb5db0973ba1b1a699c2e973fb07055`,
  subscribes to status-item window move, resize and screen-change notifications.
- Searches also found MenuPositionAnchor and HighlightableAnchor. Names alone are
  not runtime evidence. This is a general Control Center positioning coordinator;
  the entire keyboard-HUD dispatch path and every indirect specialization were not
  recovered. Centering and highlighting are corroborated by the user's captures,
  rather than inferred solely from those names.

The ten-point gap below the menu-bar row matches the supplied references on the
current30pt menu bar. Edge clamping below is FineTune's explicit policy, not a
claim that every native fallback/edge configuration was recovered.

## Reproduced defect

A focused test through the actual HUD controller, on the real screen, failed:

```
python3 scripts/run-tests.py --build-dir <QA-build> --packages-dir <packages> \
  --only FineTuneTests/HUDPositionAlignmentTests
Expectation failed: abs(panel.frame.origin.y - expected.y) < 0.5
abs(panel.frame.origin.y - expected.y) -> 30.0
```

Red run: `20261031-161239-047068`, test0.066s. Independently, a scoped lab capture
recorded the HUD envelope at displayY30 even though placement requested displayY0.
The capsule's own40pt margin was correct. AppKit moved the *whole window* down to
avoid the menu bar, adding a second30pt offset. This was not an internal icon/bar
layout error or a blur issue.

HUDPanel now overrides `constrainFrameRect(_:to:)` to preserve the controller's
explicit frame. [Apple documents this override point](https://developer.apple.com/documentation/appkit/nswindow/constrainframerect(_:to:)).
The controller remains responsible for screen bounds and menu spacing.

## Integration

HUDMenuBarAnchor shares the app-owned NSStatusBarButton with the controller.
FluidMenuBarExtra binds its real button, and FineTuneApp connects the scene to the
controller's anchor. Geometry is read afresh for each show and refreshed when the
status window moves, resizes or changes screen. The status window frame covers the
menu-bar row; its button's drawing bounds have optical insets and would otherwise
place the capsule2pt too high on the tested system.

For a308×65pt capsule in its388×145pt envelope:

- Horizontal center is the status-window center, clamped to keep the envelope
  within its display. Negative/vertical display origins are supported.
- Visible capsule top is10pt below the status-window bottom. The40pt transparent
  effect margin extends above that top and is not added to the visible gap.
- Missing/hidden anchor falls back to the existing screen-corner policy.
- Suppression-degraded placement keeps its existing upper-left-quarter policy.
- Classic and per-app notification placement retain their existing policies.

Highlight uses [NSButton.highlight(_:)](https://developer.apple.com/documentation/appkit/nsbutton/highlight(_:)),
inherited by NSStatusBarButton. The native menu-bar appearance draws the highlight.
Popup and HUD each own a Boolean request, combined with OR, so closing either one
cannot remove the other's highlight. Fade completions are generation-checked:
an obsolete fade cannot unhighlight a re-shown HUD. Dismissal/termination clears
the HUD request. The panel still cannot become key/main.

## Verification

Targeted15 tests passed, then the full988 tests passed (0 skipped) in run
`20261031-161848-027485`. Release arm64 built successfully. New regression coverage
includes actual AppKit frame placement, moved anchor without another show,
multiple display origins and edge clamping, shared highlight ownership, and
re-show during a fade.

The isolated DEBUG lab creates its own native status item before any audio
services. Its actual native-state record reported:

| Quantity | Result |
| --- | --- |
| Status window |x2009,y1410,width56,height30 |
| HUD envelope |x1843,y1295,width388,height145 |
| Horizontal center error |0pt |
| Gap below menu row |10pt |
| Visible capsule top inset |40pt |
| Native button cell highlighted |true |
| Production panel level |23 |
| Added vertical constraint offset |0pt; previously30pt |

The capture filter includes only the owned fixture and HUD, as authorized. Its
level23 image was black despite valid geometry/state metadata; this filtered
screenshot is explicitly **not accepted as visual proof** of that layer. Native
highlight state and placement above come from the lab's own AppKit objects and
window metadata. The user's preview acceptance remains the visual check of the
real menu-bar highlight/placement on their desktop. This does not alter the
previous material/backdrop QA results.

No new private API or additional Accessibility permission is needed for this
alignment/highlight change. The existing private glass backend and its documented
fallback/contrast limitations remain. No commit, push or PR was made.
