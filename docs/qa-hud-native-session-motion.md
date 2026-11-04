# Native status-item highlight and HUD motion

The 2026-10-31 reference recording supplied by Gustavo establishes the visual target for keyboard-triggered volume notifications. This change applies to the system capsule HUD and FineTune's own menu-bar icon. The classic and per-app HUDs retain their presentations. Audio processing is unchanged.

## Evidence and limits

The retained recording is 1778 × 1062, 13.783333 seconds, H.264, with variable frame intervals (648 decoded frames). Its SHA-256 is `7cba99936906cea71a53e443a7232c3ee46815ac97e5b6691c66ced865c78925`. Motion measurements use decoded presentation timestamps rather than treating every frame as 1/120 second. Analysis crops the HUD and the native volume item; the recording's other content is not a specification or instruction.

The entry brightness curve fits approximately 0.55 seconds with a cubic Bezier (0.26, 0, 0.145, 1); exit fits 0.40 seconds with (0.19, 0, 0.325, 1). Segment pitch is consistent with a scale from 0.9 to 1.0. The zoom origin is the bottom of the menu-bar row, ten points above the visible capsule. The icon becomes highlighted before the HUD is readable and loses that highlight at the start of the exit. The implementation follows those observations.

These are empirical fits to foreground brightness and geometry in one recording, not recovered Apple constants or physical compositor alpha. The recording has no key-event timestamps, so it does not establish the exact native idle timeout. FineTune retains its 1100 ms delay. Keyboard volume steps now interpolate the rendered track over 150 ms; drag and mute remain immediate. Reduce Motion disables zoom and uses the existing short fade.

## Why the old highlight did not appear

On the tested macOS 27.2 build 26B123, `NSStatusBarButton.highlight(true)` changes the NSCell state without painting the native rounded background. A second probe, the private `setButtonHighlighted:`, likewise changed internal state without changing the captured background. That second selector is not used by the implementation.

A small isolated application with the public `NSStatusItemExpandedInterfaceDelegate` installed and a guarded `_requestExpandedInterfaceSession` request produced the actual native capsule. The before/after composed background difference was 15.63 on an 8-bit channel scale; the legacy-only probe measured 0.00. A separate owned foreground text window kept key focus and received a character while the session remained active in the background application. No user document, audio service, or other application's UI was used by that test.

The request method is private. Production checks its runtime argument count and individual Objective-C return/argument types before making the sole void/no-argument invocation. Session cancellation and begin/end callbacks use public macOS 27 APIs. Older systems or an unavailable/mismatched request method use the legacy highlight. A missing acknowledgement also degrades to legacy for that presentation. An explicit new presentation retries the unacknowledged request; repeated volume presses do not. It cannot guarantee the new capsule on an unsupported OS. No synthetic click, undocumented Double argument, custom background pill, or activation of FineTune substitutes for the native request.

## Lifecycle and placement

The popup and HUD share ownership of one native session. Repeated volume presses reuse that session. A HUD timeout releases ownership when its fade starts. A new show during cancellation rearms after the previous session ends; stale callbacks cannot close a newer session. A new popup intent also survives a native cancellation already queued by an outside click. A late begin with no visible owner is cancelled. Native user cancellation hides the HUD or popup. Clicking the icon while the HUD is visible promotes the existing session to the normal popup; closing one presentation cannot remove the other's highlight.

The native highlight does not make the HUD a key/main window. Popup interaction retains the normal key-window behavior. On macOS 27, ordinary icon activation follows the expanded-interface delegate instead of being intercepted a second time by the legacy local mouse monitor. Context menus and Command-drag retain their existing paths.

The visible capsule stays 308 × 65 points with the existing 40-point compositor margin. Its resting center follows FineTune's status-window frame, with a 10-point gap below the menu-bar row and display-edge clamping. The motion anchor adjusts horizontally when the envelope is clamped. Glass selection, tint, foreground, blur, and appearance policy are unchanged from Preview4. Existing light/dark and changing-backdrop evidence remains applicable to the resting renderer; this is not a new claim of exact parity on every background.

## Verification scope

Focused lifecycle tests exercise repetition, pending and late callbacks, cancellation/re-show, popup ownership, legacy degradation, and ABI rejection with an inert driver. Render tests measure the scaled glyph/track bounds around the menu-row origin, Reduce Motion behavior, and partially filled intermediate track segments. Controller tests require the highlight to clear while the fading panel is still visible and to survive a subsequent show.

The capture helper includes only explicitly selected owned laboratory and HUD windows and crops to the HUD envelope, with audio and menu-bar capture disabled. Composed motion capture uses layer zero because the production level-23 panel is filtered to black by this capture route. It does not validate production z-order. Native icon proof uses a separate strict crop exactly around the owned laboratory status item, with no adjacent icons. The public API alone still does not provide a complete specification for Apple's HUD timing, hover policy, fullscreen behavior, or keyboard-modifier handling.

The composed motion check retained 687 frames. With the programmed curves held fixed, relative foreground brightness fitted a0.546s entry and0.348s exit (versus programmed0.55/0.40s). Segment-pitch scale residual was0.0112 against0.9+0.1×appearance across24 transition samples. Capture cadence, compositing and curve fitting limit this comparison; the shorter fitted exit is not evidence of exact native parity. Native-session acknowledgement and the visible capsule were also observed using the integrated driver and the real Fluid status item; the startup retry was checked separately from the initial request.
