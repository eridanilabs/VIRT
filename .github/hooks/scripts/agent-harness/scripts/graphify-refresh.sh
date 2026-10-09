#!/usr/bin/env bash
# Rebuild graphify corpora whose docs changed during the session.
#
# Agents are told to run `graphify update <corpus>` after editing corpus *.md,
# but that is advisory and gets forgotten, so the next session queries a stale
# graph. This is the mechanical safety net: a no-LLM AST pass that runs only
# when a corpus doc is newer than that corpus's graph.json.
#
# It never performs a first build. A corpus with no graph.json is skipped with
# a note, so ending a session can never start work the user did not ask for.
# Every path exits 0; a stale graph must not fail the session.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$SCRIPT_DIR/consumer-common.sh"
# shellcheck source=graphify-common.sh
source "$SCRIPT_DIR/graphify-common.sh"

usage() {
  printf '%s\n' 'Usage: graphify-refresh.sh [--help|-h]'
  printf '%s\n' 'Rebuilds declared graphify corpora whose *.md files are newer than their graph.json.'
  printf '%s\n' 'Corpora come from the "Graphify corpora:" line in AGENTS.md (comma separated, default: research).'
  printf '%s\n' 'A corpus with no graph.json is never built here; run graphify update <corpus> deliberately.'
  printf '%s\n' 'Set AGENT_HARNESS_SKIP_GRAPHIFY=1 to opt out entirely.'
}

case "${1-}" in
  "") ;;
  --help | -h) usage; exit 0 ;;
  *) consumer_error "unknown option: $1"; exit 1 ;;
esac

[ "${AGENT_HARNESS_SKIP_GRAPHIFY:-0}" != 1 ] || exit 0
consumer_resolve || exit 0
graphify_declared || exit 0
type -P graphify >/dev/null || exit 0

graphify_corpora
for CORPUS in "${GRAPHIFY_CORPORA[@]}"; do
  GRAPH_OUT="$WORKSPACE_ROOT/$CORPUS/graphify-out/graph.json"
  if [ ! -f "$GRAPH_OUT" ]; then
    printf '%s\n' "graphify: no graph for $CORPUS; skipping (build it deliberately with graphify update $CORPUS)" >&2
    continue
  fi
  # maxdepth 1: a corpus is a flat document directory, and graphify-out itself
  # is always newer than the graph by construction.
  find "$WORKSPACE_ROOT/$CORPUS" -maxdepth 1 -name '*.md' -newer "$GRAPH_OUT" -print -quit |
    grep -q . || continue
  (cd "$WORKSPACE_ROOT" && graphify update "$CORPUS" >/dev/null) ||
    printf '%s\n' "graphify: end-of-session refresh failed for $CORPUS; its graph is stale." >&2
done
exit 0
