#!/usr/bin/env bash
# Resolve consumer identity from invocation CWD, never from this package.
# Source from Bash 3.2+. No network, store access, or Git configuration writes.

consumer_error() { printf 'Agent harness: %s\n' "$*" >&2; return 1; }

consumer_resolve() {
  local root common remote name
  root=$(git rev-parse --show-toplevel 2>/dev/null) ||
    { consumer_error "invoke from a consumer Git working checkout (bare/non-Git CWD is unsupported)"; return 1; }
  WORKSPACE_ROOT=$(cd "$root" && pwd -P) || return 1
  common=$(git -C "$WORKSPACE_ROOT" rev-parse --git-common-dir) || return 1
  case "$common" in /*) ;; *) common="$WORKSPACE_ROOT/$common" ;; esac
  CONSUMER_GIT_COMMON_DIR=$(cd "$common" && pwd -P) || return 1
  root=$(git -C "$WORKSPACE_ROOT" worktree list --porcelain | sed -n '1s/^worktree //p') || return 1
  [ -n "$root" ] && [ -d "$root" ] ||
    { consumer_error "cannot locate the common working checkout"; return 1; }
  BEADS_ROOT=$(cd "$root" && pwd -P) || return 1
  [ "$(git -C "$BEADS_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$BEADS_ROOT" ] &&
    [ "$CONSUMER_GIT_COMMON_DIR" = "$BEADS_ROOT/.git" ] ||
    { consumer_error "bare/separate-git-dir layouts are unsupported"; return 1; }

  if [ "${AGENT_HARNESS_PROJECT_SLUG+x}" = x ]; then
    CONSUMER_SLUG=$AGENT_HARNESS_PROJECT_SLUG
  else
    remote=$(git -C "$BEADS_ROOT" config --get remote.origin.url) || remote=""
    remote=${remote%/}
    name=${remote##*/}
    name=${name##*:}
    name=${name%.git}
    [ -n "$name" ] || name=$(basename "$BEADS_ROOT")
    CONSUMER_SLUG=$(printf '%s' "$name" | LC_ALL=C tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//') || return 1
  fi
  [[ "$CONSUMER_SLUG" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] &&
    [ "${#CONSUMER_SLUG}" -le 80 ] ||
    { consumer_error "cannot derive project identity; set AGENT_HARNESS_PROJECT_SLUG to an alphanumeric/hyphen slug (1-80 characters)"; return 1; }
  # Consumed by handoff-common.sh after route selection.
  # shellcheck disable=SC2034
  HANDOFF_PREFIX="session-handoff-$CONSUMER_SLUG-"
}

# An explicit repository wins. Otherwise resolve the common checkout's origin,
# not gh's ambient GH_REPO or the package's own remote. No network discovery.
consumer_github_repo() {
  local value=${1:-} remote host path
  if [ -z "$value" ]; then
    consumer_resolve || return 1
    remote=$(git -C "$BEADS_ROOT" config --get remote.origin.url) ||
      { consumer_error "no origin remote; specify the target repository explicitly"; return 1; }
    case "$remote" in
      https://*|http://*|ssh://*)
        remote=${remote#*://}; remote=${remote#*@}
        host=${remote%%/*}; host=${host%%:*}; path=${remote#*/} ;;
      *@*:*) host=${remote%%:*}; host=${host#*@}; path=${remote#*:} ;;
      *) consumer_error "origin is not a GitHub URL; specify owner/repo explicitly"; return 1 ;;
    esac
    path=${path%/}; path=${path%.git}
    value="$host/$path"
  fi
  [[ "$value" =~ ^([A-Za-z0-9.-]+/)?[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
    { consumer_error "repository must be [host/]owner/repo"; return 1; }
  printf '%s\n' "$value"
}
