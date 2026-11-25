#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/build_app.sh"

pkill -x MailPilot || true
sleep 0.4
rm -rf /Applications/MailPilot.app
ditto "$ROOT_DIR/dist/MailPilot.app" /Applications/MailPilot.app
touch /Applications/MailPilot.app /Applications/MailPilot.app/Contents/Info.plist /Applications/MailPilot.app/Contents/Resources/MailPilotCrane.icns

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$ROOT_DIR/dist/.MailPilot.staging.app" >/dev/null 2>&1 || true
  "$LSREGISTER" -f /Applications/MailPilot.app || true
fi

# Refresh macOS IconServices & Notification Center caches so updated icon appears on banners immediately
USER_CACHE_DIR="$(getconf DARWIN_USER_CACHE_DIR 2>/dev/null || true)"
if [[ -n "$USER_CACHE_DIR" && -d "$USER_CACHE_DIR" ]]; then
  rm -f "$USER_CACHE_DIR/com.apple.iconservices/store.index" "$USER_CACHE_DIR/com.apple.dock.iconcache" >/dev/null 2>&1 || true
fi
killall -u "$USER" NotificationCenter usernoted >/dev/null 2>&1 || true
sleep 0.8

open /Applications/MailPilot.app
echo "Installed and launched /Applications/MailPilot.app"
