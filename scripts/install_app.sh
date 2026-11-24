#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT_DIR/scripts/build_app.sh"

pkill -x MailPilot || true
sleep 0.4
rm -rf /Applications/MailPilot.app
ditto "$ROOT_DIR/dist/MailPilot.app" /Applications/MailPilot.app

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -f /Applications/MailPilot.app || true
fi

open /Applications/MailPilot.app
echo "Installed and launched /Applications/MailPilot.app"
