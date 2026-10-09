#!/usr/bin/env bash
# Supported direct Beads route. No environment escapes this process.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=beads-common.sh
source "$SCRIPT_DIR/beads-common.sh"
for arg in "$@"; do
  case "$arg" in
    --db|--db=*|--database|--database=*|--server-*|-C|-C?*|--directory|--directory=*|--global|--global=*)
      beads_error "routing flag $arg is not supported; choose CWD/BEADS_DIR before invoking bd.sh"
      exit 1
      ;;
  esac
done
beads_resolve "$SCRIPT_DIR"
bd "$@"
