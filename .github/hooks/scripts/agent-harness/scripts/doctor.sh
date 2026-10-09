#!/usr/bin/env bash
# Report whether this clone's agent-harness integration is actually healthy.
#
# Session start repairs what it can and prints the rest to stderr, where it
# competes with every other startup message and is gone by the second turn.
# This is the on-demand version of the same questions, with an exit status a
# human or a CI job can act on.
#
# It diagnoses only: no installs, no Git configuration writes, no store access.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$SCRIPT_DIR/consumer-common.sh"
# shellcheck source=graphify-common.sh
source "$SCRIPT_DIR/graphify-common.sh"

# Versions whose `bd context` output this harness has actually been read
# against. Keep in step with beads-common.sh.
VERIFIED_BD='1.2.2 1.3.0-rc.1 1.3.0'
MARKER='# agent-harness managed Session-Id wrapper v1'

usage() {
  cat <<'HELP'
Usage: doctor.sh [--quiet] [--help|-h]

Reports the health of this clone's agent-harness integration: required CLIs,
the bd version canary, the Session-Id Git hook, the apm target pin, and
graphify's hooks, merge driver and .gitattributes entry.

--quiet prints only problems.

Exit status: 0 when nothing is broken (warnings included), 1 when at least one
check failed, 2 when the consumer checkout could not be resolved at all.
HELP
}

QUIET=0
case "${1-}" in
  "") ;;
  --quiet) QUIET=1 ;;
  --help | -h) usage; exit 0 ;;
  *) consumer_error "unknown option: $1"; exit 1 ;;
esac

FAILED=0
ok()   { [ "$QUIET" = 1 ] || printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; FAILED=1; }

consumer_resolve || exit 2
ok "consumer checkout $BEADS_ROOT"

# --- required command-line tools -------------------------------------------
# git is implied by consumer_resolve. bd and jq are load-bearing for the Beads
# stage; graphify is optional until a corpus is declared.
for TOOL in jq python3 bd; do
  if type -P "$TOOL" >/dev/null; then
    ok "$TOOL on PATH ($(type -P "$TOOL"))"
  else
    fail "$TOOL is not on PATH; the session's Beads stage cannot run"
  fi
done

if type -P python3 >/dev/null; then
  PY_VERSION=$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")
  if [ -z "$PY_VERSION" ]; then
    fail "python3 is on PATH but will not report a version"
  elif python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)'; then
    ok "python3 $PY_VERSION (3.9+ required by bootstrap)"
  else
    fail "python3 $PY_VERSION is older than the 3.9 bootstrap requires"
  fi
fi

# --- bd version canary ------------------------------------------------------
# The session only trusts `bd context` shapes it has been read against, so an
# upgrade outside that set degrades startup. Say so here instead of letting a
# future session discover it.
if type -P bd >/dev/null; then
  BD_VERSION=$(bd version 2>/dev/null || bd --version 2>/dev/null || true)
  BD_VERSION=$(printf '%s' "$BD_VERSION" |
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' | head -n 1 || true)
  if [ -z "$BD_VERSION" ]; then
    warn "bd would not report a version; cannot confirm it is one of $VERIFIED_BD"
  else
    case " $VERIFIED_BD " in
      *" $BD_VERSION "*) ok "bd $BD_VERSION is an explicitly verified version" ;;
      *) warn "bd $BD_VERSION is outside the verified set ($VERIFIED_BD); the session will refuse its context and skip the Beads stage" ;;
    esac
  fi
fi

# --- Session-Id Git hook ----------------------------------------------------
HOOKS_DIR=$(git -C "$WORKSPACE_ROOT" rev-parse --git-path hooks)
case "$HOOKS_DIR" in /*) ;; *) HOOKS_DIR="$WORKSPACE_ROOT/$HOOKS_DIR" ;; esac
if [ -d "$HOOKS_DIR" ]; then
  HOOKS_DIR=$(cd "$HOOKS_DIR" && pwd -P)
  ok "git hooks directory $HOOKS_DIR"
  if [ ! -e "$HOOKS_DIR/prepare-commit-msg" ]; then
    fail "no prepare-commit-msg hook; commits carry no Session-Id. Run scripts/install-git-hooks.sh"
  elif grep -qxF "$MARKER" "$HOOKS_DIR/prepare-commit-msg"; then
    if [ -x "$HOOKS_DIR/agent-harness-session-id.sh" ]; then
      ok "prepare-commit-msg is the agent-harness wrapper"
    else
      fail "prepare-commit-msg delegates to agent-harness-session-id.sh, which is missing or not executable. Re-run scripts/install-git-hooks.sh"
    fi
  else
    warn "prepare-commit-msg exists but is not managed by agent-harness; commits may carry no Session-Id"
  fi
  if [ -d "$HOOKS_DIR/.agent-harness-install.lock" ]; then
    warn "an installer lock is present at $HOOKS_DIR/.agent-harness-install.lock; it is reclaimed automatically once its owner is provably gone. Never delete it by hand"
  fi
else
  fail "git reports a hooks directory that does not exist: $HOOKS_DIR"
fi

if [ -n "${COPILOT_AGENT_SESSION_ID:-}" ]; then
  ok "COPILOT_AGENT_SESSION_ID is set"
else
  warn "COPILOT_AGENT_SESSION_ID is unset; handoff writes are refused outside an agent session. This is expected in a plain shell"
fi

# --- apm target pin ---------------------------------------------------------
if [ ! -f "$WORKSPACE_ROOT/apm.yml" ]; then
  ok "no apm.yml; this consumer does not use apm"
elif grep -qE '^targets:' "$WORKSPACE_ROOT/apm.yml"; then
  ok "apm.yml pins a deployment target"
else
  warn "apm.yml has no targets: key, so apm auto-detects and can change its answer as runtime layouts appear. Run scripts/pin-apm-target.sh"
fi

# --- deploy directory mode --------------------------------------------------
# Committed and gitignored are both valid, but a half-and-half tree is not:
# the clone works for whoever ran apm install and fails for everyone else.
DEPLOY_TRACKED=()
DEPLOY_UNTRACKED=()
for DEPLOY in .github/instructions .github/agents .github/hooks .agents/skills; do
  [ -d "$WORKSPACE_ROOT/$DEPLOY" ] || continue
  if [ -n "$(git -C "$WORKSPACE_ROOT" ls-files -- "$DEPLOY")" ]; then
    DEPLOY_TRACKED+=("$DEPLOY")
  else
    DEPLOY_UNTRACKED+=("$DEPLOY")
  fi
done
if [ "${#DEPLOY_TRACKED[@]}" = 0 ] && [ "${#DEPLOY_UNTRACKED[@]}" = 0 ]; then
  warn "none of the apm deploy directories exist; nothing is installed in this checkout"
elif [ "${#DEPLOY_UNTRACKED[@]}" = 0 ]; then
  ok "deploy directories are committed; a fresh clone has the harness without apm install"
elif [ "${#DEPLOY_TRACKED[@]}" = 0 ]; then
  ok "deploy directories are not committed; every environment, including CI, must run apm install"
else
  warn "deploy directories are mixed (committed: ${DEPLOY_TRACKED[*]}; not committed: ${DEPLOY_UNTRACKED[*]}). Commit all of them or none; a partial tree works only for whoever ran apm install"
fi

# --- graphify ---------------------------------------------------------------
# Nothing below matters to a consumer that does not commit graph files.
if ! graphify_declared; then
  ok "no graphify corpora declared; graphify integration is not required"
elif ! type -P graphify >/dev/null; then
  fail "graphify corpora are declared but graphify is not on PATH; graphs cannot rebuild"
else
  GRAPHIFY_GAPS=()
  for HOOK in post-commit post-checkout; do
    grep -q graphify "$HOOKS_DIR/$HOOK" 2>/dev/null ||
      GRAPHIFY_GAPS+=("the $HOOK hook")
  done
  [ -n "$(git -C "$WORKSPACE_ROOT" config --get merge.graphify.driver || true)" ] ||
    GRAPHIFY_GAPS+=("the merge.graphify.driver config")
  grep -q 'merge=graphify' "$WORKSPACE_ROOT/.gitattributes" 2>/dev/null ||
    GRAPHIFY_GAPS+=("the graph.json merge=graphify .gitattributes entry")
  if [ "${#GRAPHIFY_GAPS[@]}" -gt 0 ]; then
    fail "graphify's Git integration is incomplete (missing: $(IFS=,; printf '%s' "${GRAPHIFY_GAPS[*]}" | sed 's/,/, /g')). Run graphify hook install in $WORKSPACE_ROOT"
  else
    ok "graphify hooks, merge driver and .gitattributes entry are all present"
  fi
  graphify_corpora
  for CORPUS in "${GRAPHIFY_CORPORA[@]}"; do
    if [ -f "$WORKSPACE_ROOT/$CORPUS/graphify-out/graph.json" ]; then
      ok "corpus $CORPUS has a built graph"
    else
      warn "corpus $CORPUS has no graphify-out/graph.json; queries against it will find nothing until it is built"
    fi
  done
fi

if [ "$FAILED" = 0 ]; then
  [ "$QUIET" = 1 ] || printf '\n%s\n' "No failures. Warnings above, if any, are not blocking."
  exit 0
fi
printf '\n%s\n' "At least one check failed. Fix the FAIL lines before relying on this clone's harness integration." >&2
exit 1
