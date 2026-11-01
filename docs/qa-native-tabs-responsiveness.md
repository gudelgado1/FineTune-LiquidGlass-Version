# Native direction tabs — resize responsiveness and icon size

2026-11-02 (Australia/Brisbane). Preview 19's capsule is improved, but the user
reports a stalled visual transition and small symbols. The supplied 6.695 s,
336×232, 120 fps recording shows the expanded native highlight lingering while
the Output/Input content changes. This recording is kept outside Git/public
bundles; it is not a post-fix acceptance capture.

## Scope and design contract

Applied the user-suggested
[macos-golden-gate-design skill](https://github.com/github/awesome-copilot/blob/main/skills/macos-golden-gate-design/SKILL.md),
including design-patterns, SwiftUI implementation and source references. The
original was located from the user link and read as reference; no global skill
installation or external script execution was required.

Pane map: transient menu-bar panel | compact native direction control | existing
device/app content. The popup and capsule are meaningful transient/control
boundaries; no new shell, card, glass layer, gradient or synthetic press effect
is added. The existing native tab role/capsule and accepted Other Outputs action
remain. The user-specified official Sketch component was inspected in the prior
phase; no different Figma working-copy node is claimed as inspected.

## Evidence loop and hypotheses

Ranked candidates were synchronous window resize blocking UI dispatch, rebuilding
symbol artwork during selection, and an intrinsic-size change perturbing layout.
The first has a direct minimized API reproduction: a nonactivating NSPanel is
kept 10,000 points beyond all display bounds, never key/main, with a 0.30 s
resize. `setFrame(..., animate: true)` occupied the calling UI thread for
303.984 ms. The animator proxy returned in 1.946 ms and reached the same endpoint.
These are API-call timings, not app input-latency or compositor measurements.

The permanent test uses the real PopupFrameAnimation seam called by the status
item's geometry path. Before the fix, the three-case suite failed specifically
because the resize call held the UI thread for 301.044 ms (150 ms budget).
After the fix, all three cases pass, including a rapid new target and an immediate
update overriding an in-flight destination. Panels remain outside all displays,
non-key/non-main and ignored by mouse input; they do not cover the user's desktop.

- Red: run 20261102-054137-406283; one expected responsiveness failure.
- Green: run 20261102-054324-188955; three frame-animation methods passed.
- Combined: run 20261102-054442-334181; 18 targeted methods passed, zero failed/skipped.
- Optimized arm64 Release passed.

Command (use the project's documented isolated build/package directories):

```sh
python3 scripts/run-tests.py --only FineTuneTests/PopupFrameAnimationTests
```

The minimized call probe is retained outside the repository in
`work/native-tabs-motion-repro`, with its machine-readable red/green timing
record. No production debug logging was added. The supplied recording plus the
blocking-call regression identify a concrete UI-thread stall; they do not prove
that every possible glass-rendering anomaly has been eliminated.

## Implementation

PopupFrameAnimation applies the window's frame with the AppKit animator proxy
inside an NSAnimationContext. The existing window provides the resize duration;
the existing status-item geometry calculation remains the single frame owner.
A zero-duration animation handles hidden/immediate/Reduce Motion updates and
supersedes an older destination. No completion callback can later restore an
obsolete frame. The active native tab control can continue receiving UI dispatch
while the window animates.

The capsule uses native control size Large and SF Symbols Large scale with the
same body text style and monochrome rendering. No image stretching or numerical
font/slot dimensions are introduced. The native control tests verify both named
symbols fit within the control's fitting geometry and preserve binding/action
behavior. Existing image caching, accessibility descriptions, per-segment tooltips
and exclusive tab role are retained. The direction bridge remains macOS27-gated;
older systems retain the existing SwiftUI fallback. Frame animation uses standard
AppKit APIs on all supported versions.

## Acceptance still required

Review the real popup manually: Output/Input press and release, quick reversals,
selection persistence, larger symbols, row keyboard/volume navigation and popup
close/reopen. Also recheck Other Outputs/AutoEQ expansion because they share the
frame application path, even though their disclosure state and duration policy
are unchanged. Check light/dark, inactive behavior, Reduce Motion/Transparency,
Increase Contrast and VoiceOver as appropriate. No visible lab or automatic
preview launch was used; the design is not certified from static code/tests.
Sliders remain outside this fix.

## Primary API references

- [NSWindow.setFrame](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:animate:))
- [Animator proxy](https://developer.apple.com/documentation/appkit/nsanimatablepropertycontainer/animator())
- [Animation context](https://developer.apple.com/documentation/appkit/nsanimationcontext/runanimationgroup(_:completionhandler:))
- [Apple motion guidance](https://developer.apple.com/design/human-interface-guidelines/motion)
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Official macOS kit frame inspected previously](https://www.sketch.com/s/57153a31-3379-4737-8ac6-dbfd6525f052/f/6533AE04-CE96-4CD0-8DBB-D1C4DD7384C7#Inspector)
