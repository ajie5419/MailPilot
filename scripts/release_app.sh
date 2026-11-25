#!/usr/bin/env bash
set -euo pipefail

# Builds, tests, optionally Developer-ID signs & notarizes, and packages MailPilot for macOS release distribution.
#
# Local usage (ad-hoc or local MailPilot Dev cert):
#   ./scripts/release_app.sh
#
# Public distribution with Developer ID + Apple Notarization:
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="MailPilotNotary" \
#   ./scripts/release_app.sh
#
# Or with Apple ID credentials (CI):
#   CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   APPLE_ID="you@example.com" \
#   APPLE_TEAM_ID="TEAMID" \
#   APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
#   ./scripts/release_app.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/MailPilot.app"

cd "$ROOT_DIR"

echo "==> 1/4 Running core & ChatGPT test suites..."
./scripts/run_tests.sh

echo "==> 2/4 Building MailPilot.app..."
./scripts/build_app.sh

APP_VERSION="$(defaults read "$APP_BUNDLE/Contents/Info.plist" CFBundleShortVersionString)"
ZIP_NAME="MailPilot-${APP_VERSION}-macos-arm64.zip"
ZIP_PATH="$DIST_DIR/$ZIP_NAME"
SHA_PATH="${ZIP_PATH}.sha256"

# Re-sign with Hardened Runtime + secure timestamp when a Developer ID identity is supplied.
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" == *"Developer ID Application"* ]]; then
  echo "==> 2.5/4 Re-signing with Developer ID Hardened Runtime..."
  codesign --force --deep --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
fi

echo "==> 3/4 Packaging ${ZIP_NAME}..."
rm -f "$ZIP_PATH" "$SHA_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"

# Optional Apple Notarization + Stapling when credentials are provided.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> 3.5/4 Submitting for Apple Notarization via keychain profile '${NOTARY_PROFILE}'..."
  xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  echo "==> 3.5/4 Submitting for Apple Notarization via Apple ID credentials..."
  xcrun notarytool submit "$ZIP_PATH" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  ditto -c -k --sequesterRsrc --keepParent "$APP_BUNDLE" "$ZIP_PATH"
else
  echo "==> Skipping Apple Notarization (set NOTARY_PROFILE or APPLE_ID/APPLE_TEAM_ID/APPLE_APP_SPECIFIC_PASSWORD to enable)."
fi

echo "==> 4/4 Generating SHA-256 checksum..."
(cd "$DIST_DIR" && shasum -a 256 "$ZIP_NAME" > "${ZIP_NAME}.sha256")
cat "$SHA_PATH"
ls -lh "$ZIP_PATH"
