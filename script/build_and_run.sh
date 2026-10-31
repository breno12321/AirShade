#!/usr/bin/env bash
set -euo pipefail
MODE="${1:-run}"
case "$MODE" in run|--build|--debug|--logs|--telemetry|--verify|--simulate) ;; *) echo "Usage: $0 [--build|--debug|--logs|--telemetry|--verify|--simulate]" >&2; exit 2;; esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
APP_BUNDLE="$ROOT_DIR/dist/AirShade.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/AirShade"
if [[ "$MODE" != --build ]]; then pkill -x AirShade >/dev/null 2>&1 || true; fi
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$ROOT_DIR/.build/ModuleCache"
swift build --disable-sandbox --product AirShade
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$(swift build --disable-sandbox --show-bin-path)/AirShade" "$APP_BINARY"
cp Resources/AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP_BUNDLE/Contents/Info.plist"
# A certificate-backed identity keeps TCC permissions stable across rebuilds.
SIGNING_IDENTITY="${AIRSHADE_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]]; then
  if security find-identity -v -p codesigning | /usr/bin/grep -q '"Apple Development:'; then
    SIGNING_IDENTITY="Apple Development"
  else
    SIGNING_IDENTITY="-"
    echo "Warning: ad-hoc signing; macOS permissions may need reapproval after rebuilding." >&2
  fi
fi
codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
case "$MODE" in
  --build) echo "$APP_BUNDLE" ;;
  --debug) lldb -- "$APP_BINARY" ;;
  --logs) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'process == "AirShade"' ;;
  --telemetry) open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate 'subsystem == "dev.breno.AirShade"' ;;
  --verify) open -n "$APP_BUNDLE" --args --show-setup; sleep 2; pgrep -x AirShade ;;
  --simulate) open -n "$APP_BUNDLE" --args --simulate --show-setup ;;
  run) open -n "$APP_BUNDLE" ;;
esac
