# Popup motion — Apple HIG research

2026-11-02 (Australia/Brisbane). The user asks for softer effects because the
compact popup feels abrupt. This note records design guidance and API facts;
it does not certify an implementation or a visual result. No UI was launched.

## Recommendations

1. **Soften geometry without delaying the action.** Use brief, coherent motion
   for expansion/collapse and retain an understandable spatial relationship.
   HIG favors purposeful feedback, short precise animations, and interaction
   without waiting for motion to finish. Repeated volume operations should keep
   direct feedback instead of accumulating decorative animation.
   [Motion](https://developer.apple.com/design/human-interface-guidelines/motion).

2. **Animate the panel’s size change deliberately.** HIG specifically recommends
   a smooth transition between condensed and expanded popover content. For this
   custom panel, choose a bounded resize pace and keep its menu-bar anchor stable.
   This is an application of the guidance, not a requirement to replace the panel
   with NSPopover. [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers).

3. **Prefer a restrained spring for disclosure feedback.** SwiftUI’s `smooth`
   animation has no base bounce and supports a perceptual duration parameter.
   Subtle chevron/hover feedback can feel less abrupt without adding repeated
   overshoot. Candidate values such as 0.24–0.28 s for disclosure and 0.16–0.18 s
   for hover are FineTune tuning proposals, **not HIG-prescribed timings**.
   [smooth](https://developer.apple.com/documentation/swiftui/animation/smooth),
   [smooth(duration:extraBounce:)](https://developer.apple.com/documentation/swiftui/animation/smooth(duration:extrabounce:)).

4. **Respect Reduce Motion in both rendering frameworks.** SwiftUI exposes the
   system preference through `accessibilityReduceMotion`. AppKit exposes it via
   `NSWorkspace.accessibilityDisplayShouldReduceMotion` and documents change
   notifications. Avoid large geometric/3D effects when enabled. Choosing an
   immediate resize and static disclosure state is a valid FineTune policy;
   Apple does not require eliminating every small opacity change.
   [SwiftUI preference](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion),
   [AppKit preference](https://developer.apple.com/documentation/appkit/nsworkspace/accessibilitydisplayshouldreducemotion).

5. **Keep the native search-field boundary protected.** The prior white flash
   and outgoing-curve overlap are observations from FineTune’s recordings, not
   documented universal AppKit behavior. Keep the identity content swap there;
   soften surrounding geometry/hover rather than restoring a cross-fade between
   the white graph and the bridged native field. Do not apply opacity or scale
   indiscriminately to the whole glass/window tree. This is a project-specific
   recommendation informed by that regression, not an additional HIG rule.

6. **Validate rapid reversals and keyboard use.** The interface should accept a
   second disclosure, Escape or selection during motion. Check for obsolete
   queued size changes, focus loss, clipping and renewed white flashes. Test
   default and reduced motion. A chosen animation API is not itself proof that
   the complete AppKit/SwiftUI interaction is interruptible or visually correct.
   [Motion](https://developer.apple.com/design/human-interface-guidelines/motion).

## AppKit resize API facts

`NSWindow.setFrame(_:display:animate:)` uses `animationResizeTime(_:)` for an
animated frame change. Subclasses may override the latter to control duration.
Apple documents a default based on `NSWindowResizeTime`, approximately 0.20 s
per 150 pixels when unset, and explicitly says the default can vary by release.
Therefore a particular observed resize pace is neither a universal HIG timing
nor a promise of stable duration across different height deltas.

[setFrame(_:display:animate:)](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:animate:)),
[animationResizeTime(_:)](https://developer.apple.com/documentation/appkit/nswindow/animationresizetime(_:)).

## Validation boundary

Code/policy tests can check chosen timing and reduced-motion decisions. They
cannot certify perceived smoothness, compositor behavior, native-field flashes
or input responsiveness. Manual preview review remains necessary; no visible
laboratory overlay or automatic preview launch is authorized for this work.

## Implementation candidate

- Panel resize uses a bounded 0.30 s AppKit animation rather than a
  distance-dependent default. Hidden panels are positioned without animation.
- A newly opened popup fades in for 0.18 s; dismissal fades for 0.22 s. Reopening
  a still-visible dismissing panel restores it immediately, retaining the
  generation guard against stale dismissal completions.
- Shared hover feedback changes from 0.12 s ease-out to 0.18 s ease-in-out.
  Existing consumers outside the popup receive this small timing change too.
- Popup disclosures use a 0.30 s `smooth` spring, with no extra bounce. The
  Other Outputs initially animated only its chevron; the user reported the
  missing list effect in Preview 15. The follow-up wraps the shared disclosure
  mutation in the same animation and fades entering/leaving rows. AppKit still
  owns the outer panel frame. Keyboard order updates synchronously, and click,
  Shift-Command-O, Escape and route-change collapse use the shared handler.
- Removed the app EQ's 0.4 s input lock so another click can reverse the action.
- Reduced Motion skips the panel fades, resizing, disclosure and hover motion;
  expandable rows also remove their scale/opacity transition through the live
  SwiftUI environment preference. VU meters, volume and audio callbacks retain
  their existing immediate behavior.
- AutoEQ graph/browser identity swaps remain unchanged. No nested material or
  graph/search cross-fade was added.

All timings above are FineTune choices for review, not Apple-mandated values.
Two native lifecycle cases cover reopening during appearance and dismissal;
run those on CI, not as visible windows on the user's desktop. Perceived motion,
rapid disclosure/escape, search flash and Reduce Motion still require a manual
preview check. No automatic preview launch or release is part of this change.


### Other Outputs follow-up validation

Preview 15 feedback: the list lacked the effect even though the chevron moved.
The handler had no animated transaction. Added it at the existing shared action
seam and explicit opacity transitions for inserted/removed rows; no global
animation modifier or separate resize driver was added. This small visual
change reuses the presentation/navigation tests rather than adding a test that
only asserts the chosen animation constant. Its perceived smoothness, clipping,
rapid reversal and expanded AutoEQ teardown need manual Preview 16 acceptance.
No visible reproduction or compositor capture was run on the user's desktop.
