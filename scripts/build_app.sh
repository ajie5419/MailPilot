#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MailPilot"

resolve_app_version() {
  if [[ -n "${APP_VERSION:-}" ]]; then
    printf '%s\n' "$APP_VERSION"
    return
  fi
  local desc
  if desc="$(git -C "$ROOT_DIR" describe --tags --long --match 'v[0-9]*' 2>/dev/null)"; then
    local rest="${desc%-g*}"
    local commits="${rest##*-}"
    local tag="${rest%-*}"
    local base="${tag#v}"
    if [[ "$commits" == "0" ]]; then
      printf '%s\n' "$base"
    else
      printf '%s.%s\n' "$base" "$commits"
    fi
    return
  fi
  local count
  if count="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null)"; then
    printf '0.0.%s\n' "$count"
    return
  fi
  printf '0.2.0\n'
}

APP_VERSION="$(resolve_app_version)"
BUILD_VERSION="$(date +%Y%m%d%H%M)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
STAGING_BUNDLE="$DIST_DIR/.${APP_NAME}.staging.app"
CONTENTS_DIR="$STAGING_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
MODULE_CACHE="${TMPDIR:-/tmp}/mailpilot-clang-module-cache"
DEFAULT_CERT_NAME="MailPilot Dev"

mkdir -p "$MODULE_CACHE" "$DIST_DIR"
rm -rf "$STAGING_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "Compiling ${APP_NAME} ${APP_VERSION} (build ${BUILD_VERSION}) with swiftc..."
cd "$ROOT_DIR"
swiftc \
  -O \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE" \
  -lsqlite3 \
  -framework SwiftUI \
  -framework AppKit \
  -framework CoreServices \
  -framework Security \
  -framework Network \
  -framework WebKit \
  -framework UserNotifications \
  -framework PDFKit \
  -framework Vision \
  -framework ServiceManagement \
  -o "$MACOS_DIR/${APP_NAME}" \
  Sources/MailPilotCore/*.swift \
  Sources/MailPilotApp/*.swift

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleExecutable</key>
    <string>MailPilot</string>
    <key>CFBundleIconFile</key>
    <string>MailPilotCrane.icns</string>
    <key>CFBundleIdentifier</key>
    <string>com.mailpilot.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MailPilot</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${APP_VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>MailPilot 需要通过系统「邮件」App 安全执行标记已读、添加旗标、归档、删除和发送邮件。</string>
</dict>
</plist>
PLIST

# Generate official MailPilotCrane.icns using Apple's iconutil when available (with direct writer fallback)
ICON_CACHE="$DIST_DIR/MailPilotCrane.icns"
if [[ ! -f "$ICON_CACHE" || "$ROOT_DIR/scripts/generate_icon.swift" -nt "$ICON_CACHE" ]]; then
  echo "Generating MailPilotCrane.icns..."
  ICON_TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mailpilot-icon.XXXXXX")"
  trap 'rm -rf "${ICON_TMP_DIR:-}"' EXIT
  ICON_GEN_BIN="$ICON_TMP_DIR/mailpilot-generate-icon"
  ICONSET_DIR="$ICON_TMP_DIR/MailPilot.iconset"
  ICON_OUT="$ICON_TMP_DIR/MailPilotCrane.icns"
  swiftc \
    -target arm64-apple-macosx14.0 \
    -module-cache-path "$MODULE_CACHE" \
    -framework AppKit \
    -o "$ICON_GEN_BIN" \
    "$ROOT_DIR/scripts/generate_icon.swift"
  "$ICON_GEN_BIN" --iconset "$ICONSET_DIR"
  if ! iconutil --convert icns "$ICONSET_DIR" -o "$ICON_OUT"; then
    "$ICON_GEN_BIN" "$ICON_OUT"
  fi
  mv "$ICON_OUT" "$ICON_CACHE"
  rm -rf "$ICON_TMP_DIR"
fi
cp "$ICON_CACHE" "$RESOURCES_DIR/MailPilotCrane.icns"

# Prefer a stable local code-signing identity so macOS TCC permissions persist across rebuilds.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [[ -z "$SIGN_IDENTITY" ]]; then
  if security find-identity -v -p codesigning | grep -q "\"${DEFAULT_CERT_NAME}\""; then
    SIGN_IDENTITY="$DEFAULT_CERT_NAME"
  fi
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  echo "Signing with stable certificate: ${SIGN_IDENTITY}"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$STAGING_BUNDLE"
else
  echo "Note: '${DEFAULT_CERT_NAME}' certificate not found; falling back to ad-hoc signing."
  echo "Run ./scripts/setup_dev_cert.sh once to preserve macOS permissions across rebuilds."
  codesign --force --deep --sign - "$STAGING_BUNDLE"
fi

# Atomically swap the verified staging bundle into place so a failed build never deletes the previous working app.
rm -rf "$APP_BUNDLE"
mv "$STAGING_BUNDLE" "$APP_BUNDLE"

# Refresh macOS LaunchServices icon registration unless caller (e.g. install_app.sh) handles final install registration
touch "$APP_BUNDLE"
if [[ "${SKIP_LSREGISTER:-0}" != "1" ]]; then
  LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_BUNDLE" || true
  fi
fi

echo "Built app bundle: $APP_BUNDLE"
