#!/usr/bin/env bash
# Consume SDK input and inject one handoff. Hook exports do not reach tools.
#
# Startup runs independent stages: git-hook provenance, then Beads resume.
# A stage whose prerequisites are absent warns on stderr and contributes a
# short note, so a project that has not run the init skill still receives
# context and still gets the remaining stages. Corrupt state is different
# from absent state and remains a hard failure: claiming a fresh session
# over an unreadable store would hide real handoff history.
set -euo pipefail
# Capture the SDK payload instead of discarding it: the initial prompt decides
# whether a fresh, non-trunk scope should offer to fetch open tasks. The
# payload is advisory, so empty, missing or invalid input must never abort the
# hook; it simply means "no prompt".
#
# A truly closed fd 0 needs an explicit probe. Inside $(...) bash hands the
# command substitution's pipe read end the free fd 0, so `cat` then reads its
# own pipe and never sees EOF: the hook hangs where it used to fail fast. Duplicating fd 0
# onto another descriptor fails with EBADF when it is closed (a bare `<&0`
# redirect is a no-op onto itself and proves nothing), and costs nothing when
# it is open. The probe's descriptor is released before reading.
HOOK_INPUT=""
if { exec 9<&0; } 2>/dev/null; then
  exec 9<&-
  HOOK_INPUT=$(cat) || HOOK_INPUT=""
fi
export PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin"
export LC_ALL=C
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/beads-common.sh
source "$SCRIPT_DIR/scripts/beads-common.sh"
# shellcheck source=scripts/handoff-common.sh
source "$SCRIPT_DIR/scripts/handoff-common.sh"
# Include installer lock waits in the configured 15-second startup budget.
# Reserve two seconds for JSON formatting and cleanup.
# Consumed by the dynamically sourced server route, not exported to native bd.
if ! BEADS_SERVER_DEADLINE=$(beads_deadline_after 13); then
  # Zero marks failed clock initialization, not a missing/default budget.
  # Embedded startup can still skip pull, warn and emit local context;
  # the resolver must reject this sentinel before initializing a server route.
  BEADS_SERVER_DEADLINE=0
fi
# jq is one of the prerequisites a project may be missing, and the hook still
# owes the runtime one valid JSON object. Prefer jq, fall back to shell
# escaping of the fields this hook actually produces.
emit_additional_context() {
  local context=$1
  if type -P jq >/dev/null; then
    jq -n --arg ctx "$context" '{additionalContext: $ctx}'
    return
  fi
  context=$(printf '%s' "$context" | LC_ALL=C tr -d '\000-\010\013\014\016-\037')
  context=${context//\\/\\\\}
  context=${context//\"/\\\"}
  context=${context//$'\t'/\\t}
  context=${context//$'\r'/\\r}
  context=${context//$'\n'/\\n}
  printf '{"additionalContext": "%s"}\n' "$context"
}

# True only when the payload carries a non-blank string prompt. The Copilot SDK
# spells the field initialPrompt; the VS Code-compatible payload spells it
# initial_prompt. Any non-blank string counts, slash commands included;
# whitespace-only is blank. Without jq the payload cannot be read, which is
# the same as no prompt.
HAS_PROMPT=0
if type -P jq >/dev/null; then
  PROMPT_PRESENT=$(printf '%s' "$HOOK_INPUT" | jq -r '
    [.initialPrompt?, .initial_prompt?] | map(select(type == "string" and test("\\S"))) | length > 0
  ' 2>/dev/null) || PROMPT_PRESENT=""
  [ "$PROMPT_PRESENT" != true ] || HAS_PROMPT=1
fi

# Stage 1: self-heal Git's configured hooks; default hooks do not survive a
# fresh clone. Installation is local and idempotent. Failures warn without
# blocking resume.
if ! "$SCRIPT_DIR/scripts/install-git-hooks.sh" >/dev/null; then
  printf '%s\n' 'Agent harness: Session-Id git hook installation failed; continuing session startup.' >&2
fi

# Stage 2: restore graphify's local Git integration. Only a consumer that
# commits graph files is touched, and anything the stage cannot do safely is
# reported in the injected context instead of being retried silently.
GRAPHIFY_NOTE=""
if ! GRAPHIFY_NOTE=$("$SCRIPT_DIR/scripts/install-graphify-hooks.sh" 2>/dev/null); then
  GRAPHIFY_NOTE=""
  printf '%s\n' 'Agent harness: graphify hook check failed; continuing session startup.' >&2
fi
# Stage 3: Beads resume. Status 2 means a prerequisite is absent - bd, jq or
# .beads - which is the state of any project that has not run the init skill.
# That must not cost the session its remaining stages or its context. Any
# other failure means this checkout is misconfigured or unsafe to route, and
# continuing would hide it, so it stays fatal.
BEADS_READY=1
BEADS_STATUS=0
# The ready-task list is injected only for a trunk scope (main/master); see
# the decision after the handoff has been selected.
SHOW_READY=0
READY=""
beads_resolve "$SCRIPT_DIR" || BEADS_STATUS=$?
if [ "$BEADS_STATUS" != 0 ]; then
  [ "$BEADS_STATUS" = 2 ] || exit "$BEADS_STATUS"
  BEADS_READY=0
  printf '%s\n' 'Agent harness: Beads resume unavailable; continuing session startup without task context.' >&2
fi

if [ "$BEADS_READY" = 1 ]; then
  # Offline sync is nonfatal, but never indistinguishable from a successful pull.
  # No bd prime: startup only needs targeted handoff and task reads.
  SYNC_NOTE=""
  if [ "$BEADS_SERVER_DEADLINE" = 0 ] || ! beads_pull_bounded; then
    SYNC_NOTE="Beads pull failed or timed out; this resume reflects local state only."
    printf '%s\n' "$SYNC_NOTE" >&2
  fi
  # Handoff scope resolution (never inherits another scope's handoff) is unindented to keep its multi-line strings byte-identical.
# handoff_branch_slug reports three outcomes, and conflating any two of them
# is a scope error:
#   - a slug: a named branch or detached commit, which reads only its own
#     chain;
#   - a nonzero status: HEAD could not be read at all (repository
#     corruption). The scope is then *unknown*, which is not the same as
#     a legacy slug-free record, so this case must never read one as a
#     fallback. That would inject another scope's narrative into a session
#     whose real scope nobody knows.
# Unknown scope therefore resumes nothing, but it is not fatal: like the
# git-hook install and the Beads pull above, it warns (handoff_branch_slug
# has already written the Git diagnostic to stderr) and still emits the
# handoff-scope note and resume note, which a corrupt HEAD is no reason to
# discard. An unknown scope is not trunk, so it carries no ready-task list. The
# same applies to a store that cannot be read: the scope's chain is then
# unknown for a different reason, and aborting would leave the host - which has
# been promised JSON on stdout - with an empty stream and no resume context at
# all.
# Capture the status with a plain `||` and never through a pipeline: under
# pipefail only the last command's status is observed, so a pipeline here
# would mask the failure and could silently select an invented scope.
# Extracting a key from a lookup result cannot fail on content:
# handoff_records_payload() has already validated every record, and every
# lookup emits a {key,stamp,sequence} default, so jq always has a well-formed
# object to read. Only the execution environment can fail these - notably a
# full or read-only TMPDIR, which is why they use a pipe rather than a
# here-string (bash 3.2, this bundle's floor, materializes the here-string
# form through a temporary file). The host was promised JSON on stdout, so a
# failure degrades rather than aborting with an empty stream. How it degrades
# depends on what failed:
#
#   - The PRIMARY lookup and key extraction decide what gets injected. If
#     either fails, this scope's own chain is unknown, which is not the same
#     as empty, so they route through scope_indeterminate(). Reporting
#     "fresh" there would be a confirmed-absence claim built on missing data.
#   - The DECORATIVE cross-scope pointers only name another chain. A failure
#     suppresses the pointer and records that it was suppressed, so the note
#     can say so rather than implying no other scope holds a handoff.
POINTER_UNREADABLE=0
POINTER_DEFAULT='{"key":"","stamp":"","sequence":0}'
pointer_read_failed() {
  POINTER_UNREADABLE=1
  printf '%s\n' "Agent harness: could not read $1 from the handoff snapshot; continuing without it." >&2
}

# Every indeterminate cause routes through this one helper so the note, the
# suppressed handoff and the resume wording can never drift apart.
scope_indeterminate() {
  SCOPE_UNRESOLVED=1
  SCOPE_CAUSE=$1
  SCOPE_NOTE="**Handoff scope**: indeterminate ($SCOPE_CAUSE - no handoff is being resumed because an unknown scope must not inherit another scope's narrative)"
}
SCOPE_UNRESOLVED=0
SCOPE_CAUSE=""
SCOPE_NOTE=""
SCOPE_DIAGNOSTIC=""
SCOPE_OUTPUT=""
BRANCH_SLUG=""
# Pin the scope BEFORE deriving the slug, not just after. The slug and the
# scope read were two independent Git reads, so a branch switch landing
# between them left the pinned scope describing a different branch than the
# slug it was supposed to be pinning - and the later comparison, seeing that
# scope unchanged, read as "same scope". Bracketing the derivation closes
# that window: the scope identity is read, the slug derived, the identity
# read again, and the resolved scope is accepted only when the two agree.
#
# IDENTITY, not the full token: the bracket's question is "is this still the
# same scope", and the token also changes when the scope merely MOVES. An
# ordinary commit landing on the checked-out branch during slug derivation
# changed the token, so the bracket declared a legitimate branch session
# indeterminate and suppressed its handoff. A real branch switch, and any
# move between the attached/unborn/detached classes, still changes the
# identity and is still caught.
SCOPE_IDENTITY=""
SCOPE_IDENTITY_PINNED=""
# A failure here is NOT reported yet. The slug derivation below re-reads the
# same HEAD and captures Git's authoritative diagnostic for the note, so
# short-circuiting on this read would replace a specific, quoted cause with a
# generic one. An unreadable pinned identity still fails closed - it cannot
# compare equal at the bracket-close below - so deferring the report costs no
# safety. Its stderr is suppressed for the same reason: this read is an
# internal pin, and letting it echo a fault the slug derivation is about to
# report authoritatively shows the operator one fault twice.
SCOPE_IDENTITY_PINNED=$(handoff_scope_identity 2>/dev/null) || SCOPE_IDENTITY_PINNED=""
# Capture stdout and stderr from a SINGLE invocation. A second, status-
# discarding call made purely to harvest stderr could succeed, or fail
# differently, under an intermittent or stateful Git fault, so the quoted
# note could describe a failure other than the authoritative one. One call
# cannot drift from itself. Temporary-file creation is banned in this
# bundle, so the streams are merged rather than separated; the merge is made safe by validating the
# success-path output through the same slug guard the derivation itself
# applies, so any stderr contamination fails closed into the indeterminate
# state instead of silently becoming a slug.
if [ "$SCOPE_UNRESOLVED" = 0 ]; then
  SLUG_UNRESOLVED=0
  SCOPE_OUTPUT=$(handoff_branch_slug 2>&1) || SLUG_UNRESOLVED=1
  if [ "$SLUG_UNRESOLVED" = 0 ]; then
    if [ -n "$SCOPE_OUTPUT" ] && handoff_slug_valid "$SCOPE_OUTPUT"; then
      BRANCH_SLUG=$SCOPE_OUTPUT
    else
      BRANCH_SLUG=""
      SLUG_UNRESOLVED=1
    fi
  fi
  if [ "$SLUG_UNRESOLVED" = 1 ]; then
    BRANCH_SLUG=""
    # Capturing stderr took it off the stream it was written to, so put it
    # back: the warning must still reach the operator exactly once. Guarded so
    # a silent failure does not emit a blank line.
    [ -z "$SCOPE_OUTPUT" ] || printf '%s\n' "$SCOPE_OUTPUT" >&2
    # additionalContext is read by the agent, which cannot see this hook's
    # stderr, so quote the real Git diagnostic into the note as well.
    SCOPE_DIAGNOSTIC=${SCOPE_OUTPUT%%$'\n'*}
    scope_indeterminate "this repository's HEAD could not be read, so the branch this session is on is unknown${SCOPE_DIAGNOSTIC:+; Git reported: $SCOPE_DIAGNOSTIC}"
  fi
fi
# Close the bracket. The scope this hook will act on is the pair (slug,
# identity), and it is only trustworthy if the scope held still across the
# whole derivation. Revalidated again immediately before the body is
# accepted, below, which covers the store I/O that follows.
if [ "$SCOPE_UNRESOLVED" = 0 ]; then
  if ! SCOPE_IDENTITY=$(handoff_scope_identity); then
    SCOPE_IDENTITY=""
    scope_indeterminate "this repository's HEAD could not be read when pinning the resolved scope, so the branch this session is on is unknown"
  elif [ -z "$SCOPE_IDENTITY_PINNED" ] || [ "$SCOPE_IDENTITY" != "$SCOPE_IDENTITY_PINNED" ]; then
    # An empty pinned identity means the read before the derivation failed
    # while the derivation itself succeeded: the pair cannot be shown to
    # describe one branch, which is exactly the unclassifiable state the
    # invariant forbids treating as membership.
    SCOPE_IDENTITY=""
    BRANCH_SLUG=""
    printf '%s\n' "Agent harness: this worktree's HEAD changed while the handoff scope was being resolved; resuming no handoff." >&2
    scope_indeterminate "this worktree's HEAD changed while the branch this session is on was being resolved, so the resolved scope may describe a different branch"
  fi
fi
# Skip the lookup entirely when the scope is unknown - there is no chain to
# read, and this path must not be made to depend on the record read either.
# Otherwise take exactly one handoff_records_payload() / bd memories read for this
# hook invocation: a handoff written between a branch-scoped lookup and a
# separate global fallback read could otherwise make the two calls see
# different snapshots and leave the emitted scope note inconsistent with
# what was injected.
RECORDS=""
HANDOFF_SKIPPED=0
HANDOFF_AMBIGUOUS=0
HANDOFF_RECORDS=""
SKIPPED_NOTE=""
if [ "$SCOPE_UNRESOLVED" = 0 ]; then
  if RECORDS_PAYLOAD=$(handoff_records_payload) && handoff_payload_split "$RECORDS_PAYLOAD"; then
    RECORDS=$HANDOFF_RECORDS
    handoff_warn_skipped "$HANDOFF_SKIPPED"
    handoff_warn_ambiguous "$HANDOFF_AMBIGUOUS"
  else
    # bd memories can fail on Dolt lock contention or a server-route timeout,
    # and jq rejects a malformed store. Either way this scope's chain is
    # unknown, which is emphatically not the same as empty, so degrade into
    # the indeterminate state rather than aborting with nothing on stdout.
    printf '%s\n' 'Agent harness: handoff records could not be read; resuming no handoff.' >&2
    scope_indeterminate "this session's handoff records could not be read from the Beads store, so the scope's chain is unknown"
  fi
fi
# An excluded key is one this reader could not classify into any scope; an
# ambiguous one matched this prefix but could not be resolved to this
# project's namespace. Both counts reach the operator on stderr, which the
# agent never sees, so every scope note carries the same fact in text - the
# RESOLVED notes as much as the "fresh" ones. A resolved note is arguably the
# more dangerous omission: the agent acts on a possibly-stale record while a
# newer, unclassifiable key sits in the store unmentioned. Still not
# indeterminate: a stray key is not a broken store, and the records that were
# read are trustworthy.
if [ "${HANDOFF_SKIPPED:-0}" != 0 ]; then
  SKIPPED_NOTE="; $HANDOFF_SKIPPED key(s) under this prefix could not be classified and were excluded - this scope may have a handoff stored under a malformed key"
fi
if [ "${HANDOFF_AMBIGUOUS:-0}" != 0 ]; then
  SKIPPED_NOTE="$SKIPPED_NOTE; $HANDOFF_AMBIGUOUS key(s) begin with this prefix but could not be resolved to this project's namespace and were skipped - they may belong to a longer-named project, or be malformed keys of this one"
fi
# When any key was skipped, "Latest handoff" would overstate what this read
# can see: a newer handoff may exist under a key that was never classified.
# Qualify the label so the claim is true as written.
HANDOFF_LABEL_QUALIFIER=""
if [ -n "$SKIPPED_NOTE" ]; then
  HANDOFF_LABEL_QUALIFIER=" classifiable"
fi
if [ "$SCOPE_UNRESOLVED" = 1 ]; then
  HANDOFF_KEY=""
  HANDOFF_RECORD=""
elif [ -n "$BRANCH_SLUG" ]; then
  # Every healthy automatic scope is its own workstream identity. If it has
  # no handoff of its own, it must NOT inherit an unrelated scope's narrative
  # just because that record is globally latest.
  LATEST=""
  HANDOFF_KEY=""
  if ! LATEST=$(handoff_latest_for_slug_from "$RECORDS" "$BRANCH_SLUG"); then
    printf '%s\n' "Agent harness: this branch's handoff chain could not be read; resuming no handoff." >&2
    scope_indeterminate "this branch's handoff chain could not be read from the snapshot (slug: $BRANCH_SLUG), so whether it holds a handoff is unknown"
  elif ! HANDOFF_KEY=$(printf '%s\n' "$LATEST" | jq -r .key); then
    printf '%s\n' 'Agent harness: the selected handoff key could not be read; resuming no handoff.' >&2
    scope_indeterminate "the handoff key selected for this session's scope could not be read from the snapshot, so whether this scope holds a handoff is unknown"
  fi
  if [ "$SCOPE_UNRESOLVED" = 1 ]; then
    HANDOFF_KEY=""
    HANDOFF_RECORD=""
  elif [ -n "$HANDOFF_KEY" ]; then
    HANDOFF_RECORD=$LATEST
    SCOPE_NOTE="**Handoff scope**: branch-scoped (slug: $BRANCH_SLUG)$SKIPPED_NOTE"
  else
    HANDOFF_RECORD=$LATEST
    SCOPE_NOTE="**Handoff scope**: fresh (no prior handoff for slug: $BRANCH_SLUG - not inheriting another branch's context)$SKIPPED_NOTE"
    # Name (without injecting the body of) the records this session could
    # consciously resume instead. Both views come from the same $RECORDS
    # snapshot above, never a second bd memories read.
    # Each lookup is its own guarded assignment, never the left side of a
    # pipeline: under pipefail only the pipeline's last status is observed,
    # and jq on empty input exits 0 with empty output, so an unguarded
    # failure would silently suppress the pointer with nothing recorded.
    GLOBAL_LATEST_KEY=""
    if ! GLOBAL_LATEST=$(handoff_latest_from "$RECORDS"); then
      GLOBAL_LATEST=$POINTER_DEFAULT
      pointer_read_failed "the global pointer"
    elif ! GLOBAL_LATEST_KEY=$(printf '%s\n' "$GLOBAL_LATEST" | jq -r .key); then
      GLOBAL_LATEST_KEY=""
      pointer_read_failed "the global pointer"
    fi
    if [ -n "$GLOBAL_LATEST_KEY" ]; then
      SCOPE_NOTE="$SCOPE_NOTE; most recent handoff anywhere is \`$GLOBAL_LATEST_KEY\` (NOT inherited here; this is the record \`session-handoff.sh write --supersede-global\` would supersede while still minting in the current scope; bd recall it explicitly if that is the work you mean)"
    fi
    LEGACY_LATEST_KEY=""
    if ! LEGACY_LATEST=$(handoff_latest_unslugged_from "$RECORDS"); then
      LEGACY_LATEST=$POINTER_DEFAULT
      pointer_read_failed "the legacy slug-free pointer"
    elif ! LEGACY_LATEST_KEY=$(printf '%s\n' "$LEGACY_LATEST" | jq -r .key); then
      LEGACY_LATEST_KEY=""
      pointer_read_failed "the legacy slug-free pointer"
    fi
    if [ -n "$LEGACY_LATEST_KEY" ] && [ "$LEGACY_LATEST_KEY" != "$GLOBAL_LATEST_KEY" ]; then
      SCOPE_NOTE="$SCOPE_NOTE; latest legacy slug-free handoff is \`$LEGACY_LATEST_KEY\` (NOT inherited automatically; bd recall it explicitly if that is the work you mean)"
    elif [ -n "$LEGACY_LATEST_KEY" ]; then
      SCOPE_NOTE="$SCOPE_NOTE; that globally latest record is legacy slug-free and is still not inherited automatically"
    fi
    if [ "$POINTER_UNREADABLE" = 1 ]; then
      SCOPE_NOTE="$SCOPE_NOTE; a cross-scope pointer could not be read, so this note may not name every other scope that holds a handoff"
    fi
  fi
fi
if [ "$SCOPE_UNRESOLVED" = 0 ]; then
  # Re-read the scope this hook resolved against. Everything between that
  # resolution and this point is store I/O, during which the worktree can be
  # switched to another branch: injecting here would then hand branch A's
  # narrative to a branch B session, the exact cross-scope leak this scoping
  # exists to prevent. A changed OR unreadable identity fails closed.
  #
  # Identity, not the full token, for the same reason the bracket above uses
  # it: the question is whether this is still the same scope, and a commit
  # landing on the checked-out branch during the store reads moves the scope
  # without changing which scope it is. The handoff selected belongs to this
  # branch either way.
  #
  # This runs unconditionally, NOT only when a key was selected. The absence
  # arm needs it just as much: a session starting on a handoff-less branch,
  # switched to main mid-read, would otherwise be told as fact that no prior
  # handoff exists while main's chain holds one. The governing
  # invariant forbids both halves - an unclassifiable state must never be
  # treated as positive membership in a scope, and must never be reported as
  # a confirmed absence either - so the fresh claim is as much a claim as the
  # injected one.
  SCOPE_IDENTITY_NOW=$(handoff_scope_identity) || SCOPE_IDENTITY_NOW=""
  if [ -z "$SCOPE_IDENTITY_NOW" ] || [ "$SCOPE_IDENTITY_NOW" != "$SCOPE_IDENTITY" ]; then
    printf '%s\n' "Agent harness: this worktree's HEAD changed or became unreadable while the handoff was being read; resuming no handoff." >&2
    scope_indeterminate "this worktree's HEAD changed or became unreadable between resolving the handoff scope and injecting it, so the handoff selected earlier may belong to a different branch"
    HANDOFF_KEY=""
  fi
fi
if [ -n "$HANDOFF_KEY" ]; then
  # Inject the body carried by the record this hook just selected, NOT a
  # second store read of the same key. A fresh `handoff_recall` here opened a
  # TOCTOU window: a writer replacing that key's value between the snapshot
  # and the recall had its body injected, even though the record that was
  # actually validated and scope-selected was the snapshot's. (Deletion was
  # already safe - recall simply failed - but replacement with another
  # nonempty string was not.) The nonempty-string validation handoff_recall
  # applied is kept here; a record whose body is missing or empty leaves the
  # scope's narrative unknown for the same reason an unreadable chain does,
  # so it routes through the same degrade rather than aborting stdout.
  if HANDOFF_BODY=$(printf '%s\n' "$HANDOFF_RECORD" |
      jq -er '.value | select(type == "string" and length > 0)'); then
    HANDOFF_SECTION="**Latest${HANDOFF_LABEL_QUALIFIER} handoff** (\`$HANDOFF_KEY\`):

$HANDOFF_BODY"
    RESUME_NOTE="You are resuming a prior session. On your first turn, briefly acknowledge the handoff and confirm scope with the user before starting new work. If the user's first message is unrelated to the handoff, treat the handoff as background context and proceed with their request."
  else
    printf '%s\n' "Agent harness: the selected handoff record carried no usable body; resuming no handoff." >&2
    scope_indeterminate "the handoff record \`$HANDOFF_KEY\` selected for this session's scope could not be read back from the Beads store"
    HANDOFF_KEY=""
  fi
fi
# The ready-task list is trunk context. It is injected only when the resolved
# scope is exactly main or master (handoff present or absent): there it is the
# only orientation a fresh session has. A feature branch or detached HEAD is a
# narrower workstream, and an unrelated global top-ten would read as an
# assignment, so it gets its own handoff or nothing. An indeterminate scope is
# unknown, not trunk. This runs after every step that can still turn the scope
# indeterminate (the identity re-read and the body read-back above).
#
# Exact slugs, not a main-*/master-* prefix: a branch named main-fix derives
# the slug main-fix-<hash>, which a prefix test would mistake for trunk.
# Derivation matches handoff_branch_slug: <name>-<first 8 hex of sha256(name)>.
if [ "$SCOPE_UNRESOLVED" = 0 ] && [ -n "$BRANCH_SLUG" ]; then
  for TRUNK in main master; do
    if TRUNK_HASH=$(printf '%s' "$TRUNK" | handoff_sha256) && [ "$BRANCH_SLUG" = "$TRUNK-${TRUNK_HASH:0:8}" ]; then
      SHOW_READY=1
    fi
  done
fi
if [ "$SHOW_READY" = 1 ]; then
  if ! READY=$(bd ready --json | jq -er '
    if type != "array" then error("expected ready task array")
    elif length == 0 then "  (none)"
    else .[:10] | map("  - \(.id): \(.title)") | join("\n") end
  '); then
    READY="  (unavailable: bd ready failed; do not interpret this as no open tasks)"
    printf '%s\n' "$READY" >&2
  fi
  TASKS_NOTE="Treat the open Beads tasks below as background context only, and confirm scope with the user before starting new work."
elif [ "$SCOPE_UNRESOLVED" = 1 ]; then
  TASKS_NOTE="No open-task list is injected for this scope. Confirm scope with the user before starting new work."
elif [ "$HAS_PROMPT" = 1 ]; then
  TASKS_NOTE="No open-task list is injected for this scope. Proceed with the user's request, and confirm scope with the user only if it is unclear."
else
  TASKS_NOTE="No open-task list is injected for this scope. Before starting new work, ASK the user whether they want you to fetch open Beads items (for example the top 10 ready tasks, orphaned tasks, or other open tasks); do not fetch them automatically. Also confirm scope with the user."
fi
if [ -z "$HANDOFF_KEY" ]; then
  HANDOFF_SECTION="**Latest handoff**: (none for this scope)"
  if [ "$SCOPE_UNRESOLVED" = 1 ]; then
    # "Start fresh" is a factual claim about the store, and an indeterminate
    # scope cannot support it. Say what is actually known - that the handoff
    # could not be determined, and why - so a degraded session is never
    # mistaken for a confirmed fresh one.
    RESUME_NOTE="This session's handoff could not be determined ($SCOPE_CAUSE). That is NOT the same as there being none: do not treat this as a confirmed fresh start, and do not assume continuation of another branch's or session's work either. $TASKS_NOTE"
  else
    # "Start fresh" is a factual claim about the store too, and exclusions
    # undermine it from the other direction: the handoff for this scope may
    # be sitting among the keys that could not be classified. The RESOLVED
    # notes already carry this caveat; the absence path left the stronger
    # claim unqualified. Same invariant, same SKIPPED_NOTE mechanism.
    if [ -n "$SKIPPED_NOTE" ]; then
      RESUME_NOTE="No prior handoff was found for this session's scope among the records this read could classify$SKIPPED_NOTE. Treat that as a probable fresh start, not a confirmed one - the scope's handoff may be stored under one of the skipped keys. Do not assume continuation of another branch's or session's work either. $TASKS_NOTE"
    else
      RESUME_NOTE="No prior handoff was found for this session's scope. Start fresh - do not assume continuation of another branch's or session's work. $TASKS_NOTE"
    fi
  fi
fi
else
  # Absent, not corrupt: name the remedy instead of inventing task state.
  SYNC_NOTE="Beads is not available in this checkout, so no task or handoff state was read."
  SCOPE_NOTE="**Handoff scope**: unavailable (Beads did not resolve)"
  HANDOFF_SECTION="**Latest handoff**: (unavailable; Beads did not resolve)"
  # Not a scope decision: no scope was resolved and no list can be read. The
  # unavailable marker is kept so this state is never mistaken for "no tasks".
  SHOW_READY=1
  READY="  (unavailable: Beads did not resolve; do not interpret this as no open tasks)"
  RESUME_NOTE="Beads did not resolve, so this session has no task or handoff context. Tell the user on your first turn, and offer to run the init skill if the project has not been initialised. Check that bd and jq are installed and that .beads exists. Do not assume there is no prior work."
fi

# Header and list travel together: an omitted list leaves no dangling header.
TASKS_SECTION=""
if [ "$SHOW_READY" = 1 ]; then
  TASKS_SECTION="**Top open Beads tasks:**

$READY

"
fi

# A failed end-of-session push leaves a marker in the store (session-end.sh).
# Surface it loudly: sessionEnd output is invisible, so this is the only place
# the failure reaches a reader. Read-only; nothing is retried or repaired here.
PUSH_WARNING=""
if [ -n "${BEADS_DIR:-}" ] && [ -f "$BEADS_DIR/.push-failed" ]; then
  PUSH_MARKER=$(head -c 4000 "$BEADS_DIR/.push-failed" 2>/dev/null || true)
  PUSH_WARNING="## WARNING: Beads push failing

The previous session-end \`bd dolt push\` failed, so the Beads remote may be stale. Marker $BEADS_DIR/.push-failed:

$PUSH_MARKER

Tell the user on your first turn. Remedy: run \`bd dolt push\` and read the error. If it reports EOF or error 1105, check that \`dolt clone git+https://<remote>\` can fetch refs/dolt/data, since the remote ref may be corrupt. A successful push clears the marker. Do not delete remote refs without the user's approval.

"
fi
CONTEXT="${PUSH_WARNING}## Session Resume State

The following was auto-injected by the sessionStart hook from Beads (source of truth).
Store: ${BEADS_DIR:-(unresolved)}
$SYNC_NOTE

$SCOPE_NOTE

$HANDOFF_SECTION

${TASKS_SECTION}$RESUME_NOTE"
if [ -n "$GRAPHIFY_NOTE" ]; then
  CONTEXT="$CONTEXT

**Action needed**: $GRAPHIFY_NOTE"
fi
emit_additional_context "$CONTEXT"
