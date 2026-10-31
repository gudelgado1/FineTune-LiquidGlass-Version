# Public Apple evidence for macOS volume HUD behavior

Research date: 2026-10-31. Scope: public Apple documentation, Apple Support's
macOS guides, the installed macOS SDK headers, and a first-hand developer report
on Apple's forum. No UI interaction, settings changes or product-code changes
were performed. This is evidence for a behavior audit, not a claim that the
system volume HUD has a complete published specification.

## What Apple documents

| Behavior | Public evidence and confidence | Consequence for comparison |
| --- | --- | --- |
| Volume keys and mute | Apple's macOS27 guide describes the dedicated volume keys as step controls and the mute key as a toggle: press again to unmute. It also describes the Fn requirement when the keyboard uses standard function keys. **Official, high confidence.** [Adjust brightness and volume](https://support.apple.com/en-au/guide/mac-help/mchlgtd_bright01/27/mac/27) | Check normal up/down and mute/unmute. This does not define the exact native step size, mute-at-zero behavior of keyboard events, or the level restored by volume-up while muted. |
| Fine adjustment | Option–Shift with Volume Up/Down adjusts sound in smaller steps. The cited page does not specify a fractional ratio. **Official, high confidence.** [Mac keyboard shortcuts](https://support.apple.com/en-us/102650) | FineTune's configured normal step and a fine-modifier step are different concepts. Do not assume quarter steps or1/64 solely from this source. |
| Sound settings shortcut | Option with a volume key opens Sound settings; Apple explicitly includes any volume key. **Official, high confidence.** [Mac keyboard shortcuts](https://support.apple.com/en-us/102650) | Option alone needs its own route or correct pass-through; it should not be treated as an ordinary volume change when matching this shortcut. |
| Audible feedback | The Sound setting controls feedback when volume changes. Holding Shift while pressing a volume key temporarily reverses that setting. **Official, high confidence.** [Change the alert sounds](https://support.apple.com/en-eg/guide/mac-help/mchlp2207/mac) | Check Shift alone with feedback enabled and disabled. The cited text does not resolve every combined-modifier case, including Option+Shift. |
| Control Centre volume/mute | Apple's macOS27 guide describes dragging its Sound slider, dragging all the way down to mute, and clicking the volume level to toggle mute. **Official, high confidence.** [Adjust brightness and volume](https://support.apple.com/en-au/guide/mac-help/mchlgtd_bright01/27/mac/27) | This describes Control Centre. It does not establish that the compact keyboard-invoked HUD has the same pointer interactions or keyboard-zero mute semantics. |
| Menu-bar Sound control | Sound can be used in the menu bar or Control Centre. macOS27 offers Sound's menu-bar visibility always or only when active. **Official, high confidence.** [Turn volume up or down](https://support.apple.com/en-gb/guide/mac-help/mchl1f98810b/27/mac/27) | Test missing/hidden icons and live relocation. This page does not specify the compact OSD's anchor or fallback position. |
| Reduce Motion | AppKit exposes the setting and advises avoiding large motion, especially simulated depth, when enabled. HIG also recommends reducing scaling/bounce/peripheral motion and permits fades as alternatives. **Official, high confidence; general interface guidance.** [AppKit setting](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion), [HIG accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) | A custom animation must respond to the preference. These sources do not prescribe the native volume HUD's exact reduced-motion duration. |
| Transparency/contrast | AppKit says to avoid semitransparent backgrounds when Reduce Transparency is enabled. Apple's Liquid Glass guidance says settings can modify/remove effects and custom elements must be tested across configurations. **Official, high confidence.** [AppKit transparency](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducetransparency), [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) | Check Reduce Transparency and Increase Contrast explicitly. Using a system glass primitive does not by itself verify every custom foreground/background combination. |

## New expanded-interface lifecycle in macOS27

The public `expandedInterfaceDelegate` manages a custom interface beneath a status
item. Its documented callbacks show and dismiss that interface; an `NSMenu`
assigned to the item is handled automatically instead. The installed SDK marks
these APIs as available from macOS27.0. The SDK's protocol comment says this
lifecycle replaces manual target/action toggling for a custom expanded window,
participates in keyboard navigation/menu tracking, and requires cancelling the
session if the app independently closes the interface. These are lifecycle rules
for expanded status-item interfaces, not a complete volume-OSD specification.
[Delegate property](https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacedelegate),
[delegate protocol](https://developer.apple.com/documentation/appkit/nsstatusitemexpandedinterfacedelegate).

The status item exposes a readonly current session. It exists before the begin
callback and is cleared before the end callback. The reviewed public session
header exposes `cancel`; it does not expose an explicit method for starting a
keyboard-invoked OSD session. No such public OSD-start method was found in this
reviewed surface. This is a bounded finding, not proof that no other API exists.
[Session property](https://developer.apple.com/documentation/appkit/nsstatusitem/expandedinterfacesession).

Headers inspected locally:

- `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSStatusItem.h`
- `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers/NSStatusItemExpandedInterfaceSession.h`

## Highlight: documented API versus a reported macOS27 regression

`NSButton.highlight(_:)` documents changing a button's visual highlight; it does
not specify the volume-OSD capsule's animation curve, scale or timing.
[API documentation](https://developer.apple.com/documentation/appkit/nsbutton/highlight(_:)).

A developer's first-hand report, FB23330269, says programmatic
`NSStatusItem.button?.highlight(true)` no longer drew the capsule on macOS27
betas. The author describes `expandedInterfaceDelegate` as a partial workaround
for ordinary interaction and explicitly excludes programmatic OSD invocation
from that workaround. An Apple DTS engineer acknowledged the reports and added
the suggested workaround to the report. The last follow-up in August still
reported the programmatic limitation. This is credible primary runtime evidence
from the reporter, not an Apple guarantee about the installed macOS27.2 build.
[Forum discussion](https://developer.apple.com/forums/thread/836113).

Checking `NSCell.isHighlighted` only checks state. It cannot establish the
server-composed capsule's appearance or motion. For the user's reported symptom,
a composed visual observation remains necessary.

## Code-level comparison with FineTune

Read-only comparison in the implementation checkout found two gaps to documented
keyboard behavior. They have not been reproduced with physical input in this
research and should not be described as already confirmed end-to-end bugs:

1. `processSystemDefined` reads Shift/Option, but they reach `handle`'s feedback
   playback closure. `handleCore` always uses the configured
   `volumeHotkeyStep.sliderDelta`. There is no modifier-dependent fine-step route
   in that path. See [MediaKeyMonitor.swift](/Users/gustavo/Documents/Codex/2026-10-30/cha/work/finetune-implementation/FineTune/Audio/Keys/MediaKeyMonitor.swift:219),
   [step selection](/Users/gustavo/Documents/Codex/2026-10-30/cha/work/finetune-implementation/FineTune/Audio/Keys/MediaKeyMonitor.swift:291),
   and [event routing](/Users/gustavo/Documents/Codex/2026-10-30/cha/work/finetune-implementation/FineTune/Audio/Keys/MediaKeyMonitor.swift:441).
2. The same route contains no Option-alone Sound-settings action. It decodes and
   handles the media key and returns that it was consumed. This is a code-level
   mismatch to the documented Option shortcut, subject to physical event-flow
   verification on the target system.

Shift-alone feedback inversion is implemented. The combined Option+Shift branch
intentionally leaves the preference unchanged; the reviewed Apple feedback guide
only establishes Shift's ordinary shortcut, so the combined case still deserves
runtime comparison. See [VolumeFeedbackPlayer.swift](/Users/gustavo/Documents/Codex/2026-10-30/cha/work/finetune-implementation/FineTune/Audio/Feedback/VolumeFeedbackPlayer.swift:7).

The reviewed Preview4 snapshot chose a1100ms hide delay,120ms fade-in,110ms
fade-out, and80ms fades with Reduce Motion. Preview5 keeps the idle delay but
uses the supplied recording to select550ms/400ms capsule entry/exit and a
90→100% scale. See [measured follow-up](qa-hud-native-session-motion.md). It suppresses the system-volume HUD if the foreground
app is fullscreen or its popup is visible. It supports pointer drag/scroll and
hover keeping the HUD open, with an initial-stationary-cursor guard. These are
known application policies; **the public sources reviewed do not prove that they
match native keyboard-OSD behavior**. See
[HUDWindowController.swift](/Users/gustavo/Documents/Codex/2026-10-30/cha/work/finetune-implementation/FineTune/Views/HUD/HUDWindowController.swift:165)
and [CapsuleVolumeHUD.swift](/Users/gustavo/Documents/Codex/2026-10-30/cha/work/finetune-implementation/FineTune/Views/HUD/CapsuleVolumeHUD.swift:60).

## Details not resolved by public documentation

Bounded searches used Apple Developer/Support queries for volume HUD/OSD,
animation, duration, hover, fullscreen and keyboard-repeat behavior, alongside
the new status-item API surface. They did not find a normative specification for:

- precise compact-HUD size, anchor/fallback geometry, blur/refraction/tint or glyph;
- keyboard-triggered highlight scale/opacity, easing, spring or duration;
- volume-HUD hide delay, repeat-key delay/cadence and timer reset on repeated keys;
- whether pointer hover/drag/scroll expands or pins that compact HUD;
- whether an initially stationary pointer inside the future HUD bounds affects it;
- exact fullscreen/auto-hidden-menu-bar/Spaces/multi-display presentation policy;
- keyboard mute-versus-zero details or the first up/down step while already muted.

These items need reference recordings/runtime evidence on the installed build.
`NSWindow.StyleMask.hudWindow` and `NSVisualEffectView.Material.hudWindow` are
public panel/material concepts; their names do not identify a public controller
for the modern system volume OSD. [HUD style mask](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/hudwindow),
[visual-effect material](https://developer.apple.com/documentation/appkit/nsvisualeffectview/material-swift.enum/hudwindow).
No iOS/iPadOS HUD behavior was used as macOS evidence.

## Useful reference recordings

Keep the icon and compact HUD visible in the same recording. Include about1s
before invocation and let the exit finish. Prefer60fps if available. Record the
native macOS path separately from FineTune so two OSDs cannot obscure one another.

1. One volume-up press, then one down; repeated presses; a held key, released.
2. Mute and unmute; volume-down/up while muted; zero to first audible step.
3. Option alone, Option+Shift, and Shift alone with feedback initially on/off.
4. Pointer outside, already inside future HUD bounds, entering after appearance,
   then leaving; drag/scroll only if the native compact HUD accepts them.
5. A fullscreen app and auto-hidden menu bar, then another display/edge position.
6. Light/dark backgrounds, Reduce Motion, Reduce Transparency and Increase Contrast
   as separate cases when the user chooses to test those settings.

Measure first appearance, full highlight, timer reset, last key release, exit
start/end, focus changes and any geometry expansion. A screenshot can establish
one state; it cannot establish the transition or timing.
