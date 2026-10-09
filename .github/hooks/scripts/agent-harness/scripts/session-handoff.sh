#!/usr/bin/env bash
# Chained handoffs in the existing Beads store; Bash 3.2+ and jq.
# Usage and strict input requirements are printed by --help/invalid input.
set -euo pipefail
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/beads-common.sh
source "$SCRIPT_DIR/beads-common.sh"
# shellcheck source=scripts/handoff-common.sh
source "$SCRIPT_DIR/handoff-common.sh"

usage() {
  echo 'Usage: session-handoff.sh write [--slug lowercase-slug] [--supersede-global] [body] | show | list' >&2
  echo 'New write input: first nonblank line must be Session handoff: <nonempty summary> (exact prefix and space; summary must contain non-whitespace text). Blank means whitespace-only, including spaces/tabs.' >&2
  # shellcheck disable=SC2016
  echo 'write reads stdin if body is omitted. Required fields: Session IDs (project_session_id=<uuid> only - agent_session_id is auto-injected from $COPILOT_AGENT_SESSION_ID), Completed, Active branch, Open PRs, Worktrees, Next work, Review state, Blocked, Decisions.' >&2
  echo 'COPILOT_AGENT_SESSION_ID must be a UUID; invalid values fail before store access.' >&2
  echo 'Omit Supersedes from raw input; stored output prepends the generated Supersedes line before the unchanged body. Historical headings remain readable, not valid new-write templates.' >&2
  echo 'Supersedes chains per derived scope slug by default, so main, master, every other named branch, and each detached commit supersede only their own prior handoff (a fresh scope starts at (none)). An unborn HEAD still resolves to its real branch name. Legacy slug-free records are not migrated or inherited automatically; they stay readable via list and bd recall. Pass --supersede-global to explicitly chain onto the globally latest classifiable handoff while minting the new key in the current scope. Key sequencing is always derived from the globally latest record. Simultaneous sessions in the exact same derived scope are not ownership-isolated and are currently unsupported; cross-machine writers and native writers are not serialized by the helper'"'"'s local lock.' >&2
  echo 'show prints the latest handoff for the current derived scope only; use list plus bd recall to read another scope or a legacy slug-free record.' >&2
  echo 'An explicit --slug NAME is a trusted, unguarded override: it names whichever literal chain you pass, with no cross-branch collision protection (adding --supersede-global keeps NAME in the minted key but takes Supersedes from the globally latest classifiable handoff). This is the same unrestricted key choice --slug has always had, not new.' >&2
  return 0
}

handoff_unlock() {
  local status=$?
  if [ "${BEADS_ROUTE:-embedded}" = server ]; then beads_server_cleanup; fi
  if ! rmdir "$HANDOFF_LOCK"; then
    beads_error "could not release $HANDOFF_LOCK; inspect before retrying (a handoff may already be written)"
    exit 1
  fi
  exit "$status"
}

cmd_write() {
  local slug="" body="" records latest previous_record previous key actual status
  local attempts=0 explicit_slug=0 supersede_global=0
  while :; do
    case "${1:-}" in
      --slug)
        [ "$#" -ge 2 ] || { usage; exit 1; }
        slug=$2; shift 2
        explicit_slug=1
        if ! { [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#slug}" -le 40 ]; }; then
          beads_error "slug must be lowercase alphanumeric/hyphen, at most 40 characters"; exit 1
        fi
        ;;
      --supersede-global)
        supersede_global=1
        shift
        ;;
      --*) usage; exit 1 ;;
      *) break ;;
    esac
  done
  [ "$#" -le 1 ] || { usage; exit 1; }
  if [ "$explicit_slug" = 0 ]; then
    # Auto-derive from the current branch; still subject to the same
    # validation as an explicit slug, and failing exactly as that arm does
    # on mismatch. Blanking the slug would move a healthy automatic scope
    # into the legacy slug-free namespace, so it is never a fallback.
    slug=$(handoff_branch_slug) || exit 1
    if ! { [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#slug}" -le 40 ]; }; then
      beads_error "derived slug must be lowercase alphanumeric/hyphen, at most 40 characters; refusing to use an empty handoff scope"; exit 1
    fi
  fi
  if [ "$#" = 1 ]; then body=$1; else body=$(cat); fi
  # mkdir is atomic on the local filesystem. This lock covers the complete
  # read-predecessor/write/readback operation, not arbitrary native bd writes.
  HANDOFF_LOCK="$BEADS_DIR/.handoff-write.lock"
  until mkdir "$HANDOFF_LOCK" 2>/dev/null; do
    attempts=$((attempts + 1))
    [ "$attempts" -lt 50 ] ||
      { beads_error "cannot acquire $HANDOFF_LOCK (busy, stale, or unwritable); inspect before retrying, never steal a live lock"; exit 1; }
    sleep 0.1
  done
  trap handoff_unlock EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM
  handoff_validate_body "$body"
  local session_ids_line
  session_ids_line=$(printf '%s\n' "$body" | grep -E '^(- )?Session IDs: project_session_id=' | head -1)
  [ -n "$session_ids_line" ] ||
    { beads_error "internal error: Session IDs line not found after validation"; exit 1; }
  body=${body/"$session_ids_line"/"$session_ids_line agent_session_id=$AGENT_SESSION_ID"}
  # A single handoff_records() snapshot serves both lookups below, matching
  # the atomic-snapshot discipline session-start.sh uses on the read side -
  # two independent bd memories reads here could otherwise race a
  # concurrent write and see the per-slug and global views diverge.
  records=$(handoff_records)
  latest=$(handoff_latest_from "$records")
  # Key uniqueness must stay global to avoid collisions across slugs, so the
  # stamp/sequence numbering always comes from the global latest regardless
  # of which record the Supersedes line below points at.
  key=$(handoff_next_key "$latest")
  [ -z "$slug" ] || key="$key-$slug"
  if [ "$supersede_global" = 1 ]; then
    # Explicit compatibility override: continue the globally latest
    # classifiable chain while retaining this write's current scope slug.
    previous_record=$(handoff_latest_from "$records")
  else
    # Exact-scope chain: a fresh automatic or explicit slug has no
    # predecessor of its own and never inherits another scope implicitly.
    previous_record=$(handoff_latest_for_slug_from "$records" "$slug")
  fi
  previous=$(printf '%s\n' "$previous_record" | jq -r .key)
  body="Supersedes: ${previous:-(none)}
$body"
  if bd remember "$body" --key "$key" >/dev/null; then status=0; else status=$?; fi
  if [ "$status" != 0 ]; then
    printf 'Beads: remember failed; write may have persisted at allocated key %s (including a post-run auto-commit failure); inspect this key before retrying, no rollback was attempted\n' "$key" >&2
    exit "$status"
  fi
  # A sentinel preserves trailing newlines through command substitution.
  # jq -r adds one output newline; include that in the exact comparison.
  actual=$(handoff_recall "$key" && printf '.') ||
    { beads_error "write may have committed at $key, but readback failed; inspect before retrying"; exit 1; }
  [ "$actual" = "$body"$'\n.' ] ||
    { beads_error "readback differs at $key; inspect before retrying"; exit 1; }
  printf 'Wrote handoff: %s\n' "$key"
}

cmd_show() {
  local records slug latest key
  # Show the chain this session actually belongs to, matching cmd_write's
  # predecessor selection and session-start.sh's injection scope. Every
  # healthy automatic scope has a nonempty slug.
  records=$(handoff_records) || return 1
  slug=$(handoff_branch_slug) || return 1
  handoff_slug_valid "$slug" || return 1
  latest=$(handoff_latest_for_slug_from "$records" "$slug") || return 1
  key=$(printf '%s\n' "$latest" | jq -r .key) || return 1
  if [ -z "$key" ]; then echo '(none)'; else handoff_recall "$key"; fi
}

cmd_list() {
  local records
  records=$(handoff_records) || return 1
  printf '%s\n' "$records" | jq -r 'if length == 0 then "(none)" else .[].key end'
}

SUBCOMMAND=${1:-}
[ "$#" -eq 0 ] || shift
case "$SUBCOMMAND" in
  -h|--help) usage; exit 0 ;;
  write)
    if [ "$#" -eq 1 ] && { [ "$1" = --help ] || [ "$1" = -h ]; }; then
      usage
      exit 0
    fi
    ;;
esac
case "$SUBCOMMAND" in
  write|show|list) ;;
  *) usage; exit 1 ;;
esac
if [ "$SUBCOMMAND" != write ] && [ "$#" -ne 0 ]; then usage; exit 1; fi
if [ "$SUBCOMMAND" = write ]; then AGENT_SESSION_ID=$(handoff_agent_session_id) || exit 1; fi
beads_resolve "$SCRIPT_DIR"
case "$SUBCOMMAND" in
  write) cmd_write "$@" ;;
  show) cmd_show ;;
  list) cmd_list ;;
esac
