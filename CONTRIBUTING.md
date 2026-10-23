# Contributing

## Build and test

Use macOS 15+, Xcode command line tools, and Homebrew Python 3.14, matching CI. Run
`bash scripts/build_app.sh`, then `.build-tools/bin/python -m unittest discover -s worker/tests -v`.
The build creates a separate app in the build cache, not in Applications; it does
not install, request recording permissions, or change an existing installation.

The default build is ad-hoc signed. It does not discover a personal certificate
or read a signing keychain. For an explicitly chosen identity, set
`CODESIGN_IDENTITY`. For repeatable local signing, optionally run
`python3 scripts/local_signing.py setup` once, then build with `USE_LOCAL_SIGNING=1`.
It creates an app-specific keychain and certificate, then requests user-domain
code-signing trust constrained to `/usr/bin/codesign`. It does not add HTTPS trust
or change the system certificate store. The keychain password is kept in the
login keychain; the private key is never written into the repository or exported
by this helper. Only explicitly opted-in builds reuse this identity.
Do not delete or regenerate it between releases. A different signing identity
requires a new macOS permission migration. Test permission inheritance across
installed versions; a matching designated requirement alone is not an acceptance
test. CI without this identity still builds ad-hoc development artifacts.

Run `swift run ReplayCoreChecks`, the worker unit tests, and the full app build before
submitting a change. AppKit selection input, ScreenCaptureKit capture and replay
clicking must use the same selected-display coordinate system. Add a regression
case when changing coordinate conversion or filename generation.

Use `docs/ACCEPTANCE.md` for manual recording checks. Do not replace manual
verification of video borders and audible sound with a syntax-only check.

Keep screenshots, recordings, build products, signing keys, local app settings
and OBS credentials out of commits. Assets have separate copyright ownership;
keep their attribution and do not describe game art as MIT-licensed.

For releases: update the app plist/version text, run the build and package
scripts, review the file manifest and checksums, then attach the install packages
to a GitHub release. A Developer ID identity and notarization are needed for
normal notarized distribution. CI artifacts are ad-hoc development builds, not
notarized releases and not a replacement for a consistently signed update.

## Private fixtures and independent releases

The distributed tests use synthetic screens and public game reference art.
Optional real portrait tests require a locally supplied directory through
`QISHENG_PRIVATE_PORTRAIT_FIXTURES`; they are explicitly skipped when it is absent.
Never add those screenshots or their manifests to this repository.

Before committing, run `python3 scripts/privacy_audit.py --tree .`; after committing,
run `python3 scripts/privacy_audit.py .`. Build and packaging also scan the app,
including the frozen Python archive. These checks complement, not replace, a
manual privacy review. See [release process](docs/RELEASING.md) for independent
source imports, signing, testing and the limits of the current candidate.
