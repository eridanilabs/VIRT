#!/usr/bin/env bash
# Standalone alternative to APM deployment. Never updates project identity.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
BUNDLE_ROOT=$(cd "$SCRIPT_DIR/.." && pwd -P)
source "$SCRIPT_DIR/consumer-common.sh"

usage() {
  cat <<'HELP'
Usage: bootstrap-project.sh [consumer-path] [--dry-run] [--force] [--init-beads] [--skip-agents-md]

Installs the hook bundle at .github/hooks/scripts/agent-harness and its own
.github/hooks/agent-harness-hooks.json descriptor, matching APM's default name
so later APM installation replaces this descriptor instead of adding events.
--force replaces this bundle only, never existing AGENTS.md or identity files.
--init-beads explicitly initializes an absent common-checkout .beads store
using native bd init --non-interactive --skip-agents. Existing stores are
never initialized, migrated, enrolled, or reconfigured.
Requires Python 3.9+ and macOS/Linux atomic directory rename support.
All preflight checks finish before staging. Bundle and descriptor publication
is one atomic directory operation; optional AGENTS seeding is a separate,
rollback-on-error operation. Native bd init runs AFTER runtime publication:
its failure leaves the deployed runtime in place and may leave native state.
No skills, labels, dashboards, services, or remote issues are installed.
This deploys the runtime only, not a fully configured agent-harness package.
Run apm install in a consumer that declares agent-harness in apm.yml to install
the package's declared skills, personas, and instructions.
After publication, an existing apm.yml without a `targets:` key is pinned to
copilot so apm never auto-detects a target; see pin-apm-target.sh.
HELP
}

TARGET_ARG=""
DRY_RUN=0
FORCE=0
INIT_BEADS=0
SKIP_AGENTS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --init-beads) INIT_BEADS=1 ;;
    --skip-agents-md) SKIP_AGENTS=1 ;;
    --help|-h) usage; exit 0 ;;
    -*) consumer_error "unknown bootstrap option: $1"; exit 1 ;;
    *)
      [ -z "$TARGET_ARG" ] || { consumer_error "one consumer path is allowed"; exit 1; }
      TARGET_ARG=$1 ;;
  esac
  shift
done
if [ -n "$TARGET_ARG" ]; then cd "$TARGET_ARG"; fi
consumer_resolve
# Worktrees share configuration/store setup in the common checkout.
TARGET=$BEADS_ROOT
DEST="$TARGET/.github/hooks/scripts/agent-harness"
printf 'Consumer: %s (identity: %s)\nBundle: %s\n' "$TARGET" "$CONSUMER_SLUG" "$DEST"
command -v python3 >/dev/null ||
  { consumer_error "Python 3.9+ is required for transactional bootstrap"; exit 1; }
python3 -B "$SCRIPT_DIR/bootstrap-transaction.py" \
  "$BUNDLE_ROOT" "$TARGET" "$FORCE" "$DRY_RUN" "$INIT_BEADS" "$SKIP_AGENTS"
# Runtime publication is committed above. Pinning apm's target is a separate,
# fail-soft courtesy: a consumer with no apm.yml has nothing to pin, and a
# failure here must not be mistaken for a failed deployment.
PIN_ARGS=()
[ "$DRY_RUN" = 0 ] || PIN_ARGS+=(--check)
"$SCRIPT_DIR/pin-apm-target.sh" "${PIN_ARGS[@]+"${PIN_ARGS[@]}"}" ||
  consumer_error "could not pin apm targets in apm.yml; pass --target to apm yourself" || true
