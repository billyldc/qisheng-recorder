#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PYTHON="${PYTHON:-python3}"
if [[ ! -x .build-tools/bin/python ]]; then
  "$PYTHON" -m venv .build-tools
fi
.build-tools/bin/python -m pip install --index-url https://pypi.org/simple -r worker/requirements.txt
if [[ ! -f Assets/names.json ]]; then
  .build-tools/bin/python scripts/prepare_assets.py
fi
swift run ReplayCoreChecks
swift build -c release -Xswiftc -debug-prefix-map -Xswiftc "$ROOT=/QishengRecorder" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=/QishengRecorder"
.build-tools/bin/pyinstaller --noconfirm --clean --onedir --name portrait-worker \
  --distpath .build/worker-dist --workpath .build/worker-build --specpath .build \
  --copy-metadata numpy --copy-metadata opencv-python-headless --copy-metadata certifi \
  worker/recognize.py
APP_BASE="${APP_BUILD_DIR:-$HOME/Library/Caches/QishengRecorder/build}"
APP="$APP_BASE/Qisheng Recorder.app"
# Replace only the build artifact, never a user's installed application.
if [[ -d "$APP" ]]; then mv "$APP" "$APP_BASE/previous-app-$(date +%s).app"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/QishengRecorder "$APP/Contents/MacOS/QishengRecorder"
# Local release builds must not ship debugger object paths containing usernames.
/usr/bin/strip -S "$APP/Contents/MacOS/QishengRecorder"
cp packaging/Info.plist "$APP/Contents/Info.plist"
ditto --norsrc --noextattr .build/worker-dist/portrait-worker "$APP/Contents/Resources/portrait-worker"
ditto --norsrc --noextattr Assets "$APP/Contents/Resources/Assets"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
PYTHON_LICENSE="$(.build-tools/bin/python -c 'import sysconfig; print(sysconfig.get_path("stdlib") + "/LICENSE.txt")')"
cp "$PYTHON_LICENSE" "$APP/Contents/Resources/PYTHON-LICENSE.txt"
swift scripts/make_icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# Finder/iCloud metadata on generated bundles is rejected by codesign.
xattr -cr "$APP"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP"
elif [[ "${USE_LOCAL_SIGNING:-0}" == 1 ]]; then
  "$PYTHON" scripts/local_signing.py sign "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
"$APP/Contents/MacOS/QishengRecorder" --self-test
"$APP/Contents/MacOS/QishengRecorder" --update-self-test
"$APP/Contents/MacOS/QishengRecorder" --review-self-test
"$APP/Contents/MacOS/QishengRecorder" --gallery-self-test
"$PYTHON" scripts/privacy_audit.py --artifact "$APP" --review-dependencies
.build-tools/bin/python scripts/audit_worker_archive.py "$APP/Contents/Resources/portrait-worker/portrait-worker"
printf 'Application built: %s\n' "$APP"
