# Device direction selector — Liquid Glass research

2026-11-02 (Australia/Brisbane). The user rejected Preview 17's blue native
segmented selection and requested a treatment closer to macOS 27 Liquid Glass.
A later Finder back/forward reference asks for a neutral translucent capsule,
subtle outline, divider and native press feedback. That reference is visual;
it is not evidence of Finder's internal implementation. No UI was launched,
no unrelated application inspected, and no app code changed for this research.

## Adoption guide and constrained recommendation

The user explicitly referenced Apple's **Adopting Liquid Glass → Controls**
section and its For You/Library segmented-control video. That section says to
rebuild standard controls with current Xcode and avoid hard-coded control layout
metrics so new shapes and sizes can be adopted. It also asks developers to review
control color, prefer standard spacing, and avoid crowding or layering glass.
It lists SwiftUI Picker and AppKit NSSegmentedControl among the affected controls.
The demonstration does not promise that every platform/style produces the same
segmented-control artwork or that a Picker matches Finder's private implementation.
[Adopting Liquid Glass — Controls](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass#Controls).

For this project, the **recommended next implementation** is deliberately small:
use `.pickerStyle(.tabs)` on macOS 27+, retain `.segmented` on older supported
systems, preserve the existing boolean binding and monochrome SF Symbols, and
remove the manually chosen font point size/control size so the native picker
can use its own metrics. Do not add a custom glass overlay, blue-fill replacement,
additional selection animation or `ControlGroup.navigation` around that picker.
This recommendation follows the newly found native tab API and the adoption
guide's standard-control guidance; it still requires a manual preview verdict.
No source implementation or appearance certification is implied by this note.
[TabsPickerStyle](https://developer.apple.com/documentation/swiftui/tabspickerstyle),
[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

## First native candidate: macOS 27 tab picker

**`PickerStyle.tabs` is a new public macOS 27+ option worth trying first.**
Apple explicitly distinguishes its macOS tab-navigation treatment from ordinary
segmented value selection; VoiceOver announces its options as tabs. Output/Input
switches the popup's related views, so this is a closer semantic match than a
pair of back/forward actions. The local SDK 27.2 public SwiftUI interface confirms
this API and its macOS 27 availability. The docs do not promise a particular
neutral color, capsule silhouette, divider, press animation or pixel-identical
Finder appearance. Its appearance still needs a manual preview review.
[TabsPickerStyle](https://developer.apple.com/documentation/swiftui/tabspickerstyle),
[PickerStyle.tabs](https://developer.apple.com/documentation/swiftui/pickerstyle/tabs).

Ordinary `SegmentedPickerStyle` only documents a segmented control presentation;
it does not promise the desired Liquid Glass navigation appearance. There is
no documented `PickerStyle.glass` in the sources consulted. Changing tint is
not a documented guarantee of the requested material or geometry.
[SegmentedPickerStyle](https://developer.apple.com/documentation/swiftui/segmentedpickerstyle).

## Finder-style grouping: native controls and semantic limits

`ControlGroup` groups semantically related controls using a context-appropriate
presentation. Its `.navigation` style is explicitly intended for back/forward
or timeline navigation and renders as a separated **momentary** segmented control
on macOS. `.automatic` is also documented as a context-dependent momentary
segmented presentation. Neither supplies persistent exclusive Output/Input
selection by itself. Use the reference's grouping language without inventing
back/forward semantics for device direction.
[ControlGroup](https://developer.apple.com/documentation/swiftui/controlgroup),
[navigation](https://developer.apple.com/documentation/swiftui/controlgroupstyle/navigation),
[automatic](https://developer.apple.com/documentation/swiftui/controlgroupstyle/automatic).

`ButtonStyle.glass` is public on macOS 26+ and applies contextual Liquid Glass
border artwork. Apple describes custom `.glassEffect(.regular.interactive())`
as providing the same responsive touch/pointer reactions as the standard glass
button style. Prefer these supported effects to hand-written brightness pulses
or fake blur. However, the documentation does **not** guarantee that adding
`.buttonStyle(.glass)` inside `ControlGroup` forces one shared capsule/divider;
context and group style can determine presentation. A native group is a
candidate to inspect, not a documented Finder clone.
[Glass button style](https://developer.apple.com/documentation/swiftui/primitivebuttonstyle/glass),
[GlassButtonStyle](https://developer.apple.com/documentation/swiftui/glassbuttonstyle),
[Applying Liquid Glass to custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views).

## Alternatives only if native tabs miss the requested appearance

The following is a **FineTune design proposal**, not an Apple-mandated recipe:

- One neutral capsule groups two equal symbol hit areas and a subtle center
  separator. Use semantic foreground/separator colors. Keep monochrome SF Symbols
  at consistent weight and scale. A filled selected variant and explicit selected
  trait can reinforce state without relying solely on a tint.
- Choose **one** glass treatment: either a shared `.regular.interactive()` glass
  capsule with a quiet non-glass selected fill, or one selected glass capsule
  moving over a subtle **non-glass** shared track. Do not stack a glass outer
  capsule and independent glass selection backgrounds merely to increase gloss.
- Keep hover visibly weaker/different from persistent selection. App state must
  remain a single exclusive boolean choice; a momentary press should not clear it.
- Preserve actual Button semantics, Output/Input accessibility labels, tooltips,
  keyboard focus and `.isSelected` on the chosen segment. Group the options without
  combining them into one inaccessible action. Visual similarity does not certify
  VoiceOver; verify the final native accessibility tree and speech.

The basis is HIG's guidance to group related choices, keep segment/content sizes
balanced and make selection visible, together with its advice to use Liquid Glass
sparingly for functional layers. The exact separator, dimensions, opacities and
transition duration remain product choices.
[Segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls),
[SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols),
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[isSelected](https://developer.apple.com/documentation/swiftui/accessibilitytraits/isselected),
[accessibilityAddTraits](https://developer.apple.com/documentation/swiftui/view/accessibilityaddtraits(_:)).

## Glass variant, shape and motion facts

`glassEffect(_:in:)` defaults to `.regular` in a Capsule and anchors its material
to the view's bounds, including padding. `.regular` blurs and adjusts background
luminosity for legibility. `.clear` is specifically intended for controls over
visually rich media; it is not simply a stronger or more modern glass setting.
For this compact popup header, neutral untinted regular glass is the conservative
candidate. This recommendation is context-specific, not a prohibition on clear.
[glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)),
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials).

`GlassEffectContainer` combines glass shapes and enables their interaction and
morphing. Container spacing determines when shapes begin merging; setting it
larger than the interior layout gap can merge shapes even at rest. For multiple
glass views, use a container rather than independent expensive effects.
`glassEffectID` associates effect identity for transitions;
`glassEffectTransition(.matchedGeometry)` coordinates effect rendering during
hierarchy changes. IDs must be unambiguous for simultaneously present shapes.
`glassEffectUnion` deliberately combines contributions into a shared material
shape; it is not a persistent selection API.
[Applying custom glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views),
[GlassEffectContainer](https://developer.apple.com/documentation/swiftui/glasseffectcontainer),
[glassEffectID](https://developer.apple.com/documentation/swiftui/view/glasseffectid(_:in:)),
[glassEffectTransition](https://developer.apple.com/documentation/swiftui/view/glasseffecttransition(_:)).

The older `matchedGeometryEffect` synchronizes frames; Apple explicitly states
that it does not itself define rendering. Do not describe it as reproducing
native glass refraction. One continuous offset highlight can be simpler than a
morphing pair; choose one geometry owner and avoid competing animation drivers.
The latter is implementation guidance, not a separate HIG requirement.
[matchedGeometryEffect](https://developer.apple.com/documentation/swiftui/view/matchedgeometryeffect(id:in:properties:anchor:issource:)).

## Accessibility and compatibility

Use primary/secondary semantic colors and check light, dark and Increase Contrast.
Read `colorSchemeContrast` for the current contrast preference. Do not infer that
an untinted translucent design is automatically readable on every background.
[Color](https://developer.apple.com/design/human-interface-guidelines/color),
[Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility),
[colorSchemeContrast](https://developer.apple.com/documentation/swiftui/environmentvalues/colorschemecontrast).

System glass variants respond to transparency/contrast settings. If a custom
track or selection uses additional translucency, explicitly consider
`accessibilityReduceTransparency`; an opaque semantic fallback can preserve
legibility. For Reduce Motion, skip custom sliding/morphing and preserve a clear
static selected state. `accessibilityReduceMotion` communicates that preference;
GlassEffectTransition.identity specifies no transition changes. Neither HIG nor
these APIs mandate removing all opacity feedback or fixed numerical timings.
[Materials](https://developer.apple.com/design/human-interface-guidelines/materials),
[Reduce Transparency](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducetransparency),
[Reduce Motion](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityreducemotion),
[Identity glass transition](https://developer.apple.com/documentation/swiftui/glasseffecttransition/identity),
[Motion](https://developer.apple.com/design/human-interface-guidelines/motion).

Guard `.tabs` for macOS 27+ and Liquid Glass APIs for macOS 26+. Earlier systems
can retain a plain semantic capsule/selection or the existing supported segmented
control; there is no need to fake liquid optics with nested blur. Do not use
private Finder/Control Center APIs. The application minimum remains a separate
compatibility constraint.
[TabsPickerStyle availability](https://developer.apple.com/documentation/swiftui/tabspickerstyle),
[Glass availability](https://developer.apple.com/documentation/swiftui/glass).

## Validation boundary

A compile or hidden structural probe can verify API availability, state updates,
images and native hierarchy. It cannot certify the compositor's blur/refraction,
Finder similarity, pointer press motion or VoiceOver speech. Review the manual
preview in both appearance modes, with quick reversals and keyboard navigation,
plus Reduce Motion/Transparency and Increase Contrast. Keep the already accepted
Other Outputs motion unchanged. No visible lab, automatic app launch, release or
merge belongs to this investigation.


## Implemented candidate and local evidence

The follow-up uses the recommendation above: a macOS 27 availability branch
applies `.tabs` to the existing Picker, and older systems use `.segmented`.
The explicit 14 pt font and forced regular control size are removed; monochrome
SF Symbols, equal medium scale, native labeling and the existing selection
binding are retained. No custom glass, divider, tint, spring or shader is added.
The accepted Other Outputs handler is unchanged.

Run 20261102-031543-903657 passed 12 existing compact-output/browser/editor/offline
tests, zero failed/skipped. Optimized arm64 Release passed. A hidden structural
probe extracted the actual header with the animation token set to nil only
for inspection. Both selected directions under both appearance preferences
resolved to two native segments with nonempty symbol images and correct
selection; intrinsic header-plus-padding size was 89×48 pt. Every panel remained
unordered. This checks structure and state, not appearance, press feedback,
VoiceOver speech or light/dark compositor rendering. The new macOS 27 candidate
remains subject to manual visual acceptance.
