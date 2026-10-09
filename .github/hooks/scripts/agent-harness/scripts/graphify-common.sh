#!/usr/bin/env bash
# Shared graphify detection for the session hooks. Source after consumer_resolve.
#
# apm deploys the graphify skill to a target-specific path, so no skill
# directory is a portable signal. What is portable is the consumer's own
# declaration: a `Graphify corpora:` line in AGENTS.md, or committed graph
# files. Both graphify stages key off that, never off an install layout.

# The invoking checkout wins over the common one: a worktree's AGENTS.md
# describes the corpora on its own branch, which is the content being read.
graphify_identity_files() {
  local seen=""
  local identity
  for identity in "$WORKSPACE_ROOT/AGENTS.md" "$BEADS_ROOT/AGENTS.md"; do
    [ "$identity" != "$seen" ] || continue
    seen=$identity
    printf '%s\n' "$identity"
  done
}

# Corpora are comma separated and default to `research`, matching the contract
# AGENTS.md documents. Results land in GRAPHIFY_CORPORA.
graphify_corpora() {
  local identity line="" raw corpus
  GRAPHIFY_CORPORA=()
  while IFS= read -r identity; do
    line=$(grep -m1 -i '^Graphify corpora:' "$identity" 2>/dev/null) || line=""
    [ -z "$line" ] || break
  done < <(graphify_identity_files)
  if [ -n "$line" ]; then
    IFS=',' read -r -a raw < <(printf '%s\n' "${line#*:}")
    for corpus in "${raw[@]}"; do
      corpus="${corpus#"${corpus%%[![:space:]]*}"}"
      corpus="${corpus%"${corpus##*[![:space:]]}"}"
      while [ "${corpus%/}" != "$corpus" ]; do corpus="${corpus%/}"; done
      # A corpus names a directory under the checkout and nothing above it.
      case "$corpus" in "" | /* | *..*) continue ;; esac
      GRAPHIFY_CORPORA+=("$corpus")
    done
  fi
  [ "${#GRAPHIFY_CORPORA[@]}" -gt 0 ] || GRAPHIFY_CORPORA=(research)
}

# Declaring corpora is the project's own statement that it uses graphify;
# tracked graph files are the same statement made by the repository.
graphify_declared() {
  local identity
  while IFS= read -r identity; do
    ! grep -qi '^Graphify corpora:' "$identity" 2>/dev/null || return 0
  done < <(graphify_identity_files)
  [ -n "$(git -C "$WORKSPACE_ROOT" ls-files -- '*graphify-out/graph.json' 2>/dev/null)" ]
}
