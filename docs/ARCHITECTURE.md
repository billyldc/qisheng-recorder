# Architecture

The native application handles recording, selection and replay control directly.
It does not require OBS or Hammerspoon.

## Capture and coordinates

`RegionSelector` uses one nonactivating AppKit `NSPanel` / `NSView` on an explicitly
chosen display, or the display with the largest overlap with the target window.
It does not activate the recorder application or open overlays on other displays.
The view accepts the first mouse event and receives `mouseDown`, `mouseDragged`,
`mouseUp` normally. Selection is free-aspect and remains editable until Enter;
Escape cancels. Selecting does not need Accessibility or an event tap.

Selection coordinates are local AppKit points with a bottom-left origin.
`RegionGeometry.sourceRect` converts them to top-left display-local points for
ScreenCaptureKit. `sourceRect` is always points, regardless of Retina pixel size.
Output dimensions are even numbers, scaled from the rectangle up to 1080 pixels
high; no source pixels are discarded to make the output 16:9.

`ScreenRecorder` uses `SCStream` and `SCRecordingOutput` on macOS 15+. Screen
and optional two-channel 48 kHz system audio go to one MP4. The recorder excludes
its own application windows and audio. It waits for the recording delegate to
start before clicking and waits for file finalization when stopping or quitting.
Full-window mode binds a window ID and owner PID, uses a desktop-independent
window filter without shadows, and resolves current coordinates before input.
Window movement can be followed; resizing invalidates the selection. The HUD
uses a nonactivating panel and is absent from both capture filters.

## Metadata

Vision recognizes Chinese text within the selected screenshot. An isolated
bundled Python worker uses OpenCV Hough circles to locate card portraits and
play controls. It compares SIFT features against attributed standard GCG card
art, requiring RANSAC spatial consistency, unique matches and a winner margin.
Portrait crops are normalized to 160 pixels before feature extraction; missing
matches retry at 224 pixels, then native size. Ambiguous candidates remain
unknown rather than being resolved by a different resize.
It does not label a portrait based only on the nearest visual candidate.
Every candidate with card art must also pass independent, geometrically aligned
pixel correlation with at least 80% valid inner-circle coverage. High-inlier
matches with repeated-texture outliers retain their additional spatial-coverage
requirements. Team aliases and past filenames are never used to infer a role.
Speed controls use a paired pause/fast-forward glyph check,
including highlight polarity, instead of assuming a screen-specific position.

The worker returns editable replay rows. Unknown portraits use `未识别`.
Temporary PNG/OCR files live in a UUID-scoped temporary directory and are
deleted after the worker finishes. Recognition is offline. Only an explicit
reference update fetches the public catalog and new PNGs; resources are appended
in Application Support, not the signed bundle. Old references remain available.

## Automation

The selected replay queue is copied at start, so editing the UI cannot change an
active batch. Native CGEvent clicks require Accessibility and use the capture
display's global top-left origin. Each replay is checked against the favorites
date before clicking; a persistent favorites list after loading is an error.

End detection begins after 60 seconds and requires an end banner and
`退出观看` (or calibrated fallback exit) for three successive checks. A timeout,
recording failure, changed bounds, closed/minimized window or locked session stops
the batch. Region capture stops on focus loss; window capture has a 15-second
grace period, or permits continued loss of focus in explicit unattended mode.
Before a click, the exact window and unobstructed point must be confirmed. On Stop,
the automation task is cancelled, the MP4 is finalized, and the fragment remains
available. No automatic post-recording crop or in-place transcoding runs.
Worker cancellation is separate from file finalization; finalization runs in an
uncancelled task. Temporary IOKit power assertions cover recording only, never
override direct screen lock, and are released on every completion path.

Speed and fallback exit calibration are stored per target app, capture mode,
display and selected size. Old native profiles remain associated with their
original target application.

## Privacy and packaging

App-owned screen recording and Accessibility checks appear in the setup form.
TCC grants require user interaction; a program cannot pre-approve them.
Microphone, camera, AppleScript Automation and Input Monitoring are not requested.
Carbon global hotkeys show the window and stop recording without an event tap.

The Swift executable uses system frameworks. PyInstaller bundles the worker,
Python runtime and its dependencies into Resources. The application is signed
as a bundle after assembly. No credentials are included. Recording content and
local settings are excluded from git.
