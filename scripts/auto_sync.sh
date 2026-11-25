#!/usr/bin/env bash
set -euo pipefail

# Safely keeps a clean local checkout fast-forwarded to remote tags and main branch.
# Designed for cron / launchd / manual periodic sync on both Linux and macOS.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${MAILPILOT_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd)}"
REMOTE="${MAILPILOT_SYNC_REMOTE:-origin}"
TARGET_BRANCH="${MAILPILOT_SYNC_BRANCH:-main}"
LOG_FILE="${MAILPILOT_SYNC_LOG:-}"
LOCK_BASE="${TMPDIR:-/tmp}/mailpilot-git-autosync"

log_msg() {
  local line
  line="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1"
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s\n' "$line" >>"$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

# Prevent overlapping runs across Linux (flock) and macOS (atomic mkdir fallback)
if command -v flock >/dev/null 2>&1; then
  exec 9>"${LOCK_BASE}.lock"
  flock -n 9 || exit 0
else
  LOCK_DIR="${LOCK_BASE}.lock.d"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 0
  trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT
fi

GIT_DIR="$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)" || exit 0
if [[ "$GIT_DIR" != /* ]]; then
  GIT_DIR="$REPO/$GIT_DIR"
fi

# Skip if any merge, rebase, cherry-pick, or bisect operation is in progress
if [[ -e "$GIT_DIR/MERGE_HEAD" || -d "$GIT_DIR/rebase-merge" || -d "$GIT_DIR/rebase-apply" || -e "$GIT_DIR/CHERRY_PICK_HEAD" || -e "$GIT_DIR/BISECT_LOG" ]]; then
  exit 0
fi

# Only auto-pull on the configured target branch when working tree is completely clean
CURRENT_BRANCH="$(git -C "$REPO" symbolic-ref --short -q HEAD || true)"
[[ "$CURRENT_BRANCH" == "$TARGET_BRANCH" ]] || exit 0
[[ -z "$(git -C "$REPO" status --porcelain)" ]] || exit 0

export GIT_TERMINAL_PROMPT=0
git -C "$REPO" fetch --tags --prune "$REMOTE" >/dev/null 2>&1 || exit 0

LOCAL_SHA="$(git -C "$REPO" rev-parse HEAD)"
REMOTE_SHA="$(git -C "$REPO" rev-parse "${REMOTE}/${TARGET_BRANCH}" 2>/dev/null || true)"

if [[ -n "$REMOTE_SHA" && "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
  if git -C "$REPO" merge-base --is-ancestor "$LOCAL_SHA" "$REMOTE_SHA"; then
    if [[ -n "$LOG_FILE" ]]; then
      mkdir -p "$(dirname "$LOG_FILE")"
      if git -C "$REPO" pull --ff-only "$REMOTE" "$TARGET_BRANCH" >>"$LOG_FILE" 2>&1; then
        log_msg "fast-forwarded ${LOCAL_SHA:0:7} -> ${REMOTE_SHA:0:7}"
      fi
    else
      if git -C "$REPO" pull --ff-only "$REMOTE" "$TARGET_BRANCH"; then
        log_msg "fast-forwarded ${LOCAL_SHA:0:7} -> ${REMOTE_SHA:0:7}"
      fi
    fi
  fi
fi
