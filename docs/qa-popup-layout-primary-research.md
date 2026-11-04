# Popup resize crash — primary-source research

2026-11-02 (Australia/Brisbane), Extra High investigation. Scope: the real popup's
NSWindow/NSHostingView/ScrollView sizing boundary. No app code was changed and no
UI, visible fixture, preview or unrelated application was launched for this note.
Restoring the small Regular symbols is independent of this layout investigation.
No release or merge is part of this work.

## Reported evidence and its limits

The parent investigation reports that Preview 20 throws an uncaught
`NSGenericException` for too many Layout Window passes after moving window-frame
animation into `window.animator().setFrame` inside `NSAnimationContext`.
The supplied stack includes NSScrollView layout invalidation, SwiftUI change
delivery, NSThemeFrame resizing, NSWindow layout and a Core Animation commit.
Plain offscreen NSPanel tests had passed, but the real hosting root contains a
ScrollView, `.fixedSize()` and a measurement callback that requests another
window frame. These are project observations supplied to this research, not
claims derived from Apple documentation or a new reproduction by this agent.

The source inspected at this checkpoint calls `PopupFrameAnimation.apply` from
`FluidMenuBarExtraStatusItem.setWindowFrame`. The helper sends `setFrame` through
the animator proxy with display enabled. `RootViewModifier` reads geometry before
`.fixedSize()`, publishes changes, then expands its outer frame to the available
viewport. `FluidMenuBarExtraWindow` asynchronously returns those sizes to the
status item. Its NSHostingView is layer-backed, autoresizes on both axes and has
`sizingOptions = []`. This combination must be tested as an integration; a bare
window with a constant-size child does not exercise the feedback path.

## What Apple documents

### Frame mutation can cause more layout and drawing

`NSWindow.setFrame(_:display:)` and `setFrame(_:display:animate:)` set the complete
window frame. With display enabled, the window asks its view hierarchy to redraw
views that need display. The animated variant performs a smooth resize whose
duration comes from `animationResizeTime(_:)`. Neither document promises
nonblocking input, interruptibility or immunity to self-sizing feedback.
[setFrame display](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:)),
[setFrame animate](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:animate:)),
[animationResizeTime](https://developer.apple.com/documentation/appkit/nswindow/animationresizetime(_:)).

The animator is an implied-animation proxy. Crucially,
`NSAnimationContext.allowsImplicitAnimation` says that using the proxy enables
implicit animation and can make descendant frame changes animate along with the
original property for layer-backed views. Thus changing only the window's entry
point can alter descendant layout/animation behavior; it is not merely a
scheduling-equivalent replacement for the three-argument window resize method.
This is a documented API difference, not proof of the precise crash mechanism.
[animator](https://developer.apple.com/documentation/appkit/nsanimatablepropertycontainer/animator()),
[allowsImplicitAnimation](https://developer.apple.com/documentation/appkit/nsanimationcontext/allowsimplicitanimation).

### Layout has an invalidation boundary

AppKit's `NSView.layout()` documentation prohibits invalidating constraints,
invalidating parent or outside-subtree layout, and invoking drawing as part of
layout. `NSView.updateConstraints()` separately warns that scheduling another
constraint update from its own update pass creates a feedback loop. Apple's
Auto Layout guide explains that a layout pass can temporarily contain both
updated and not-yet-updated frames, so external invalidation during that pass
can feed back into the hierarchy.
[NSView.layout](https://developer.apple.com/documentation/appkit/nsview/layout()),
[updateConstraints](https://developer.apple.com/documentation/appkit/nsview/updateconstraints()),
[Auto Layout Guide — Changing Constraints](https://developer.apple.com/library/archive/documentation/UserExperience/Conceptual/AutolayoutPG/ModifyingConstraints.html).

`NSWindow.layoutIfNeeded()` and `NSView.layoutSubtreeIfNeeded()` are automatically
called by the framework before display. They can also be called manually to
obtain current layout, but Apple says not to override either. Calling them
repeatedly from size-observation or animation callbacks is not a documented
way to break a layout cycle. Likewise, broadly forcing `needsLayout = false`
is not a repair prescribed by these APIs.
[Window layoutIfNeeded](https://developer.apple.com/documentation/appkit/nswindow/layoutifneeded()),
[View layoutSubtreeIfNeeded](https://developer.apple.com/documentation/appkit/nsview/layoutsubtreeifneeded()).

### Hosting sizing options do not disable SwiftUI layout

An NSHostingView bridges SwiftUI size preferences back to AppKit during layout.
Its `sizingOptions` controls automatic minimum, ideal and maximum constraints;
when used as an NSWindow's content view, those options can also affect the
window's content min/max size. Setting `[]` disables those generated constraints.
It does **not** state that SwiftUI stops measuring content, that ScrollView stops
invalidating its viewport, or that an application's separate geometry callback
can no longer request a window resize. Do not treat `[]` as a layout-loop guard.
[NSHostingView](https://developer.apple.com/documentation/swiftui/nshostingview),
[sizingOptions](https://developer.apple.com/documentation/swiftui/nshostingview/sizingoptions),
[NSHostingSizingOptions](https://developer.apple.com/documentation/swiftui/nshostingsizingoptions).

SwiftUI's `fixedSize()` requests the view's ideal size as a counterproposal to its
parent's offered size; its effect depends on the actual view. This is not a
constant size guarantee for a compound ScrollView/header/content tree.
[fixedSize](https://developer.apple.com/documentation/swiftui/view/fixedsize()).

`sceneBridgingOptions` was also checked. Its documented options manage window
title/subtitle and toolbar content, not window geometry. Its default `.all` when
used as the window's contentView is not evidence of an additional undocumented
size manager. Do not disable it merely on that hypothesis.
[sceneBridgingOptions](https://developer.apple.com/documentation/swiftui/nshostingview/scenebridgingoptions),
[NSHostingSceneBridgingOptions](https://developer.apple.com/documentation/swiftui/nshostingscenebridgingoptions).

### Framework animation APIs are not all interchangeable

Apple's cross-framework animation article documents `NSAnimationContext.animate`
with SwiftUI Animation and demonstrates resizing an NSView. It also explains
that SwiftUI animation has a different implementation without a backing
CAAnimation. The article does not demonstrate a self-sizing NSWindow containing
an animated SwiftUI ScrollView. It cannot certify that replacing one animation
API with another fixes this crash.
[Unifying your app's animations](https://developer.apple.com/documentation/swiftui/unifying-your-app-s-animations).

## Narrow mechanism hypotheses to distinguish

These are inferences to test, **not established platform facts**:

1. **Implicit descendant animation introduces a layout cycle.** The newly used
   animator proxy enables implied animation while the NSHostingView/NSScrollView
   descendants are reacting to each frame. Compare with direct frame writes under
   non-animated conditions using the same real content and callbacks.
2. **Intermediate viewport size is promoted into a new desired content size.**
   A window-frame change alters the proposal; ideal-size measurement republishes
   a size; the callback retargets the same window. Record measured size, desired
   target, actual frame, semantic content state and callback order separately.
3. **Stale or near-equal queued targets prevent convergence.** Successive geometry
   observations can enqueue obsolete sizes or alternate around backing-pixel
   rounding. Record at pixel precision; do not hide the issue with an arbitrary
   delay or unbounded debounce.

The stack establishes activity at these boundaries, not which hypothesis wins.
No matching Apple bug identifier or published guarantee for this exact exception
was found in the consulted macOS 27.0 and 27.2 release notes. The documented
ScrollView fixes there address other behavior; do not call this a confirmed
known macOS regression or claim a particular OS update resolves it.
[macOS 27 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes),
[macOS 27.2 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27_2-release-notes).

## Public scheduling alternatives and their actual guarantees

- **A direct, non-animated window frame is the useful control condition.** The
  window API documents it. Preserve root/content measurement and the real scroll
  view so this comparison isolates the animation entry point. Disabling animation
  globally and simplifying content at the same time would not distinguish cause.
- **`NSViewAnimation` explicitly supports window/view frame changes** and defaults
  to nonblocking mode. However, its documented `stop()` moves to the final frame,
  which makes it unsuitable as a drop-in retarget implementation that expects
  interruption at the current rectangle. Its docs do not guarantee that it avoids
  this hosting feedback loop or say which private frame-mutation path it uses.
  [NSViewAnimation](https://developer.apple.com/documentation/appkit/nsviewanimation).
- **`NSAnimation` with `.nonblocking` is documented to use a standard or specified
  run-loop mode that permits input.** A custom main-runloop driver can be built
  from this scheduling model, but main-thread ownership and each frame write
  still need to be made explicit. Avoid `.nonblockingThreaded` for AppKit frame
  mutation. [BlockingMode](https://developer.apple.com/documentation/appkit/nsanimation/blockingmode).
- **A display link is another documented animation clock.** CADisplayLink can be
  added to a run loop and used to compute each animation frame. On macOS,
  `NSView.displayLink(target:selector:)` synchronizes callbacks with that view's
  display, but does not call back when the view is hidden/off-display. Hidden,
  close and teardown paths therefore need immediate/final-state handling and
  invalidation. This API is not a documented cure for reentrant layout.
  [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink),
  [NSView displayLink](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:)).

A custom driver is a **candidate architecture**, not an Apple-approved fix for
this particular bug. Its value would be explicit sequencing: one main-actor
geometry owner, one logical end target, and discrete direct frame writes outside
an active layout/CA-commit callback, without the animator proxy's inherited
implicit-animation behavior. Selecting a new clock alone is insufficient.

## Suggested validation boundary before another preview

This is project-specific experimental guidance, based on the API boundaries above:

- Use the real Fluid root, layer-backed NSHostingView, ScrollView, content limits,
  geometry publisher and async return path. Keep the native control and regular
  symbols independent so they cannot mask a sizing-path regression.
- Vary only frame mutation/animation scheduling in the first comparison. Check
  repeated expansion/collapse, rapid reversal, scrollable-height content, input
  switching, close/reopen mid-resize, appearance changes and Reduce Motion.
- Coalesce redundant pending size requests. Distinguish a semantic new target from
  a frame-animation intermediate result; do not feed the latter into another
  recursive animation. A one-main-queue-turn deferral is not proof of convergence.
- Do not draw or force layout inside layout callbacks. Direct per-frame writes can
  use display-disabled mutation and leave normal display scheduling to AppKit,
  but only reproduction can show whether that is sufficient for this hierarchy.
- Cancellation must prevent stale callbacks from writing after close, teardown
  or a newer target. A deterministic frame-step seam can test cancellation and
  retargeting, but a bare-panel test cannot certify hosting/ScrollView integration.
- The Objective-C exception can terminate the test host; run the reproducer in a
  bounded child process and record success/exit, pending callbacks and relevant
  size trajectories. Do not use a try/catch wrapper as the asserted fix.

No hidden or visible test was executed by this research agent. Evidence of a fix
must come from the actual integration reproduction and appropriate regression
checks; a compile, valid signature or earlier plain-panel pass is insufficient.
