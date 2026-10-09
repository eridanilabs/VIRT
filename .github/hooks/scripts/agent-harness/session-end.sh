#!/usr/bin/env bash
# session-end.sh
#
# Beads is the source of truth for session handoff state - the sessionStart hook
# reads it directly and injects via additionalContext. No file is written here.
#
# Session end runs independent stages: a graphify staleness refresh, then the
# Beads sync. The refresh is a safety net for work the agent should already
# have done, so it never fails the session; losing the Beads push does matter
# and still sets a nonzero status. Never fabricate a handoff here.
set -euo pipefail

cat >/dev/null

# Portable across Linux/macOS: don't assume a username or install path.
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Stage 1: rebuild graphify corpora whose docs this session left newer than
# their graph. Mechanical and no-LLM, and it never performs a first build.
if ! "$SCRIPT_DIR/scripts/graphify-refresh.sh"; then
  echo 'Agent harness: graphify refresh failed; continuing session shutdown.' >&2
fi

# Stage 2: Beads sync. Status 2 means a prerequisite is absent - bd, jq or
# .beads - which is the state of any project that has not run the init skill.
# There is no stored state to push, so there is nothing to warn about losing
# and the hook still owes the runtime its JSON. Any other failure means this
# checkout is misconfigured or unsafe to route, and stays fatal.
# shellcheck source=scripts/beads-common.sh
source "$SCRIPT_DIR/scripts/beads-common.sh"
# Consumed by the dynamically sourced server route.
# shellcheck disable=SC2034
BEADS_SERVER_DEADLINE=$(beads_deadline_after 28)
BEADS_STATUS=0
beads_resolve "$SCRIPT_DIR" || BEADS_STATUS=$?
if [ "$BEADS_STATUS" != 0 ]; then
  [ "$BEADS_STATUS" = 2 ] || exit "$BEADS_STATUS"
  echo 'Agent harness: Beads sync unavailable; ending session without pushing task state.' >&2
  echo '{}'
  exit 0
fi
# beads_resolve preserves an explicit actor; its exports stay in this hook.
STATUS=0
# bd dolt push uses refs/dolt/data, not a conventional Dolt remote. sessionEnd
# output is effectively invisible, so a failure is also recorded durably in a
# marker file that the next sessionStart reads and surfaces. Success clears it.
MARKER="$BEADS_DIR/.push-failed"
PUSH_OUTPUT=""
PUSH_CODE=0
PUSH_OUTPUT=$(bd dolt push 2>&1) || PUSH_CODE=$?
if [ "$PUSH_CODE" != 0 ]; then
  PUSH_TAIL=$(printf '%s\n' "$PUSH_OUTPUT" | tail -n 20)
  {
    printf 'timestamp: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'exit_code: %s\n' "$PUSH_CODE"
    printf 'error:\n%s\n' "$PUSH_TAIL"
  } >"$MARKER" 2>/dev/null ||
    echo "Beads: could not write push-failure marker at $MARKER." >&2
  echo "Beads: end-of-session push failed (exit $PUSH_CODE); local state has not been confirmed remote. Last output: $(printf '%s' "$PUSH_TAIL" | tail -n 3 | tr '\n' ' ')" >&2
  STATUS=1
else
  rm -f "$MARKER" 2>/dev/null || true
fi

echo '{}'
exit "$STATUS"
