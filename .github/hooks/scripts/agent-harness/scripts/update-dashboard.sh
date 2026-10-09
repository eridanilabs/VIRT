#!/usr/bin/env bash
# GitHub issue bodies have no documented conditional-write contract.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$SCRIPT_DIR/consumer-common.sh"

usage() {
  cat <<'HELP'
Usage: update-dashboard.sh --dry-run [--section <heading>] <command> [arguments]

Commands:
  add-row <status> <repo> <url> <description> <timestamp>
  update-row <pattern> [--status <text>] [--description <text>] [--timestamp <text>] [--link <url>]
  remove-row <pattern>
  add-note <text>
  refresh-timestamp

Prints a proposed Markdown body to stdout; NEVER changes the issue.
Row commands default to the exact "Active Work Streams" heading and require
one five-column Status/Repo table. Updates/removals require exactly one
matching data row. Headers, separators, fenced content, and other sections
are never row candidates. add-note defaults to the "Notes" heading.

DASHBOARD_REPO overrides the consumer origin; DASHBOARD_ISSUE is required.
Direct writes are disabled: GitHub does not document conditional issue PATCH
requests, so read/compare/edit cannot protect concurrent human or API edits.
Do not pipe this snapshot into gh issue edit; review and reconcile manually.
HELP
}

case "${1:-}" in
  help|--help|-h) usage; exit 0 ;;
  --dry-run) shift ;;
  *)
    consumer_error "dashboard writes are disabled: no server-enforced conditional issue update; use --dry-run for a proposal"
    exit 1 ;;
esac
[ "$#" -gt 0 ] || { usage >&2; exit 1; }
for dependency in gh python3; do
  command -v "$dependency" >/dev/null ||
    { consumer_error "required command not found: $dependency"; exit 1; }
done
[[ "${DASHBOARD_ISSUE:-}" =~ ^[1-9][0-9]*$ ]] ||
  { consumer_error "optional dashboard requires DASHBOARD_ISSUE=<positive issue number>"; exit 1; }
REPO=$(consumer_github_repo "${DASHBOARD_REPO:-}")
gh auth status >/dev/null 2>&1 ||
  { consumer_error "gh is not authenticated; run gh auth login"; exit 1; }

gh issue view "$DASHBOARD_ISSUE" --repo "$REPO" --json body |
  python3 "$SCRIPT_DIR/dashboard-edit.py" "$@"
printf '%s\n' 'Dashboard proposal only; no issue was changed. Reconcile concurrent edits before any manual change.' >&2
