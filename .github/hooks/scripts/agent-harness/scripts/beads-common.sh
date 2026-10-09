#!/usr/bin/env bash
# Shared, fail-closed routing for this repo's existing embedded Beads stores.
# Source from Bash 3.2+; invocation CWD always selects the consumer.
BEADS_HELPER_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$BEADS_HELPER_DIR/consumer-common.sh"

beads_error() {
  printf 'Beads: %s\n' "$*" >&2
  return 1
}

beads_require() {
  command -v "$1" >/dev/null 2>&1 || beads_error "required command not found: $1"
}

beads_common_dir() {
  local common
  common=$(git -C "$1" rev-parse --git-common-dir) || return 1
  case "$common" in
    /*) ;;
    *) common="$1/$common" ;;
  esac
  (cd "$common" && pwd -P)
}

# Bash 3.2 has no monotonic/subsecond clock. Use the system Perl core module,
# not date (wall-clock jumps) or SECONDS (whole seconds and wall-clock time).
# Integer milliseconds have <1ms quantization; process suspension counts, but
# cleanup cannot run until this supervisor is scheduled again. Fail closed if
# this platform lacks the clock. No polling count is an execution budget.
beads_now_ms() {
  /usr/bin/perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC \
    -e 'printf "%d\n", clock_gettime(CLOCK_MONOTONIC) * 1000'
}

beads_deadline_after() {
  local now
  now=$(beads_now_ms) || return 1
  printf '%s\n' "$((now + $1 * 1000))"
}

# A subshell keeps job-control and traps out of the caller. Bash job control
# assigns this one background pull its own process group on Bash 3.2 as well.
# Signal only that owned group, including children, never a discovered server
# or any process selected by name. No timeout/setsid utility is required.
beads_run_bounded() (
  local now deadline status
  local ticks=$1
  shift
  now=$(beads_now_ms) || exit 1
  deadline=$((now + ticks * 100))
  if [ "${BEADS_ROUTE:-embedded}" = server ] &&
    [ -n "${BEADS_SERVER_DEADLINE:-}" ] &&
    [ "$BEADS_SERVER_DEADLINE" -lt "$deadline" ]; then
    deadline=$BEADS_SERVER_DEADLINE
  fi
  [ "$now" -lt "$deadline" ] || exit 124
  # Bash 3.2 unwinds function locals before EXIT on a trapped signal. Keep the
  # owned PID in this subshell's scope so cleanup can still find its group.
  pull_pid=""
  # Invoked by the EXIT trap below, not a direct call.
  # shellcheck disable=SC2329
  beads_pull_cleanup() {
    [ -n "$pull_pid" ] || return 0
    if kill -0 -- "-$pull_pid" 2>/dev/null; then
      kill -TERM -- "-$pull_pid" 2>/dev/null || true
      sleep 0.2 || true
      kill -KILL -- "-$pull_pid" 2>/dev/null || true
    fi
    wait "$pull_pid" 2>/dev/null || true
  }
  trap beads_pull_cleanup EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  set -m
  if [ "${BEADS_ROUTE:-embedded}" = server ]; then
    # Only this supervisor creates a process group. Disable inherited job
    # control before server functions/subshells launch native grandchildren.
    (set +m; "$@") &
  else
    # Preserve the embedded supervisor -> native pull -> child process chain.
    "$@" &
  fi
  pull_pid=$!
  # The child's process group is already allocated. Disable job notifications
  # without changing that ownership (diagnostics would corrupt captured JSON).
  set +m
  # Polling only controls responsiveness, never elapsed accounting. Check the
  # deadline before observing completion AND after wait, so a delayed/stopped
  # supervisor cannot accept a child that finished after its budget.
  while :; do
    now=$(beads_now_ms) || exit 1
    [ "$now" -lt "$deadline" ] || break
    if ! kill -0 "$pull_pid" 2>/dev/null; then
      if wait "$pull_pid"; then status=0; else status=$?; fi
      now=$(beads_now_ms) || exit 1
      [ "$now" -lt "$deadline" ] || break
      exit "$status"
    fi
    sleep 0.1 || exit 1
  done
  # A diagnostic must not let errexit replace the timeout status with 1.
  printf 'Beads: command exceeded the bounded execution budget (%s)\n' "$1" >&2
  exit 124
)

beads_pull_bounded() {
  local status
  if [ "${BEADS_ROUTE:-embedded}" = server ]; then
    # Dispatch already supervises each native call. An outer supervisor would
    # kill that inner supervisor before it could reap its independently grouped
    # descendants. Instead, share one five-second deadline across the dispatch
    # identity check, remote check and pull, capped by the hook's remaining time.
    local pull_deadline
    pull_deadline=$(beads_deadline_after 5) || return 1
    local BEADS_SERVER_DEADLINE=${BEADS_SERVER_DEADLINE:-$pull_deadline}
    [ "$BEADS_SERVER_DEADLINE" -le "$pull_deadline" ] ||
      BEADS_SERVER_DEADLINE=$pull_deadline
    if bd dolt pull >/dev/null; then return 0; else status=$?; fi
  else
    if beads_run_bounded 50 bd dolt pull >/dev/null; then return 0; else status=$?; fi
  fi
  [ "$status" != 124 ] || printf '%s\n' "Beads: pull exceeded the five-second synchronization budget" >&2
  return "$status"
}

# A function keeps hooks, handoffs and direct wrapper calls on the same route.
# Embedded callers still invoke exactly the existing native command.
bd() {
  if [ "${BEADS_ROUTE:-embedded}" = server ]; then
    beads_server_dispatch "$@"
  else
    command bd "$@"
  fi
}

# Resolve the store for this checkout and export the route.
# Exit status is a contract, not a boolean: 2 means a prerequisite is absent
# (bd, jq or git missing, or .beads never created) and a caller may degrade to
# a reduced mode; 1 means this checkout is misconfigured or unsafe to route and
# the caller must refuse rather than continue with a plausible-looking store.
beads_resolve() {
  local root common selected target store_common database identity overrides redirect_database="" selected_explicit=0 selected_dir
  beads_require git || return 2
  beads_require jq || return 2
  type -P bd >/dev/null || { beads_error "required command not found: bd"; return 2; }

  consumer_resolve || return 1
  common=$CONSUMER_GIT_COMMON_DIR

  case "${AGENT_HARNESS_BEADS_ALLOW_EXTERNAL:-0}" in
    0|1) ;;
    *) beads_error "AGENT_HARNESS_BEADS_ALLOW_EXTERNAL must be 0 or 1"; return 1 ;;
  esac
  # sed returns success on no matches; do not mask env/filter failures with
  # `grep ... || true`, which can silently skip this routing safety check.
  overrides=$(env | sed -n -e '/^BEADS_DB=/s/=.*//p' \
    -e '/^BEADS_DOLT_[^=]*=/s/=.*//p' -e '/^BD_DB=/s/=.*//p') ||
    { beads_error "could not inspect routing environment"; return 1; }
  [ -z "$overrides" ] ||
    { beads_error "unsupported routing overrides: $overrides (unset them, do not silently mix stores)"; return 1; }
  if [ "${BEADS_DIR+x}" = x ]; then
    [ -n "$BEADS_DIR" ] ||
      { beads_error "BEADS_DIR is explicitly empty; unset it to use the common checkout"; return 1; }
    selected=$BEADS_DIR
    selected_explicit=1
  elif [ "$WORKSPACE_ROOT" != "$BEADS_ROOT" ] &&
    { [ -e "$WORKSPACE_ROOT/.beads/redirect" ] || [ -L "$WORKSPACE_ROOT/.beads/redirect" ]; }; then
    selected="$WORKSPACE_ROOT/.beads"
  else
    selected="$BEADS_ROOT/.beads"
  fi
  # An absent default .beads means the project was never initialised. An
  # absent *explicit* BEADS_DIR is a wrong pointer and must not be softened.
  if [ ! -e "$selected" ] && [ ! -L "$selected" ]; then
    beads_error "selected BEADS_DIR does not exist"
    return $((selected_explicit ? 1 : 2))
  fi
  # Present but unusable (a file, a dangling link, no permission) is a broken
  # store, never an absent one, so it must not be softened to a degraded start.
  selected_dir=$(cd "$selected" 2>/dev/null && pwd -P) ||
    { beads_error "selected BEADS_DIR cannot be entered: $selected"; return 1; }
  selected=$selected_dir

  # Match native single-hop redirect syntax, but reject its silent fallbacks.
  if [ -e "$selected/redirect" ] || [ -L "$selected/redirect" ]; then
    if [ -f "$selected/metadata.json" ]; then
      redirect_database=$(jq -r '.dolt_database // ""' "$selected/metadata.json") || return 1
    fi
    target=$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e '/^#/d' -e '/^$/d' "$selected/redirect") || return 1
    case "$target" in
      ""|*$'\n'*) beads_error "redirect must contain exactly one target path"; return 1 ;;
      /*) ;;
      *) target="$selected/../$target" ;;
    esac
    selected=$(cd "$target" && pwd -P) ||
      { beads_error "redirect target does not exist: $target"; return 1; }
    [ ! -e "$selected/redirect" ] && [ ! -L "$selected/redirect" ] ||
      { beads_error "redirect chains/cycles are not supported"; return 1; }
  fi
  store_common=$(beads_common_dir "$selected" 2>/dev/null) || store_common=""
  if [ "$store_common" != "$common" ] && [ "${AGENT_HARNESS_BEADS_ALLOW_EXTERNAL:-0}" != 1 ]; then
    beads_error "BEADS_DIR belongs to another repository. Unset inherited BEADS_DIR, or explicitly opt in with AGENT_HARNESS_BEADS_ALLOW_EXTERNAL=1 for this invocation."
    return 1
  fi
  export BEADS_DIR="$selected"
  export BEADS_ACTOR="${BEADS_ACTOR:-$CONSUMER_SLUG${COPILOT_AGENT_SESSION_ID:+:$COPILOT_AGENT_SESSION_ID}}"
  BEADS_ROUTE=embedded
  if [ -e "$selected/server-enrollment.json" ] || [ -L "$selected/server-enrollment.json" ]; then
    # Startup preserves clock failure as zero so it cannot acquire a fresh
    # default budget here. Embedded resolution never consumes this deadline.
    [ "${BEADS_SERVER_DEADLINE:-}" != 0 ] ||
      { beads_error "server route requires a usable session deadline; monotonic clock initialization failed"; return 1; }
    BEADS_SERVER_HELPER="$BEADS_HELPER_DIR/beads-server.sh"
    BEADS_ROUTE=server
    export BEADS_SERVER_HELPER BEADS_ROUTE
    [ -z "$redirect_database" ] ||
      [ "$redirect_database" = "$(jq -er .dolt_database "$selected/metadata.json")" ] ||
      { beads_error "redirect source selects a different database"; return 1; }
    # Source once: one captured binary/config pair for this wrapper/hook
    # process, instead of recopying hundreds of MB for every handoff read.
    # shellcheck source=beads-server.sh
    source "$BEADS_SERVER_HELPER"
    beads_server_init
    return 0
  fi
  database=$(jq -er '
    select(.backend == "dolt" and .dolt_mode == "embedded") |
    .dolt_database | select(type == "string" and test("^[A-Za-z0-9_]+$"))
  ' "$selected/metadata.json") ||
    { beads_error "expected existing embedded Dolt metadata in $selected"; return 1; }
  [ -z "$redirect_database" ] || [ "$redirect_database" = "$database" ] ||
    { beads_error "redirect source selects a different database; refusing to discard that configuration"; return 1; }
  [ -d "$selected/embeddeddolt/$database/.dolt" ] ||
    { beads_error "embedded database is absent in $selected; refusing init or fallback"; return 1; }
  # The explicitly verified v1.2.2, v1.3.0-rc.1, and v1.3.0 (stable) context
  # commands skip store initialization. v1.3.0 stable was added after its
  # Darwin arm64 `bd context --json` output was confirmed to match the same
  # shape as v1.3.0-rc.1: identical required fields (backend, beads_dir,
  # database, dolt_mode), no server_host/server_port/proxied_dir, and no
  # shared-server notice on stderr -- only bd_version differs. dolt_mode is
  # metadata, but
  # IsDoltServerMode() emits server_host (always nonempty, even for sockets)
  # and a nonzero server_port. Reject server/proxy fields even when metadata
  # says embedded: native .env loading can enable BEADS_DOLT_SERVER_MODE=1
  # after our outer environment check. The separate effective shared-server
  # override can instead emit only a mismatch notice; retain stderr too.
  # config show is NOT safe here: it opens a store.
  identity=$(bd context --json 2>&1) ||
    { beads_error "bd context preflight failed; no operational command was run"; return 1; }
  case "$identity" in
    *"Notice: shared-server mode is enabled ("*)
      beads_error "effective shared-server config conflicts with the selected embedded store; inspect project and user config before retrying"
      return 1 ;;
  esac
  printf '%s\n' "$identity" | jq -e --arg dir "$BEADS_DIR" --arg db "$database" '
    type == "object" and
    (.bd_version == "1.2.2" or .bd_version == "1.3.0-rc.1" or .bd_version == "1.3.0") and
    .beads_dir == $dir and .database == $db and .dolt_mode == "embedded"
    and ((has("server_host") or has("server_port") or has("proxied_dir")) | not)
  ' >/dev/null ||
    { beads_error "bd context disagrees with the selected embedded store, includes server/proxy identity, emitted diagnostics, or is not an explicitly verified version (1.2.2, 1.3.0-rc.1, or 1.3.0)"; return 1; }
}
