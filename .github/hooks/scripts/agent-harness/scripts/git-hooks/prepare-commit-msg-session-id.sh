#!/usr/bin/env sh
# Deterministically append a Session-Id trailer to every commit message,
# so provenance does not depend on an agent remembering to type it.
#
# COPILOT_AGENT_SESSION_ID comes from the CLI environment. The app-level
# project_session_id remains agent-supplied in handoffs, never inferred
# from a private application database or invented for this trailer.
#
# Installed by scripts/install-git-hooks.sh alongside prepare-commit-msg
# in Git's configured hooks directory (including core.hooksPath).
# Self-healing: the bundled session-start.sh runs the installer on every
# session start (idempotent, near-instant, non-fatal), so a fresh clone or
# rebuild on a different machine picks up this hook automatically -
# Git's default hooks directory is never checked out from a clone, so the hook
# would silently vanish on any new machine. No manual install step is
# required in normal operation; install-git-hooks.sh remains available to
# run by hand for a one-off checkout that hasn't started a session yet.
#
# Git's prepare-commit-msg contract: $1=msg file, $2=source, $3=sha (commit only).
set -eu

msg_file=$1

# Nothing to inject if this hook runs outside a live Copilot CLI session
# (e.g. a human committing by hand) or if run via the pre-existing sample
# hooks git already ships (those never reach here).
[ -n "${COPILOT_AGENT_SESSION_ID:-}" ] || exit 0

if [ "${#COPILOT_AGENT_SESSION_ID}" -ne 36 ] ||
   ! printf '%s\n' "$COPILOT_AGENT_SESSION_ID" |
     LC_ALL=C grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
  printf '%s\n' 'Session-Id hook: COPILOT_AGENT_SESSION_ID must be a UUID' >&2
  exit 1
fi

# A chained hook can append another block after an existing provenance line.
grep -qi '^Session-Id:' "$msg_file" && exit 0

# Git preserves trailer grouping, existing provenance, comments, and patch text.
git -c trailer.separators=: interpret-trailers --in-place --where end \
  --if-exists doNothing --if-missing add \
  --trailer "Session-Id: agent_session_id=$COPILOT_AGENT_SESSION_ID" -- "$msg_file"
