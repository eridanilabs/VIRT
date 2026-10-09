#!/usr/bin/env bash
# Install commit provenance in the consumer's configured Git hooks directory.
set -euo pipefail
usage() {
  printf '%s\n' 'Usage: install-git-hooks.sh [--help|-h]'
  printf '%s\n' 'With no arguments, install commit provenance in the consumer hooks directory selected by git rev-parse --git-path hooks (including core.hooksPath).'
  printf '%s\n' 'Non-shell hooks and filename-sensitive dispatchers (including Husky) are refused unchanged; integrate through their hook manager instead.'
}
if [ "$#" -gt 0 ]; then
  if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
    usage
    exit 0
  fi
  printf '%s\n' 'Agent harness: install-git-hooks.sh accepts no installation arguments; use --help for usage.' >&2
  exit 1
fi
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$SCRIPT_DIR/consumer-common.sh"
consumer_resolve
HOOKS_DIR=$(git -C "$WORKSPACE_ROOT" rev-parse --git-path hooks)
case "$HOOKS_DIR" in /*) ;; *) HOOKS_DIR="$WORKSPACE_ROOT/$HOOKS_DIR" ;; esac
mkdir -p "$HOOKS_DIR"
HOOKS_DIR=$(cd "$HOOKS_DIR" && pwd -P)
LOCK="$HOOKS_DIR/.agent-harness-install.lock"
HOOK_FILE="$HOOKS_DIR/prepare-commit-msg"
PREVIOUS="$HOOKS_DIR/prepare-commit-msg.agent-harness.previous"
LOGIC="$HOOKS_DIR/agent-harness-session-id.sh"
SOURCE_LOGIC="$SCRIPT_DIR/git-hooks/prepare-commit-msg-session-id.sh"
MARKER='# agent-harness managed Session-Id wrapper v1'

# bd init, Husky, and similar tools point core.hooksPath at a directory inside
# the working tree. Everything installed here is machine-local: a per-clone
# logic script, a renamed predecessor hook, and a transient lock. Committing
# those would publish one machine's hook state to every other clone, so they
# are excluded per clone through .git/info/exclude rather than by editing the
# consumer's tracked .gitignore. A hooks directory that already holds tracked
# files is reported once, because the collision is the consumer's to resolve.
hookspath_declare_local() {
  local relative exclude entry notice
  case "$HOOKS_DIR/" in "$CONSUMER_GIT_COMMON_DIR"/*) return 0 ;; esac
  case "$HOOKS_DIR/" in "$WORKSPACE_ROOT"/*) ;; *) return 0 ;; esac
  relative=${HOOKS_DIR#"$WORKSPACE_ROOT"/}
  exclude="$CONSUMER_GIT_COMMON_DIR/info/exclude"
  mkdir -p "$CONSUMER_GIT_COMMON_DIR/info"
  for entry in \
    "/$relative/agent-harness-session-id.sh" \
    "/$relative/prepare-commit-msg.agent-harness.previous" \
    "/$relative/.agent-harness-install.lock/"; do
    grep -qxF -- "$entry" "$exclude" 2>/dev/null ||
      printf '%s\n' "$entry" >>"$exclude"
  done
  notice="$CONSUMER_GIT_COMMON_DIR/.agent-harness-hookspath-notice"
  [ "$(cat "$notice" 2>/dev/null)" = "$relative" ] && return 0
  if [ -n "$(git -C "$WORKSPACE_ROOT" ls-files -- "$relative" 2>/dev/null)" ]; then
    printf '%s\n' \
      "Agent harness: core.hooksPath points at tracked directory $relative." \
      "Agent harness: machine-local hook files are excluded there via .git/info/exclude, but replacing a tracked hook still shows as a working tree change; commit or revert it deliberately." >&2
  fi
  printf '%s\n' "$relative" >"$notice"
}
hookspath_declare_local
WRAPPER=$(cat <<'HOOK'
#!/usr/bin/env sh
# agent-harness managed Session-Id wrapper v1
set -eu
hook_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
if [ -x "$hook_dir/prepare-commit-msg.agent-harness.previous" ]; then
  "$hook_dir/prepare-commit-msg.agent-harness.previous" "$@" || exit $?
fi
"$hook_dir/agent-harness-session-id.sh" "$@"
HOOK
)

# Every session starts by calling this installer, and almost every call has
# nothing to do. Comparing the installed files costs no lock, so the common
# case cannot be delayed by - or blocked on - a lock another run left behind.
if [ ! -L "$HOOK_FILE" ] && [ ! -L "$LOGIC" ] && [ ! -L "$PREVIOUS" ] &&
  { [ ! -e "$PREVIOUS" ] || [ -f "$PREVIOUS" ]; } &&
  [ -f "$HOOK_FILE" ] && [ -x "$HOOK_FILE" ] &&
  [ -f "$LOGIC" ] && [ -x "$LOGIC" ] &&
  printf '%s\n' "$WRAPPER" | cmp -s - "$HOOK_FILE" &&
  cmp -s "$SOURCE_LOGIC" "$LOGIC"; then
  printf 'Session-Id prepare-commit-msg hook already current: %s\n' "$HOOK_FILE"
  exit 0
fi

# A lock may only be reclaimed when its owner is demonstrably gone. A kill
# permission error means the owner is running under another account, which is
# live, not stale; an unreadable or absent owner record is not evidence of
# death either. Anything short of proof keeps the existing never-steal rule.
lock_owner_is_gone() {
  local pid error
  pid=$(cat "$LOCK/owner" 2>/dev/null) || return 1
  case "$pid" in "" | *[!0-9]*) return 1 ;; esac
  error=$(kill -0 "$pid" 2>&1) && return 1
  case "$error" in *[Nn]ot" "permitted*) return 1 ;; esac
  return 0
}

attempts=0
until (umask 077; mkdir "$LOCK") 2>/dev/null; do
  attempts=$((attempts + 1))
  if [ "$attempts" = 25 ] && lock_owner_is_gone; then
    # Reclaim, do not reuse: staging from an interrupted run is unpublished
    # and may be incomplete, so it is discarded rather than inherited.
    printf 'Agent harness: reclaiming installer lock abandoned by a dead process: %s\n' "$LOCK" >&2
    rm -f "$LOCK/logic" "$LOCK/hook" "$LOCK/previous" "$LOCK/owner" 2>/dev/null || true
    rmdir "$LOCK" 2>/dev/null || true
    continue
  fi
  [ "$attempts" -lt 50 ] ||
    { consumer_error "git hook installer is busy or has a stale lock: $LOCK; never steal a live lock"; exit 1; }
  sleep 0.1
done
printf '%s\n' "$$" >"$LOCK/owner"
cleanup() {
  local status=$?
  trap - EXIT HUP INT TERM
  if ! rm -f "$LOCK/logic" "$LOCK/hook" "$LOCK/previous" "$LOCK/owner" || ! rmdir "$LOCK"; then
    printf 'Agent harness: could not clean installer staging at %s; inspect before retrying\n' "$LOCK" >&2
    status=1
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for file in "$HOOK_FILE" "$PREVIOUS" "$LOGIC"; do
  [ ! -L "$file" ] ||
    { consumer_error "refusing to replace symlink: $file"; exit 1; }
  if [ -e "$file" ] && [ ! -f "$file" ]; then
    consumer_error "hook destination is not a regular file: $file"
    exit 1
  fi
done
if [ -f "$HOOK_FILE" ]; then
  shebang=$(head -n 1 "$HOOK_FILE")
  if ! [[ "$shebang" =~ ^\#![[:blank:]]*/([^[:blank:]]*/)*(sh|bash|dash|ksh|zsh|ash)([[:blank:]].*)?$ ]] &&
     ! [[ "$shebang" =~ ^\#![[:blank:]]*/([^[:blank:]]*/)*env[[:blank:]]+(-S[[:blank:]]+)?(sh|bash|dash|ksh|zsh|ash)([[:blank:]].*)?$ ]]; then
    consumer_error "refusing to modify non-shell Git hook: $HOOK_FILE"
    exit 1
  fi
fi
SAVE_PREVIOUS=0
if [ -e "$HOOK_FILE" ] && ! grep -qxF "$MARKER" "$HOOK_FILE"; then
  # Renaming changes script identity. Husky and similar dispatchers use $0
  # to select another hook and can silently skip it under a backup filename.
  # shellcheck disable=SC2016 # Match literal shell parameter references.
  if grep -Eq '\$0|\$\{[!#]?0|BASH_SOURCE' "$HOOK_FILE"; then
    consumer_error "refusing to rename filename-sensitive Git hook (including hook-manager dispatchers): $HOOK_FILE; integrate provenance through its owner"
    exit 1
  fi
  [ ! -e "$PREVIOUS" ] ||
    { consumer_error "saved prior hook already exists; inspect $PREVIOUS before installing"; exit 1; }
  cp -p "$HOOK_FILE" "$LOCK/previous"
  SAVE_PREVIOUS=1
fi
cp "$SOURCE_LOGIC" "$LOCK/logic"
chmod 755 "$LOCK/logic"
printf '%s\n' "$WRAPPER" >"$LOCK/hook"
chmod 755 "$LOCK/hook"
# Publish complete files only; the wrapper is last so its dependencies exist.
# A saved original remains recoverable if a later rename fails.
if [ "$SAVE_PREVIOUS" = 1 ]; then mv "$LOCK/previous" "$PREVIOUS"; fi
mv "$LOCK/logic" "$LOGIC"
mv "$LOCK/hook" "$HOOK_FILE"
printf 'Installed Session-Id prepare-commit-msg hook: %s\n' "$HOOK_FILE"
