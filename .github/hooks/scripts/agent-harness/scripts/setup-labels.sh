#!/usr/bin/env bash
# Optional example label catalog. Nothing runs this script implicitly.
#
# Creates an example Beads-aligned GitHub Issue label workflow.
# Preserves consumer label definitions unless reconciliation is opted into.
#
# Usage:
#   bash scripts/setup-labels.sh --dry-run [--overwrite-existing] [--repo [host/]owner/repo]
#   bash scripts/setup-labels.sh --apply [--overwrite-existing] [--repo [host/]owner/repo]
#
# Requires: gh CLI authenticated with write access to the selected consumer.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$SCRIPT_DIR/consumer-common.sh"
REPO=""
APPLY=0
DRY_RUN=0
OVERWRITE=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --overwrite-existing) OVERWRITE=1; shift ;;
    --repo)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { consumer_error "--repo requires a value"; exit 1; }
      REPO=$2; shift 2 ;;
    -h|--help)
      echo 'Usage: setup-labels.sh (--apply | --dry-run) [--overwrite-existing] [--repo [host/]owner/repo]'
      echo 'Creates missing labels only. Conflicting definitions abort before writes unless --overwrite-existing is supplied.'
      exit 0 ;;
    *) consumer_error "unknown argument: $1"; exit 1 ;;
  esac
done
[ "$((APPLY + DRY_RUN))" = 1 ] ||
  { consumer_error "optional label catalog is opt-in; pass exactly one of --apply or --dry-run"; exit 1; }
for dependency in gh jq; do
  command -v "$dependency" >/dev/null ||
    { consumer_error "required command not found: $dependency"; exit 1; }
done
REPO=$(consumer_github_repo "$REPO")
HOST=github.com
REPO_PATH=$REPO
case "$REPO" in */*/*) HOST=${REPO%%/*}; REPO_PATH=${REPO#*/} ;; esac
EXISTING=$(gh api --hostname "$HOST" --paginate --slurp "repos/$REPO_PATH/labels?per_page=100" |
  jq -ce '
    if type != "array" or any(.[]; type != "array") then
      error("expected paginated label arrays")
    else (add // []) end |
    if any(.[]; (.name | type) != "string" or (.color | type) != "string" or
       (.description != null and (.description | type) != "string")) then
      error("invalid existing label definition")
    elif (map(.name | ascii_downcase) | unique | length) != length then
      error("ambiguous duplicate existing label names")
    else . end
  ')
PLAN='[]'

create_label() {
  local name="$1"
  local color="$2"
  local description="$3"
  local current action
  current=$(printf '%s\n' "$EXISTING" | jq -c --arg name "$name" '
    [.[] | select((.name | ascii_downcase) == ($name | ascii_downcase))][0]
  ')
  if [ "$current" = null ]; then
    action=create
  elif printf '%s\n' "$current" | jq -e --arg color "$color" --arg description "$description" '
    (.color | ascii_downcase) == ($color | ascii_downcase) and
    (.description // "") == $description
  ' >/dev/null; then
    action=unchanged
  elif [ "$OVERWRITE" = 1 ]; then
    action=overwrite
  else
    action=conflict
  fi
  PLAN=$(printf '%s\n' "$PLAN" | jq -c --arg action "$action" --arg name "$name" --arg color "$color" \
    --arg description "$description" --argjson current "$current" '
    . + [{action: $action, name: $name, color: $color,
          description: $description, current: $current}]
  ')
}

echo "Planning optional labels for $REPO..."
echo

# ── Type labels (mirror Beads issue types) ────────────────────────────────────
echo "Types:"
create_label "epic"     "6E40C9" "Parent tracking issue for a collection of related tasks"
create_label "feature"  "0075CA" "A user-facing feature or functional improvement"
create_label "bug"      "D73A4A" "Something is broken or behaving incorrectly"
create_label "task"     "E4E669" "A unit of work (implementation, config, infra)"
create_label "research" "0E8A16" "Investigation or spike — produces a research document"

echo

# ── Priority labels (mirror Beads P0–P4) ─────────────────────────────────────
echo "Priority:"
create_label "P0" "B60205" "Critical — drop everything"
create_label "P1" "D93F0B" "High — do this sprint"
create_label "P2" "E99695" "Medium — do next sprint"
create_label "P3" "F9D0C4" "Low — do when capacity allows"
create_label "P4" "EDEDED" "Backlog — someday / maybe"

echo

# ── Ownership labels ──────────────────────────────────────────────────────────
echo "Ownership:"
create_label "owner:agent" "1D76DB" "Task assigned to the agent"
create_label "owner:human" "0052CC" "Task assigned to a human"
create_label "owner:both"  "5319E7" "Task shared between agent and human"

echo

# ── Status labels ─────────────────────────────────────────────────────────────
echo "Status:"
create_label "status:in-progress" "FBCA04" "Currently being worked on"
create_label "status:blocked"     "E11D48" "Blocked — cannot proceed without resolution"
create_label "status:review"      "7057FF" "Ready for review or waiting on feedback"

echo
printf '%s\n' "$PLAN" | jq -r '.[] | "\(.action): \(.name) (#\(.color)) - \(.description)",
  (if .action == "conflict" or .action == "overwrite"
   then "  existing: #\(.current.color) - \(.current.description // "")"
   else empty end)'
if printf '%s\n' "$PLAN" | jq -e 'any(.[]; .action == "conflict")' >/dev/null; then
  consumer_error "existing label definitions conflict; nothing changed. Review --dry-run --overwrite-existing before opting into reconciliation"
  exit 1
fi
if [ "$DRY_RUN" = 1 ]; then
  echo "Dry run: no labels changed."
  exit 0
fi
while IFS= read -r entry; do
  action=$(printf '%s\n' "$entry" | jq -r '.action')
  name=$(printf '%s\n' "$entry" | jq -r '.name')
  color=$(printf '%s\n' "$entry" | jq -r '.color')
  description=$(printf '%s\n' "$entry" | jq -r '.description')
  if [ "$action" = overwrite ]; then
    # Explicit opt-in authorizes changing this existing definition.
    gh label edit "$(printf '%s\n' "$entry" | jq -r '.current.name')" --repo "$REPO" \
      --color "$color" --description "$description"
  else
    # No --force: a label created concurrently must not be overwritten.
    gh label create "$name" --repo "$REPO" --color "$color" --description "$description"
  fi
done < <(printf '%s\n' "$PLAN" | jq -c '.[] | select(.action == "create" or .action == "overwrite")')
echo "Label plan applied to $REPO."
