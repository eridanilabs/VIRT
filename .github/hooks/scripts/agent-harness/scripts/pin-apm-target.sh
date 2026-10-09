#!/usr/bin/env bash
# Pin apm's deployment target in the consumer's apm.yml.
#
# apm resolves its target as --target > apm.yml targets: > apm config set >
# auto-detect. A consumer with no targets: key falls through to auto-detect,
# which asks or errors as soon as it sees more than one agent runtime layout -
# and `bd setup codex` creates .codex/ alongside the Copilot layout, so this
# happens to ordinary consumers of this harness. Pinning the key once makes
# every later `apm update` deterministic.
#
# Writing the key is the whole job: this never edits dependencies, never runs
# apm, and leaves an existing targets: alone.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=consumer-common.sh
source "$SCRIPT_DIR/consumer-common.sh"

DEFAULT_TARGET=copilot
# Layouts whose presence makes apm's auto-detection ambiguous.
RUNTIME_DIRS=(.codex .claude .cursor .windsurf .aider .gemini .github/copilot)

usage() {
  cat <<HELP
Usage: pin-apm-target.sh [--target <name>] [--check] [--help|-h]

Adds a top-level "targets:" key to the common checkout's apm.yml so apm never
auto-detects. Defaults to $DEFAULT_TARGET, this harness's runtime.
An existing targets: key is never rewritten; --check reports and writes nothing.
A consumer with no apm.yml has nothing to pin and is reported, not an error.
HELP
}

TARGET=$DEFAULT_TARGET
CHECK_ONLY=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1 ;;
    --target)
      shift
      [ "$#" -gt 0 ] || { consumer_error "--target needs a value"; exit 1; }
      TARGET=$1 ;;
    --target=*) TARGET=${1#--target=} ;;
    --help | -h) usage; exit 0 ;;
    *) consumer_error "unknown option: $1"; exit 1 ;;
  esac
  shift
done
[[ "$TARGET" =~ ^[a-z0-9][a-z0-9._-]*$ ]] ||
  { consumer_error "target must be a lowercase apm target name: $TARGET"; exit 1; }

consumer_resolve
MANIFEST="$BEADS_ROOT/apm.yml"
if [ ! -f "$MANIFEST" ]; then
  printf '%s\n' "apm: no apm.yml in $BEADS_ROOT; nothing to pin."
  exit 0
fi

# Only a plain single-document mapping can take a blind top-level append.
if grep -qE '^(---|\.\.\.)[[:space:]]*$' "$MANIFEST" || [ ! -s "$MANIFEST" ]; then
  consumer_error "apm.yml is empty or a multi-document stream; add 'targets: [$TARGET]' by hand"
  exit 1
fi

if grep -qE '^targets:' "$MANIFEST"; then
  printf '%s\n' "apm: apm.yml already pins targets; leaving it unchanged."
  exit 0
fi

# An ambiguous layout is why the key matters, so name it either way.
AMBIGUOUS=()
for DIR in "${RUNTIME_DIRS[@]}"; do
  [ ! -d "$BEADS_ROOT/$DIR" ] || AMBIGUOUS+=("$DIR")
done
if [ "${#AMBIGUOUS[@]}" -gt 1 ]; then
  printf 'apm: %s\n' "multiple agent runtime layouts present (${AMBIGUOUS[*]}); apm cannot auto-detect a target here." >&2
fi

if [ "$CHECK_ONLY" = 1 ]; then
  printf '%s\n' "apm: apm.yml does not pin targets; run pin-apm-target.sh --target $TARGET."
  exit 0
fi

# Publish by rename so a reader never sees a half-written manifest.
STAGE="$BEADS_ROOT/.apm-target-$$-$RANDOM"
trap 'rm -f "$STAGE"' EXIT
cat "$MANIFEST" >"$STAGE"
# A file not ending in a newline would otherwise glue the key to the last value.
[ -z "$(tail -c 1 "$STAGE")" ] || printf '\n' >>"$STAGE"
printf 'targets:\n  - %s\n' "$TARGET" >>"$STAGE"
chmod --reference="$MANIFEST" "$STAGE" 2>/dev/null || chmod 644 "$STAGE"
mv -f "$STAGE" "$MANIFEST"
trap - EXIT
printf '%s\n' "apm: pinned targets: [$TARGET] in apm.yml; commit it so every clone resolves the same target."
