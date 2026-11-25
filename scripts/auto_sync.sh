#!/usr/bin/env bash
set -euo pipefail

# Safely keeps a clean local checkout fast-forwarded to remote tags and target branch.
# Designed for cron / launchd / manual periodic sync on both Linux and macOS.

# Clear Git redirection variables that could target a different repo/index than MAILPILOT_REPO_DIR
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REPO_INPUT="${MAILPILOT_REPO_DIR:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
REMOTE="${MAILPILOT_SYNC_REMOTE:-origin}"
TARGET_BRANCH="${MAILPILOT_SYNC_BRANCH:-main}"
LOG_FILE="${MAILPILOT_SYNC_LOG:-}"

log_info() {
  local line
  line="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $1"
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s\n' "$line" >>"$LOG_FILE"
  else
    printf '%s\n' "$line"
  fi
}

log_err() {
  local line
  line="[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] ERROR: $1"
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")"
    printf '%s\n' "$line" >>"$LOG_FILE"
  fi
  printf '%s\n' "$line" >&2
}

if [[ ! -d "$REPO_INPUT" ]]; then
  log_err "repository directory does not exist: $REPO_INPUT"
  exit 1
fi
REPO="$(cd "$REPO_INPUT" && pwd -P)"

TOPLEVEL="$(git -C "$REPO" rev-parse --show-toplevel 2>/dev/null)" || {
  log_err "not a git worktree: $REPO"
  exit 1
}
TOPLEVEL="$(cd "$TOPLEVEL" && pwd -P)"
if [[ "$REPO" != "$TOPLEVEL" ]]; then
  log_err "configured path '$REPO' is not the git worktree root ('$TOPLEVEL')"
  exit 1
fi

RAW_GIT_DIR="$(git -C "$REPO" rev-parse --git-dir 2>/dev/null)" || {
  log_err "failed to resolve git-dir for $REPO"
  exit 1
}
if [[ "$RAW_GIT_DIR" == /* ]]; then
  GIT_DIR="$(cd "$RAW_GIT_DIR" && pwd -P)"
else
  GIT_DIR="$(cd "$REPO/$RAW_GIT_DIR" && pwd -P)"
fi

# Per-worktree private lock inside GIT_DIR (same protocol on Linux & macOS, safe against stale SIGKILL locks)
LOCK_DIR="$GIT_DIR/mailpilot-auto-sync.lock.d"
LOCK_ACQUIRED=0

cleanup_lock() {
  if [[ "$LOCK_ACQUIRED" -eq 1 ]]; then
    rm -f "$LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}
trap cleanup_lock EXIT

acquire_lock() {
  local attempt holder_pid
  for attempt in 1 2; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$LOCK_DIR/pid"
      LOCK_ACQUIRED=1
      return 0
    fi

    # Allow a brief moment if another process just created LOCK_DIR and hasn't written pid yet
    if [[ ! -f "$LOCK_DIR/pid" ]]; then
      sleep 0.1
    fi

    holder_pid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
    if [[ "$holder_pid" =~ ^[0-9]+$ ]] && kill -0 "$holder_pid" 2>/dev/null; then
      return 1
    fi

    # Stale lock (missing/invalid PID or dead process): atomically move aside before retrying
    if [[ "$attempt" -eq 1 ]]; then
      local stale_dir="${LOCK_DIR}.stale.$$"
      if mv "$LOCK_DIR" "$stale_dir" 2>/dev/null; then
        rm -rf "$stale_dir" 2>/dev/null || true
      else
        return 1
      fi
    fi
  done
  return 1
}

acquire_lock || exit 0

has_in_progress_git_op() {
  local rel path
  for rel in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG sequencer; do
    path="$(git -C "$REPO" rev-parse --git-path "$rel" 2>/dev/null)" || return 2
    if [[ "$path" != /* ]]; then
      path="$REPO/$path"
    fi
    if [[ -e "$path" ]]; then
      return 0
    fi
  done
  return 1
}

# Returns 0 if ready to sync, 10 if safely skipped (non-target branch, dirty tree, in-progress op), exits 1 on git errors
check_ready_for_sync() {
  local op_rc=0
  has_in_progress_git_op || op_rc=$?
  if [[ "$op_rc" -eq 0 ]]; then
    return 10
  elif [[ "$op_rc" -ne 1 ]]; then
    log_err "failed to inspect git operation state"
    exit 1
  fi

  local full_ref="" ref_rc=0
  full_ref="$(git -C "$REPO" symbolic-ref -q HEAD 2>/dev/null)" || ref_rc=$?
  if [[ "$ref_rc" -ne 0 || "$full_ref" != "refs/heads/${TARGET_BRANCH}" ]]; then
    return 10
  fi

  local status_out="" status_rc=0
  status_out="$(git -C "$REPO" status --porcelain --untracked-files=normal 2>&1)" || status_rc=$?
  if [[ "$status_rc" -ne 0 ]]; then
    log_err "git status failed (exit $status_rc): $status_out"
    exit 1
  fi
  if [[ -n "$status_out" ]]; then
    return 10
  fi

  return 0
}

ready_rc=0
check_ready_for_sync || ready_rc=$?
if [[ "$ready_rc" -eq 10 ]]; then
  exit 0
fi

INITIAL_HEAD="$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null)" || {
  log_err "failed to resolve HEAD"
  exit 1
}

export GIT_TERMINAL_PROMPT=0
fetch_out=""
fetch_rc=0
fetch_out="$(git -C "$REPO" fetch --tags --prune "$REMOTE" 2>&1)" || fetch_rc=$?
if [[ "$fetch_rc" -ne 0 ]]; then
  log_err "git fetch from '$REMOTE' failed (exit $fetch_rc): $fetch_out"
  exit 1
fi

TARGET_SHA="$(git -C "$REPO" rev-parse --verify "refs/remotes/${REMOTE}/${TARGET_BRANCH}^{commit}" 2>/dev/null)" || {
  log_err "failed to resolve remote branch '${REMOTE}/${TARGET_BRANCH}'"
  exit 1
}

if [[ "$INITIAL_HEAD" == "$TARGET_SHA" ]]; then
  exit 0
fi

anc_rc=0
git -C "$REPO" merge-base --is-ancestor "$INITIAL_HEAD" "$TARGET_SHA" || anc_rc=$?
if [[ "$anc_rc" -eq 1 ]]; then
  # Local branch is ahead or diverged; skip safely without modifying history
  exit 0
elif [[ "$anc_rc" -ne 0 ]]; then
  log_err "git merge-base check failed (exit $anc_rc)"
  exit 1
fi

# Re-verify branch, cleanliness, op state, and HEAD right before merging to avoid TOCTOU races during fetch
recheck_rc=0
check_ready_for_sync || recheck_rc=$?
if [[ "$recheck_rc" -eq 10 ]]; then
  exit 0
fi

CURRENT_HEAD="$(git -C "$REPO" rev-parse --verify HEAD 2>/dev/null)" || {
  log_err "failed to re-verify HEAD before merge"
  exit 1
}
if [[ "$CURRENT_HEAD" != "$INITIAL_HEAD" ]]; then
  exit 0
fi

merge_out=""
merge_rc=0
merge_out="$(git -C "$REPO" merge --ff-only --no-overwrite-ignore "$TARGET_SHA" 2>&1)" || merge_rc=$?
if [[ "$merge_rc" -ne 0 ]]; then
  log_err "git merge --ff-only failed (exit $merge_rc): $merge_out"
  exit 1
fi

log_info "fast-forwarded ${INITIAL_HEAD:0:7} -> ${TARGET_SHA:0:7} (${REMOTE}/${TARGET_BRANCH})"
