# HUD mute/unmute level restoration

Physical Preview5 QA on2026-10-31 showed correct audible mute/unmute but an empty track and zero-level speaker after unmute. The software backend publishes gain0 when muted and restores the saved gain synchronously when unmuted. MediaKeyMonitor captured the gain before calling setMute and sent that old zero to the HUD.

The mute-toggle path now reads the resulting cached device volume after unmute, then converts it through the existing tier-specific mapping. The read is supplied to handleCore by the real handle entry point. No extra HAL read, sound level change, volume-up/down policy change, or view/material change is involved.

HUDMuteRestoreTests drives handle(.muteToggle) through a software-backend adapter with the same zero/save/restore contract and renders the actual controller root via ImageRenderer. It checks that mute empties the track and unmute paints the same track as before, while the restored backend gain is0.25. Hardware/DDC adapters retain their scalar and are checked too. This is an integration/render regression, not physical hardware certification.

Red:20261031-210907-000264; software case failed the rendered track equality, while hardware/DDC cases passed. Green full run:20261031-210955-558727;1006 tests passed,0 failed/skipped. Release arm64 built successfully. Physical verification of Preview6 remains pending user confirmation.
