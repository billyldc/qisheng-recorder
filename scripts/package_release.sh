#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' packaging/Info.plist)}"
ARCH="$(uname -m)"
APP="${APP_BUILD_DIR:-$HOME/Library/Caches/QishengRecorder/build}/Qisheng Recorder.app"
[[ -d "$APP" ]] || { echo "Run scripts/build_app.sh first" >&2; exit 1; }
python3 scripts/privacy_audit.py --artifact "$APP" --review-dependencies
BASE="$ROOT/dist/Qisheng-Recorder-$VERSION-macOS-$ARCH"
mkdir -p "$ROOT/dist"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$BASE.zip"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/qisheng-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto --norsrc --noextattr "$APP" "$STAGING/Qisheng Recorder.app"
ln -s /Applications "$STAGING/Applications"
cp README.md "$STAGING/README.md"
# Hosted macOS runners can transiently report "Resource busy" while attaching
# the temporary filesystem. Keep failures visible and bound the retry count.
for attempt in 1 2 3; do
  if hdiutil create -ov -volname "Qisheng Recorder" -srcfolder "$STAGING" -format UDZO "$BASE.dmg"; then
    break
  fi
  if [[ "$attempt" == 3 ]]; then exit 1; fi
  sleep "$((attempt * 5))"
done
(cd dist && shasum -a 256 "$(basename "$BASE").zip" "$(basename "$BASE").dmg") > "$ROOT/dist/SHA256SUMS.txt"
printf 'Packaged: %s\n' "$BASE"
