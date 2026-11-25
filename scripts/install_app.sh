#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REFRESH_ICONS=false
for arg in "$@"; do
  if [[ "$arg" == "--refresh-icons" ]]; then
    REFRESH_ICONS=true
  fi
done

PREV_ICON=""
if [[ -f /Applications/MailPilot.app/Contents/Info.plist ]]; then
  PREV_ICON="$(plutil -extract CFBundleIconFile raw /Applications/MailPilot.app/Contents/Info.plist 2>/dev/null || true)"
fi

SKIP_LSREGISTER=1 "$ROOT_DIR/scripts/build_app.sh"
NEW_ICON="$(plutil -extract CFBundleIconFile raw "$ROOT_DIR/dist/MailPilot.app/Contents/Info.plist" 2>/dev/null || true)"

pkill -x MailPilot || true
sleep 0.4
rm -rf /Applications/MailPilot.app
ditto "$ROOT_DIR/dist/MailPilot.app" /Applications/MailPilot.app
touch /Applications/MailPilot.app /Applications/MailPilot.app/Contents/Info.plist
if [[ -n "$NEW_ICON" && -f "/Applications/MailPilot.app/Contents/Resources/$NEW_ICON" ]]; then
  touch "/Applications/MailPilot.app/Contents/Resources/$NEW_ICON"
fi

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f /Applications/MailPilot.app || true
fi

# Only flush global user icon & NotificationCenter caches when explicitly requested (--refresh-icons)
# or when the bundle's CFBundleIconFile changed across installs.
if [[ "$REFRESH_ICONS" == "true" || ( -n "$PREV_ICON" && -n "$NEW_ICON" && "$PREV_ICON" != "$NEW_ICON" ) ]]; then
  CURRENT_USER="$(id -un)"
  USER_CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
  if [[ -n "$USER_CACHE_DIR" && -d "$USER_CACHE_DIR" ]]; then
    rm -f "$USER_CACHE_DIR/com.apple.iconservices/store.index" "$USER_CACHE_DIR/com.apple.dock.iconcache" >/dev/null 2>&1 || true
  fi
  killall -u "$CURRENT_USER" NotificationCenter usernoted >/dev/null 2>&1 || true
  sleep 0.8
fi

open /Applications/MailPilot.app
echo "Installed and launched /Applications/MailPilot.app"
