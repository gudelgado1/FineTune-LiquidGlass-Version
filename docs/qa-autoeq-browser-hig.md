# AutoEQ Browse — Apple HIG research

Date: 2026-11-01 (Australia/Brisbane). Scope: official Apple design guidance and API documentation for rebuilding the AutoEQ profile chooser. This research does not certify an implementation or prescribe an exact blur, corner radius, or layout.

## Guidance and its application

| Area | Primary guidance | Application to FineTune |
| --- | --- | --- |
| Search entry and scope | Use a recognizable search field, explain its scope, refine useful results as typing proceeds, and keep relevant results easy to find. Dedicated discovery areas can focus search on entry. [Searching](https://developer.apple.com/design/human-interface-guidelines/searching), [Search fields](https://developer.apple.com/design/human-interface-guidelines/search-fields) | “Search headphone profiles” makes the collection clear. Browse can reveal an inline search area and move focus there. Favorites/imported profiles can make the initial state useful. Inline placement and these categories are proposed choices, not HIG requirements. |
| Results | Lists suit scannable text. Keep labels concise and distinguish an option’s chosen state from temporary interaction feedback; a checkmark can identify the chosen option. [Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables) | Use readable profile names plus brief source/measurement metadata. Track keyboard highlight separately from the applied profile. Keep favorite and apply actions distinguishable. |
| Presentation | Avoid cascaded popovers and make changing popover size visually continuous. [Popovers](https://developer.apple.com/design/human-interface-guidelines/popovers) | An inline browser avoids another floating chooser and duplicate Correction/Preamp controls. FineTune’s main window is a custom panel: this guidance is not an `NSPopover` API prohibition, nor proof that every child window is incorrect. |
| Loading and absence | Show activity appropriately; report known progress honestly and explain a stalled task and available action. A search with zero matches deserves a purposeful no-results state. [Progress indicators](https://developer.apple.com/design/human-interface-guidelines/progress-indicators), [Design intuitive search experiences](https://developer.apple.com/videos/play/wwdc2026/292/) | Distinguish idle, catalog loading, results, zero matches, and failure. An unloaded/failed catalog must not be described as a completed search with no matches. Query preservation and an inline retry are proposed recovery behavior. |
| Material hierarchy | Standard materials organize content; use Liquid Glass selectively for functional controls/navigation and choose variants for legibility. [Materials](https://developer.apple.com/design/human-interface-guidelines/materials) | Keep result content a legible content surface inside the existing panel. Avoid adding another glass sheet around every row or reproducing desktop colors with fixed fills. Existing outer glass need not be replaced solely to modernize Browse. |
| Accessibility and motion | Use semantic colors, test contrast in light/dark appearances, label controls and support keyboard-only operation. Keep custom motion brief, purposeful and interruptible. [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), [Motion](https://developer.apple.com/design/human-interface-guidelines/motion) | Label search, clear, favorite, import and close actions. Test actual focus order and VoiceOver names. Reduce/replace expansion effects when appropriate for the system motion setting; do not communicate state only through animation. |

## API facts, separate from design recommendations

- `NSSearchField` supplies native search-oriented input and search/cancel controls. Its `sendsSearchStringImmediately` property controls action timing; delayed delivery can reduce work while typing. These APIs do not themselves cancel application requests or reject stale asynchronous results. [NSSearchField](https://developer.apple.com/documentation/appkit/nssearchfield), [sendsSearchStringImmediately](https://developer.apple.com/documentation/appkit/nssearchfield/sendssearchstringimmediately)
- SwiftUI’s programmatically presented `searchable` interface focuses/unfocuses search as presentation changes on macOS. Search presentation and text focus are distinct states, and `onSubmit(of: .search)` handles submission. This does not guarantee correct behavior in FineTune’s custom panel, root key handlers, or an arbitrary wrapped text field. [Managing search interface activation](https://developer.apple.com/documentation/swiftui/managing-search-interface-activation)

## Proposed interaction contract to verify

Browse reveals one inline browser for the device. Correction and Preamp keep one authoritative control each on the device card. Empty-query discovery can show saved/favorite profiles; typed queries show matching profiles. Clear retains the browser. Selection applies the intended profile; closing/canceling without selecting preserves the prior profile.

Verify arrows move only the result highlight, Return applies the highlighted result, and Esc closes the browser without dismissing the whole FineTune popup. These exact key semantics are the proposed product contract, not a quoted HIG rule. Test with the real root keyboard handlers and text-field editor; a standalone field cannot prove that integration.

Acceptance also needs bounded scrolling/window resizing, long names, zero results, offline/retry, rapid query changes, selection during refresh, favorite toggling, import through the system file picker, and light/dark appearance. Check Reduce Transparency, Increase Contrast and Reduce Motion separately. Existing QA of EQ presets does not automatically certify these new browser paths.

## Implemented and verified in this checkpoint

The browser replaces the curve/details area inside `AutoEQExpandedPanel`; no
secondary window is created for Browse. The native search field supplies search
and clear affordances. Empty search shows favorites and local profiles; typed
search keeps the manager’s relevance order instead of lifting approximate
favorites above exact results. The current profile has a checkmark, independent
of keyboard highlight. Each result has a separate labeled favorite button.

A small request owner rejects canceled/superseded asynchronous selections,
including resolvers that finish after cancellation. The popup delegates Escape
to its current inline editor before dismissing itself and disables volume-row
keyboard navigation while the browser is active. Losing the popup’s key window
also cancels/dismisses the editor. The catalog retains cached entries on network
failure and exits the loading state with a retry affordance.

Local isolated test run `20261101-195949-846949`: **1026 passed, zero failed or
skipped**. Six new cases cover late completion after close, supersession,
failure/retry, one-shot Escape ownership, stale editor teardown and a real
URLSession offline refresh with cached entries. Release arm64 also builds.

An isolated native laboratory compiled the actual browser/expanded-panel source,
without audio capture, using synthetic imported and cached profiles. Computer
Use verified light/dark appearance, bounded list rows, long-name truncation with
full accessibility labels/tooltips, search, zero results, native clear, favorites,
arrow/Return selection, Escape preserving the selected profile and the containing
window, and the import callback returning to the correction area. Screenshots
and source hashes remain in the local QA evidence folder.

Limits: this lab does not prove full production root focus/height/close behavior
or a live file import/network download. Retest the new preview in the real menu
bar popup. VoiceOver navigation and system Increase Contrast/Reduce Transparency
settings have not been physically certified for this browser. Reduce Motion is
respected in the browser transitions and keyboard scroll animation. Existing
Preview 10 audio/blur acceptance remains evidence for that version, not automatic
acceptance of this new presentation.

## Preview 11 visual regression: nested material

The user reported functional behavior but supplied a recording showing the
background becoming much sharper when Browse opened, with old controls visible
during the transition. The original fixed-window lab did not exercise the real
transparent popup and its content-driven resizing; its visual pass was insufficient.

A second, audio-free fixture used the actual `FluidMenuBarExtraWindow`,
`RootViewModifier`, `ExpandableGlassRow`, expanded panel and browser over a
synthetic black/white text backdrop. Explicitly filtered ScreenCaptureKit captures
included only its owned backdrop and probe. An unchanged header patch at
(370,25)–(575,100) pixels measured horizontal + vertical mean grayscale differences.
The local `check-blur.py BEFORE AFTER` loop rejects an increase above 1.5×. It
failed on the original behavior: 0.900238 → 5.146934 (**5.7173×**); same-image
negative control passed at 1×. This is a bounded legibility regression signal,
not a universal glass metric or pixel-identity contract.

One-variable probes disabling native window animation, SwiftUI Browse animation,
and native search autofocus each retained the same 5.7173× failure. Removing only
the browser’s `.regularMaterial` wrapper passed at 0.9777×. The production fix
removes that wrapper: the device row already supplies the content surface, while
the main popup remains the backdrop owner. No fixed blur radius or private glass
API was introduced. This establishes the wrapper as the trigger in this fixture;
it does not establish the compositor’s undocumented internal mechanism.

The actual corrected source, without component probe overrides, passed still
captures in light (0.3332× after opening, 1.0000× after returning) and dark
(0.1850× after opening). The material need not look pixel-identical as the panel
changes height; the observed unwanted gain in background detail is eliminated.
A separate temporal capture lost the probe after resizing and was excluded from
acceptance evidence. Full motion/ghosting still requires the real-popup retest.

Targeted isolated run `20261101-202416-147639`: six browser/editor/offline cases
passed. The earlier 1026-case CI at `161abb1` passed and its artifact/tree were
verified before this material fix; do not label that run as testing this fix.
The compositor regression is covered by the local owned-lab capture loop, not a
unit test pretending to verify GPU output. Preview 12 physical acceptance remains
pending. Release publication was explicitly deferred by the user.
