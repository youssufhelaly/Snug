#!/bin/zsh
# Builds Snug for the simulator and screenshots each screen via the debug
# screenshot harness (Snug/App/ScreenshotHarness.swift).
#
#   scripts/screenshots.sh [out-dir] [screen ...]
#
# Screens: onboarding emptyHome home room selected catalog shop
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:-/tmp/snug-shots}; shift || true
if (( $# )); then SCREENS=("$@"); else SCREENS=(onboarding emptyHome home room selected catalog shop); fi
DEVICE_NAME="Snug Review iPhone"
BUNDLE=com.helaly.Snug
DD=/tmp/snug-dd

UDID=$(xcrun simctl list devices available -j | python3 -c "
import json,sys
for rt, devs in json.load(sys.stdin)['devices'].items():
    for d in devs:
        if d['name'] == '$DEVICE_NAME': print(d['udid']); raise SystemExit
")
if [[ -z "$UDID" ]]; then
  TYPE=$(xcrun simctl list devicetypes -j | python3 -c "
import json,sys
types=[t for t in json.load(sys.stdin)['devicetypes'] if t['name'].startswith('iPhone') and 'Pro' in t['name'] and 'Max' not in t['name']]
print(types[-1]['identifier'])")
  RUNTIME=$(xcrun simctl list runtimes -j | python3 -c "
import json,sys
rts=[r for r in json.load(sys.stdin)['runtimes'] if r['platform']=='iOS' and r['isAvailable']]
print(rts[-1]['identifier'])")
  UDID=$(xcrun simctl create "$DEVICE_NAME" "$TYPE" "$RUNTIME")
fi
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
# Clean status bar for screenshots.
xcrun simctl status_bar "$UDID" override --time 9:41 --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 2>/dev/null || true

xcodebuild build -project Snug.xcodeproj -scheme Snug -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO COMPILER_INDEX_STORE_ENABLE=NO -quiet
APP=$(ls -d "$DD"/Build/Products/Debug-iphonesimulator/Snug.app)
xcrun simctl install "$UDID" "$APP"

mkdir -p "$OUT"
for screen in $SCREENS; do
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
  # "onboarding2" opens the onboarding flow on its third slide (0-based index 2).
  base=${screen%%[0-9]}; slide=${screen#$base}
  xcrun simctl launch "$UDID" "$BUNDLE" -snugScreen "$base" -snugSlide "${slide:-0}" -snugHideChrome "${HIDE_CHROME:-NO}" >/dev/null
  case $screen in
    room|selected|catalog|shop) sleep 9 ;;
    *) sleep 4 ;;
  esac
  xcrun simctl io "$UDID" screenshot --type=png "$OUT/$screen.png" >/dev/null 2>&1
  echo "$OUT/$screen.png"
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null || true
