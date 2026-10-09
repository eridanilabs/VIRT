#!/usr/bin/env bash
# Restore graphify's local Git integration, which no clone ever receives.
#
# graphify hook install writes a post-commit rebuild, a post-checkout rebuild
# and a graph.json merge driver. The hooks live in .git/hooks and the driver in
# .git/config, so a fresh clone, a rebuilt checkout or a new machine silently
# loses all three and the consumer gets stale graphs and graph.json conflicts.
#
# Only a consumer that actually commits graph files is healed. Anything this
# script cannot do safely is reported on stdout for the session to relay; the
# exit status stays 0 so startup is never blocked by graphify.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$SCRIPT_DIR/consumer-common.sh"
# shellcheck source=graphify-common.sh
source "$SCRIPT_DIR/graphify-common.sh"

usage() {
  printf '%s\n' 'Usage: install-graphify-hooks.sh [--check|--help|-h]'
  printf '%s\n' 'Restores graphify post-commit/post-checkout hooks and the graph.json merge driver in the invoking checkout.'
  printf '%s\n' '--check reports what is missing without running graphify hook install.'
  printf '%s\n' 'Set AGENT_HARNESS_SKIP_GRAPHIFY=1 to opt out entirely.'
}

CHECK_ONLY=0
case "${1-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  --help | -h) usage; exit 0 ;;
  *) consumer_error "unknown option: $1"; exit 1 ;;
esac

[ "${AGENT_HARNESS_SKIP_GRAPHIFY:-0}" != 1 ] || exit 0
consumer_resolve || exit 0
graphify_declared || exit 0

report() {
  printf '%s\n' "$*"
  exit 0
}

if ! type -P graphify >/dev/null; then
  report "graphify is not on PATH, so its Git hooks and graph.json merge driver cannot be restored. Tell the user on your first turn and point them at the graphify install instructions; graph queries in this session may read a stale graph."
fi

# graphify writes into the hooks directory Git resolves, so a directory another
# tool owns is not ours to extend. Husky dispatches by filename from .husky/_,
# and a hooks directory inside the working tree is shared with every clone.
HOOKS_DIR=$(git -C "$WORKSPACE_ROOT" rev-parse --git-path hooks)
case "$HOOKS_DIR" in /*) ;; *) HOOKS_DIR="$WORKSPACE_ROOT/$HOOKS_DIR" ;; esac
[ -d "$HOOKS_DIR" ] || mkdir -p "$HOOKS_DIR"
HOOKS_DIR=$(cd "$HOOKS_DIR" && pwd -P)
hooks_dir_is_foreign() {
  case "$HOOKS_DIR" in */_) return 0 ;; esac
  case "$HOOKS_DIR/" in "$CONSUMER_GIT_COMMON_DIR"/*) return 1 ;; esac
  case "$HOOKS_DIR/" in "$WORKSPACE_ROOT"/*) ;; *) return 1 ;; esac
  [ -n "$(git -C "$WORKSPACE_ROOT" ls-files -- "${HOOKS_DIR#"$WORKSPACE_ROOT"/}" 2>/dev/null)" ]
}

# graphify hook install rewrites these files, so one that exists without being
# graphify's was written by someone else and must not be overwritten.
foreign_hook_files() {
  local hook found=()
  for hook in post-commit post-checkout; do
    [ ! -e "$HOOKS_DIR/$hook" ] || grep -q graphify "$HOOKS_DIR/$hook" 2>/dev/null ||
      found+=("$hook")
  done
  [ "${#found[@]}" -gt 0 ] || return 1
  printf '%s' "$(IFS=,; printf '%s' "${found[*]}")"
}

missing() {
  local hook gaps=()
  for hook in post-commit post-checkout; do
    grep -q graphify "$HOOKS_DIR/$hook" 2>/dev/null || gaps+=("the $hook hook")
  done
  [ -n "$(git -C "$WORKSPACE_ROOT" config --get merge.graphify.driver || true)" ] ||
    gaps+=("the merge.graphify.driver config")
  grep -q 'merge=graphify' "$WORKSPACE_ROOT/.gitattributes" 2>/dev/null ||
    gaps+=("the graph.json merge=graphify .gitattributes entry")
  [ "${#gaps[@]}" -gt 0 ] || return 1
  printf '%s' "$(IFS=,; printf '%s' "${gaps[*]}")"
}

GAPS=$(missing) || exit 0

if hooks_dir_is_foreign; then
  report "graphify's Git integration is incomplete (missing: ${GAPS//,/, }) and the hooks directory $HOOKS_DIR belongs to another hook manager, so it was not modified. Tell the user on your first turn and offer to integrate graphify through that manager."
fi
if FOREIGN=$(foreign_hook_files); then
  report "graphify's Git integration is incomplete (missing: ${GAPS//,/, }) and $HOOKS_DIR already holds ${FOREIGN//,/, } from another tool, so graphify hook install was not run. Tell the user on your first turn and offer to chain graphify into those hooks."
fi
if [ "$CHECK_ONLY" = 1 ]; then
  report "graphify's Git integration is incomplete (missing: ${GAPS//,/, }). Run graphify hook install in $WORKSPACE_ROOT."
fi

if ! OUTPUT=$(cd "$WORKSPACE_ROOT" && graphify hook install 2>&1); then
  printf '%s\n' "$OUTPUT" >&2
  report "graphify hook install failed, so graph rebuilds and graph.json merges are not wired up in this clone (missing: ${GAPS//,/, }). Tell the user on your first turn; do not retry it silently."
fi
GAPS=$(missing) || exit 0
report "graphify hook install ran but left part of its Git integration missing: ${GAPS//,/, }. Tell the user on your first turn rather than assuming graphs rebuild on commit."
