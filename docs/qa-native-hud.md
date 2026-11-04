> Alignment update: [qa-hud-alignment.md](qa-hud-alignment.md) supersedes the
> screen-corner placement described below. FineTune now follows its own status
> item, with native highlight, and prevents AppKit from adding a second menu-bar
> inset. The recovered BetterDisplay placement remains the no-anchor fallback.

# Capsule HUD: GlassOSD reconstruction and QA

Investigated on 2026-10-31 against BetterDisplay 5.2.1 (54014), arm64 slice of
`/Applications/BetterDisplay.app/Contents/MacOS/BetterDisplay`, SHA-256
`f0b874e4bbd0356dcc457be593aa31bc2d522fcde6d8f3fe9e0c49f2fa0cbca6`.
This implementation was written independently from recovered behavior and layout.
No BetterDisplay executable code or packaged assets are included.

## Findings and implementation

The earlier OSDManager experiment rendered a classic square on the user's Mac.
That backend is removed. The earlier custom capsule also placed a black fill
behind regular glass and clipped its effect. CapsuleVolumeHUD replaces that view.
The saved `tahoe` preference remains compatible; its picker label is Capsule.

| Question | Evidence / confidence | Implemented result |
| --- | --- | --- |
| Native material | Cached style, `0x100a33384`, REA `ev_ea09a224806238621bd5bdce611a06da62bec5a5cedf9dfd17d7ff949681ca87` | Resolve SwiftUICore's private Control Center Glass getter only for the observed 40-byte layout; retain loaded framework. Public clear/tint fallback for unsupported layouts/symbols. |
| Glass application | Body `0x100a4dfc4`, `ev_c15eaf065ee6b41501d304a0ffb8c533fb072f73e2c43bcfe34f65d58fd64af5` | Apply material directly to a continuous rounded rectangle. No opaque background or hand-painted rim in the normal modern path. |
| Geometry | Constructor `0x100a35a20`, `ev_c90541dda6cbcc1287c62423dd6a1386573ce789511f9a1725396fddf4b64bc7` | Visible capsule 308×65 pt, radius32.5, 40pt effect margin; panel388×145. |
| Row | `0x100a45e38`, `ev_683616f07fe15c0dbbd11d1c2af3d5f8317593e5f65f9aac25ae9d0a6cf0bd41` | Left22, glyph frame28 and font27 regular, gap12, track214, right32. |
| Track | Supplemental disassembly `0x100a529b8`, height at `0x100a53fa8`, opacity at `0x100a53f30` | Passive bar4pt, inactive opacity0.1. Sixteen segments; 1pt gap remains a visual estimate. |
| Foreground | Body `0x100a440a8`, `ev_640be26b29ff8ab576cdeb2e6fab2253c7f07a1b6773383a975bb6e692ae4165`; slider `0x100a52460`, `ev_731e1e5704e515abe55322c4a3d26f22abeb08563f41c0caac02d51c8ff85dc3` | BetterDisplay supports scheme-based black/white and a separate force-white presentation. FineTune selects white to match the user's supplied OSD references; material still inherits appearance. Mapping every BetterDisplay preference to these branches remains incomplete. |
| Panel appearance | Show `0x100a3a590`, `ev_0402b4ff92356cd8aca7f33a37f92f8f6133b8a59361ff8f1ab1234f166b6b3e`; appearance selectors `ev_ea4eff61c7ba7a138fe6881f9537e6c7bf0111c803370261e580503e04809af0`, `ev_7d2532ae199b80557d94206ebf2b743cb034c3e1c4d8dc4419cf661d646d98b5` | Transparent nonactivating NSPanel, no AppKit shadow, active/key *appearance* without key/main focus. Production level mainMenu−1 (23). |
| Placement | `0x100a582d4`, `ev_d8bbd885bbb46fdcd9a72c07249670a3292fde3c134634c15fdf17d1d3de10e8` | Screen frame top-right, account for status-bar/safe-area obstruction; capsule top inset max(40, obstruction+10). Per-app HUD keeps its existing usable-screen inset. |
| Interaction | Slider witness/type recovery, `ev_4279aa9ce803a07f0d77c777c0445ef9ce827b76e55da38ce2d97c0b64747205` and exported assembly | Rounded presentation is not inherently click-through. FineTune supports drag/scroll/accessibility adjustment. Transparent margins pass mouse input. Initial stationary pointer cannot pin the HUD open. |
| Close affordance | Content `ev_640be26b29ff8ab576cdeb2e6fab2253c7f07a1b6773383a975bb6e692ae4165` | BetterDisplay's rounded close button is invisible and accessibility-hidden. FineTune capsule has no hover X; named accessibility dismiss remains. |

The private getter is `$s7SwiftUI6_GlassV13controlCenterACvgZ`. Host smoke confirmed
Glass size/stride40, alignment8, symbol present and successful rendering. This is
an unsupported ABI boundary, isolated in HUDGlassMaterial; layout/symbol guards do
not guarantee compatibility with every future operating-system release. Older
macOS versions use the public NSVisualEffectView HUD material. Those fallback
paths have not been visually matched on separate operating-system installations.

## Compositor QA

A DEBUG-only lab enters before audio, media keys, CrashGuard or permission
services. It presents the production renderer above controlled solid/patterned
backgrounds and changes only its own windows' appearance. Release excludes the
lab and negative-control paths.

A selected-window screenshot strips backdrop contributions and cannot establish
blur correctness. The user explicitly authorized ScreenCaptureKit capture of only
the lab and HUD. The capture helper uses an inclusion filter containing these two
owned windows, verifies containment, and crops to the HUD's388×145pt envelope at2x.
It excludes other apps and saves window IDs, bounds and SHA-256 next to each PNG.
The lab alone lowers its HUD to layer0 for the selected-window provider; production
level23 is checked separately by controller tests. The images do not verify live
production z-order, Spaces or fullscreen behavior.

Twelve composed captures cover light/dark appearances × black, white, red, blue,
coarse detail and fine stripes. In the final white presentation, theme changes
leave the foreground white; the tested material's response to a given backdrop
is nearly the same across those two appearances.

- Live red→blue changes only the fixture, without calling HUD show again. Interior
  RGB delta is (−145,−14,+213), distance258.05 in byte RGB space.
- A deliberately opaque negative control produces interior delta(0,0,0), correctly
  failing the same backdrop-response condition.
- Fine-stripe horizontal contrast falls77.98% in dark appearance and77.85% in light
  appearance, measured outside vs inside the pill away from glyph/bar/rim. This
  establishes smoothing on this pattern, not a Gaussian blur radius or pixel
  equivalence to BetterDisplay.
- Mute is captured live; zero,7/16,full and mute content are also rendered in both
  appearances by tests. Offscreen images establish geometry/content only.

## Limits and next acceptance checks

The material, size, row and host-window behavior are substantially better grounded
than the previous preview. Exact BetterDisplay runtime equivalence is **not**
established: there was no side-by-side capture of both apps over the same live
fixture. Complete hover expansion geometry, all presentation flags, exact segment
gap and animation/easing/auto-hide behavior remain partially recovered. FineTune
retains its own1100ms delay and120/110ms fade rather than asserting those are
BetterDisplay's timings. Reduce Motion reduces fade durations.

White content loses contrast on a uniformly bright backdrop in the current native
material. The matrix exposes this explicitly; matching the reference's white
presentation is not a claim of universal contrast compliance. A previous
scheme-only black foreground was rejected because it becomes nearly invisible on
black backdrops. A further contrast treatment should be judged against actual
BetterDisplay behavior under identical conditions before claiming fidelity.
Reduce Transparency/Increase Contrast, HDR and other displays/scale factors,
production Spaces/fullscreen stacking, and the public fallback require additional
visual acceptance on those configurations. No global accessibility setting was
changed for this investigation.

## Public API context

Apple documents Liquid Glass as a dynamic material and its bounds-based
application: [custom views](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views),
[glassEffect](https://developer.apple.com/documentation/swiftui/view/glasseffect(_:in:)),
[Glass](https://developer.apple.com/documentation/swiftui/glass).
These docs do not document or guarantee the recovered Control Center getter.
The scoped capture uses [SCContentFilter(display:including:)](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(display:including:)).

Evidence exports, pseudocode, supplemental assembly, capture sources, original PNGs,
metrics, tests and build logs are delivered in the HUD Glass evidence archive.
No commit or GitHub publication was performed for this revision.
