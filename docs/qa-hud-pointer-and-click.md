# HUD pointer presentation and status-item click

Date:2026-11-01, Australia/Brisbane. Reference: user recording from2026-10-31 at21:18:10; identity retained in work/hud-native-click-reference/source.json.

The recording shows16 segments at rest, a continuous4pt track and approximately18×14pt white thumb while the pointer is inside, and a larger glass thumb during drag. The visible capsule does not resize. Preview7 implements this presentation, with an180ms hover transition and120ms pressed-thumb transition, disabled under Reduce Motion. These durations and the pressed-thumb glass are reconstructions; exact native transition timing/refraction has not been established. The existing308×65pt capsule, material, placement and mute-restore behavior remain intact.

A drag holds the HUD even outside the capsule, keeps mouse input enabled, and restarts auto-dismiss after release outside. Release inside retains the interactive presentation. Drag values bypass the150ms keyboard-level animation, including when model feedback clears the temporary local value. The final drag location resolves hover against the rounded capsule because pointer capture/synthetic input can omit hover events during the drag.

## First-click regression

The physical report was that one click dismissed the HUD and only a second click opened the popup. The previous lab set observesOutsideClicks=false and therefore did not certify that chain.

The regression now calls the same HUD and Fluid local handlers used by the monitors, with the HUD handler first and Fluid first. The original HUD handler dismissed every other window, including its own status button, so Fluid could no longer see a HUD to promote. The red run20261101-020316-219899 failed popup ownership and visibility in0.267s. The handler now leaves its own status-item event to Fluid, which consumes that promotion click. The extracted weak monitor wrapper explicitly preserves nil (consumed); this is a refactoring safeguard, not a separate defect attributed to Preview6.

On macOS27 the status item can be hosted remotely and the click can reach a global monitor. That route checks the exact own-item rectangle and only ordinary left clicks request a popup. A dedicated status-click handoff reserves popup ownership before retiring the old native expanded session; didEnd can then rearm without closing the newly requested popup. A visible fading capsule remains eligible for promotion if native cancellation arrived first. Other clicks dismiss the HUD normally; Command/Control/right clicks do not request a popup through this route. No mouse event is synthesized or reposted by this fix.

## Validation and limits

Final native run20261101-023415-920802:1017 passed,0 failed/skipped. Release arm64 build succeeded. Regressions cover local ordering, remote event routing and modifier/outside exclusions, old native-session cancellation, hover track rendering, endpoints, drag holding/release, and rounded release geometry. Remote rectangles are supplied explicitly in the inert host because its status windows are not an active menu bar. Those tests do not claim physical menu-server event delivery.

The scoped layer-zero lab capture confirmed the segmented rest renderer and actual drag changing its displayed level. Pointer/drag captures include only owned fixture/HUD windows. A final physical icon click in Preview7 remains pending: CUA can operate the lab window but did not reach its remote menu-bar item. No AppKit session callback, unit state flag, or synthetic click was counted as physical success. The running /Applications/FineTune.app was not terminated or replaced.

Preview7 is an ad-hoc signed local candidate, not notarized. No commit, push or PR was made in this stage.

## Endpoint icon feedback

Glyph crops from the supplied recording show the maximum-volume symbol grow from about68×48 to79×60 pixels, then undershoot to64×44 and return, over approximately0.6s. The zero/muted symbol similarly changes from46×47 to58×59 and returns. The bar approaches its endpoint while this happens; without key-event timestamps the recording does not establish behavior for every subsequent clamped repeat.

The image now uses Apple's public SF Symbols bounce.up.byLayer effect on endpoint arrivals. Remaining at the same bound does not restart it repeatedly. Middle-volume changes do not request it; a muted maximum is excluded, and Reduce Motion removes the effect. This is a supported effect consistent with the observation, not proof of the exact internal Apple implementation. See https://developer.apple.com/documentation/symbols/bouncesymboleffect . The animation changes only presentation; no volume/mute/audio-engine policy was changed.
