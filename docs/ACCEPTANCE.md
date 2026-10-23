# Release acceptance

Automated checks:

- `swift run ReplayCoreChecks`: free-aspect rectangles, reverse/clamped drag, Retina mapping,
  second-display origins, UTF-8 filename limits, date parsing and collision safety.
- `QishengRecorder --self-test`: native AppKit drag sequence and Enter confirmation.
  Also checks keep-alive preference migration, move-only CGEvent construction,
  and unchanged paired mouse-down/up for actual clicks. No events are posted.
- `QishengRecorder --input-self-test`: five real HUD show/hide/restore cycles and
  same-process panel obstruction; requires an unlocked desktop without other
  floating windows at the fixture position. Does not capture or post input.
- `QishengRecorder --selector-test`: interactive, permission-free selector test;
  logs the display/source rectangle and exits without capturing or clicking a game.
- Worker unit tests: dates, no rows on a non-favorites screenshot, rejection of a
  nonmatching portrait, positive reference feature matching.
- `swift run ReplayCoreChecks` also drives the complete perspective coordinator
  against an interactive replay simulator: auto-closing and retained menus,
  automatic pause, dice/animation delays, disabled switch, missing frames,
  dropped Continue/close clicks, delayed playback, already-running playback, and
  another pause while waiting for readable headers.
  The menu label deliberately stays unchanged after switching. Continuous player
  header evidence must confirm the swap; unreadable/identical names stay unverified
  without another blind toggle. The 28 scenarios cover successful completion and
  safe waiting when evidence is unavailable. Own-side takes must emit no perspective input.
- `QishengRecorder --perspective-self-test` runs private captured images through
  production OCR, the bundled worker, and the same coordinator as recording.
  Set `QISHENG_PERSPECTIVE_FIXTURES` to a local fixture directory. The legacy
  `menu.png`/`paused.png` pair checks detection only. For sequence coverage, use
  `sequence.json` with `desired`, `requireFinished`, and `frames`; each frame has
  `image`, monotonically increasing `at` seconds, expected `menu`
  (`own`/`opponent` denotes the label's target, NOT the current side;
  otherwise `closed`/`unavailable`), `playback`
  (`running`/`paused`/`unknown`), and `action`
  (`wait`/`openMenu`/`switchView`/`closeMenu`/`resume`/`finished`).
  Optional `confirmed` asserts `own`/`opponent`/`unknown` independently of the menu.
  `requireFinished` requires confirmed headers, a closed menu and running playback;
  unverified continuation is not a fully confirmed pass.
  CLI debug builds can point `QISHENG_TEST_RESOURCES` to a built app's Resources
  directory. No window, login, recording, screenshot capture or input is created
  by this check. Keep real screenshots and traces private; a partial regression
  trace is explicitly not a complete live-game pass.
- `codesign --verify --deep --strict`: executable bundle consistency.

Interactive checks on a permitted Mac:

1. Launch the installed app from a fixed path. Both permission buttons lead to
   their system pages. Denied permissions show an actionable state, not success.
2. Choose a named display or follow the target window. Exactly one selector
   opens on that display without switching Spaces. Disconnect an explicitly
   selected display and verify an error rather than a silent fallback.
   Drag on each display in both directions. Release retains the rectangle;
   Enter confirms and Escape cancels. Underlying game buttons are not clicked.
3. Select a region that is not 16:9, with visible content at all four edges.
   Verify the preview contains every edge. Record ten seconds and verify the
   exported video contains the same boundaries and audible game sound.
4. Scan a favorites page, edit a name, record one replay. Check the edited name
   is in the filename and sidecar JSON. Repeat without overwriting the first take.
5. Test an incorrectly calibrated play button: the batch must stop when the
   favorites page remains. Confirm the failed attempt is preserved for diagnosis.
6. Stop a live recording from the menu bar and with Cmd+Shift+S. The MP4 must open.
   Quit while recording and verify file finalization before app exit.
7. Calibrate 2x on the correct visible button. Confirm speed changes during a
   replay; re-calibrate if browser/game UI scale changes.
8. Verify consecutive end detection, returning to the list, and advancing to the
   next selected row. Full replay behavior needs an actual game session.
9. Full-window mode: choose between two windows of the same browser. The chosen
   window, not merely the frontmost application, must be captured and clicked.
   Cover it with another app and confirm capture retains all four original edges.
10. Enable unattended mode; disconnect only the remote viewer, wait 5–10 minutes,
    reconnect and check continuous video/audio and replay transitions. Separately
    lock the desktop: the partial file must finalize and no more clicks may occur.
11. Confirm power assertions are held during recording only, and released on
    completion, error, Stop and app quit. Do not change persistent lock settings.
12. Drag the HUD, click Stop without activating it, and check it is absent from
    both window and region captures. Test another app's fullscreen Space.
13. Switch speed on/off: detect existing 2x without toggling it off, prioritize
    manually calibrated coordinates, and continue with a log when speed is
    unconfirmed. Missing recognition must not abort the batch or trigger a
    repeated click. Lock, real occlusion and capture failures still stop safely.
14. Update references while online, then offline. Keep old references/settings,
    avoid rewriting bundle resources, and retry failed downloads without duplicates.
15. With HUD enabled and unattended disabled, start a replay in region mode.
    Move the HUD over the next click location; it must hide before the click and
    return afterwards with Stop enabled. Repeat for speed and exit clicks.
    A real alert, another window of the same browser, another recorder panel,
    or a visible Dock icon must still prevent input at that point. A transparent
    Dock surface may be bypassed only when AX hit-testing confirms the exact
    selected window. Inspect failure logs for the window ID and hit-test result.
16. Cloud keep-alive: leave a replay running without physical input for longer
    than the service's observed inactivity timeout. Confirm repeated move logs,
    HUD count increments, no pause/speed/exit clicks and no cloud timeout dialog.
    This requires a real cloud session; unit tests alone do not prove it.
    Test disabled mode, 15/60/120-second settings, held mouse buttons, an obstructed
    point, temporary focus loss and cancellation. Stop must prevent further moves.
    A delayed loop must not replay missed intervals as a burst. Confirm macOS
    power assertions and cloud mouse activity remain independently implemented.

Permission-dependent checks must not be reported as passed merely because the
application builds. Record the tested environment and remaining checks in each
release's notes.

17. Standalone keep-alive: calibrate the selected Chrome/Safari tab without
    scanning favorites. Start, switch to another app and another tab, and verify
    periodic restoration of the exact calibrated tab with move-only input and
    no video files. Stop and wait beyond an interval; close the tab/window and
    lock the session separately. Verify termination, no input after Stop and
    mutual exclusion with recording. Check held mouse buttons defer the pulse.
18. Manual updater: check private GitHub login, no-network and cancellation;
    reject missing digests, corrupted archives, wrong bundle IDs and downgrades.
    Updates must be blocked while recording or keeping alive. Verify staged
    replacement, backup preservation, launch and rollback. Certificate-signed
    installations must also enforce their existing designated requirement.
19. Opponent perspective: start during dice, wait for the switch to become
    available, and confirm the game's automatic pause after switching. Continue
    must be clicked, the play triangle must become pause bars, and the actual
    match must advance. Check both auto-closing and retained-menu behavior.
    Confirm stable swapped player headers without switching back; the switch
    menu label may remain unchanged. Unreadable names must stay unverified,
    not trigger repeated toggles. Do not declare confirmed completion
    until the menu is closed and playback is running. Stop during each wait and
    verify the partial video is retained. Repeat an own-side take to confirm no
    perspective menu is opened. A simulator or saved-image pass does not replace
    this live check on the installed version.

`QishengRecorder --update-self-test` exercises temporary signed fixtures and
subprocess cancellation, not the user's actual installation or GitHub login.
