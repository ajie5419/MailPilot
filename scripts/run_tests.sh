#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODULE_CACHE="${TMPDIR:-/tmp}/mailpilot-clang-module-cache"
TEST_BIN="${TMPDIR:-/tmp}/mailpilot-core-tests"

mkdir -p "$MODULE_CACHE"
cd "$ROOT_DIR"

swiftc \
  -parse-as-library \
  -target arm64-apple-macosx14.0 \
  -module-cache-path "$MODULE_CACHE" \
  -lsqlite3 \
  -framework CoreServices \
  -framework Security \
  -framework Network \
  -o "$TEST_BIN" \
  Sources/MailPilotCore/*.swift \
  Tests/StandaloneTestRunner.swift \
  Tests/ChatGPTTests.swift

"$TEST_BIN"
