#!/usr/bin/env bash
# Shared ordering/recall for the hook and helper. Source after beads-common.sh.
# consumer_resolve sets HANDOFF_PREFIX after selecting the consumer checkout.

handoff_agent_session_id() {
  local id=${COPILOT_AGENT_SESSION_ID:-}
  [ -n "$id" ] ||
    { beads_error "COPILOT_AGENT_SESSION_ID is not set; cannot record agent_session_id"; return 1; }
  [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] ||
    { beads_error "COPILOT_AGENT_SESSION_ID must be a UUID"; return 1; }
  printf '%s\n' "$id"
}

handoff_sha256() {
  local digest
  if command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256) || return 1
    digest=${digest##* }
  elif command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256) || return 1
    digest=${digest%% *}
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum) || return 1
    digest=${digest%% *}
  else
    beads_error "cannot derive branch handoff slug: no SHA-256 tool found (openssl, shasum, sha256sum)"
    return 1
  fi
  [[ "$digest" =~ ^[a-fA-F0-9]{64}$ ]] ||
    { beads_error "SHA-256 tool returned an invalid digest"; return 1; }
  printf '%s\n' "$digest" | tr '[:upper:]' '[:lower:]'
}

# The single read-side expression of the slug bound: lowercase alphanumeric
# and hyphens, no leading/trailing/double hyphen, at most 40 characters -
# the same pair the two write-side guards in session-handoff.sh apply.
# Shared so session-start.sh can validate a captured slug without spelling
# the bound a fourth time and letting read and write drift apart.
#
# A slug whose first component is six digits ("123456-fix") is deliberately
# ALLOWED. Ticket-number branches are ordinary, and the classifier already
# distinguishes them: a minted key carries its own six-digit sequence first,
# so "...-000001-123456-fix-deadbeef" matches the sequence+slug arm and
# classifies as sequence 1 with slug "123456-fix-deadbeef" - a branch record
# that can never claim trunk. Banning the shape bought no disjointness and
# made every such branch permanently unreadable AND unwritable, because
# handoff_branch_slug aborts on an invalid derived slug.
#
# The residual ambiguity the ban did not fix, and could not: a sequence-less
# LEGACY key "...-<stamp>-000001-foo" is textually identical to a
# sequence-qualified "...-<stamp>-000001-foo", so the sequence+slug arm wins
# and it reads as sequence 1 with slug "foo" rather than sequence 0 with slug
# "000001-foo". That is a known limitation of sharing "-" as both the
# sequence and slug delimiter; it is tracked for a v2 prefix-free key format,
# not something a slug-character ban can correctly resolve. Both readings are
# branch readings, so neither leaks into the trunk scope.
handoff_slug_valid() {
  local slug=${1-}
  [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] && [ "${#slug}" -le 40 ]
}

# Emits the raw three-line payload:
#   line 1: count of own-prefix keys EXCLUDED as unclassifiable;
#   line 2: count of own-prefix keys dropped as AMBIGUOUS by the namespace
#           pre-filter - they start with this project's prefix but also parse
#           as a longer project's dated key, so the namespace alone cannot say
#           whether they are foreign records or malformed own records;
#   line 3: the compact JSON record array.
# Both counts travel on stdout rather than through jq's `stderr` builtin so a
# caller can surface them to its own audience - session-start.sh has to put
# them in front of the agent, which never sees hook stderr - and so the
# wording is not at the mercy of jq's version-dependent `stderr` quoting (1.6
# emits the JSON-quoted form, 1.7 the raw string) or its missing terminator.
handoff_records_payload() {
  [ -n "${HANDOFF_PREFIX:-}" ] || { beads_error "consumer identity is unresolved"; return 1; }
  # Legacy date-only and tHHMM keys remain readable. Normalize T/t, optional
  # colons/seconds/Z, then order by timestamp, sequence and original key.
  #
  # Slurp and require exactly one top-level document. Without -s, jq applies
  # the program to *each* document independently and still exits 0, so a
  # wrapper that duplicated or corrupted its output would yield one record
  # array per document; the lookups below would then emit one default object
  # each, the key would collapse to empty with status 0, and session-start
  # would report a *confirmed* fresh trunk scope. An unparseable store state
  # must fail, never resolve to positive membership in a scope. (Empty input
  # slurps to [] and fails here too, where unslurped jq -e already exited 4.)
  #
  # Store-level faults (bd unavailable, unparseable JSON, not exactly one
  # document, a non-object top level) still abort: they make the whole
  # snapshot untrustworthy, and a caller must degrade rather than act on a
  # partial view. Per-key unclassifiability is different in kind - it is one
  # stray key, not a broken store - and is handled by EXCLUSION below.
  #
  # A non-string VALUE used to abort here too, which was a misclassification:
  # the value type is a property of one key, not of the store. The Beads
  # memory namespace is SHARED, and the real store already carries non-string
  # values (`schema_version` is a number); they survive only because the
  # namespace pre-filter runs first. One such key landing under this prefix
  # discarded every valid handoff in the store, so the fix below excludes and
  # counts it like any other key this reader cannot turn into a record.
  bd memories session-handoff --json | jq -sce --arg p "$HANDOFF_PREFIX" '
    # Gregorian validation. The character-class date pattern below range-
    # checks month and day independently, so it accepts 2026-02-31 and
    # 2026-04-31; such a key used to capture cleanly and - having no suffix
    # after the date - classify as a *trunk* record, i.e. positive membership
    # in the main chain for a day that never existed. Validate the real
    # calendar instead, in jq, so no subprocess or locale can influence a
    # scope decision.
    def leap_year($y): ($y % 4) == 0 and (($y % 100) != 0 or ($y % 400) == 0);
    def real_date($day):
      ($day[0:4] | tonumber) as $y | ($day[5:7] | tonumber) as $m |
      ($day[8:10] | tonumber) as $d |
      $y > 0 and $d >= 1 and $d <= (
        if $m == 2 then (if leap_year($y) then 29 else 28 end)
        elif $m == 4 or $m == 6 or $m == 9 or $m == 11 then 30
        else 31 end);
    # Decide whether a key'"'"'s post-prefix remainder belongs to THIS project'"'"'s
    # namespace. A remainder starting with a date is ours; one that parses as
    # "<longer-project>-<date>..." probably is not.
    def own_namespace:
      if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[tT].*|-.*)?$") then true
      else (test("^[a-z0-9]+(?:-[a-z0-9]+)*-[0-9]{4}-[0-9]{2}-[0-9]{2}(?:[tT].*|-.*)?$") | not)
      end;
    # Classify one own-namespace key, or report it unclassifiable. Every    # anchor here is \z, never $: Oniguruma'"'"'s $ also matches immediately
    # before a single trailing newline, so "...-000001\n" tested as a pure
    # six-digit sequence (trunk!) and "...-otel\n" captured a slug carrying a
    # newline that the bash-side handoff_slug_valid would reject. A key that
    # is not the key it appears to be must not claim scope membership.
    def classify($key; $value):
      ($key | ltrimstr($p)) as $rest |
      ([$rest | capture("^(?<day>[0-9]{4}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12][0-9]|3[01]))(?:[tT](?<hh>[01][0-9]|2[0-3]):?(?<mm>[0-5][0-9])(?::?(?<ss>[0-5][0-9]))?[zZ]?)?(?:-(?<suffix>.+))?\\z")] | .[0]) as $parts |
      # The suffix group is `.+`, never `.*`. With `.*` a key ending in a
      # bare separator ("...-2026-10-03t1200-") captured an EMPTY suffix,
      # which is indistinguishable from an absent one, so the first arm below
      # classified it as a trunk record - and being later-stamped it then
      # displaced the real trunk handoff in main'"'"'s selection. With `.+` the
      # optional group cannot match, the trailing "-" is left unconsumed,
      # \z fails, $parts is null, and the key is excluded and counted: the
      # correct outcome for a key this reader cannot classify. A genuinely
      # suffix-less key ("...-2026-01-01t0900") never enters the group at all
      # and still classifies as trunk.
      # Validate the COMPLETE suffix grammar. The suffix was once captured as
      # (?<suffix>.*) and anything that did not start with six digits and a
      # hyphen fell through to slug "" - i.e. was classified as a *trunk*
      # record. bd remember is user-callable, so a hand-written or corrupted
      # key ("...-foreign", a trailing "...-000001-") was selected as the
      # predecessor for main and injected into a main session.
      #
      # The fourth shape - a bare slug with no six-digit sequence - is the
      # pre-sequence legacy key ("...-otel", "...-graphify"). The real store
      # is full of them. They are classified as sequence 0 under their own
      # named chain rather than as trunk: a hand-written or corrupted
      # "...-foreign" is structurally indistinguishable from "...-otel", and
      # the governing invariant is that an unclassifiable or foreign record
      # must never claim positive membership in the trunk scope. Order
      # matters: the two sequence arms are tried first so a pure six-digit
      # sequence is never misread as a slug. The slug bound is the same pair
      # the read-side and write-side guards apply: lowercase
      # alphanumeric/hyphen, no leading/trailing/double hyphen, at most 40.
      ("[a-z0-9]+(-[a-z0-9]+)*") as $slug |
      (if $parts == null or (real_date($parts.day) | not) then null
       else ($parts.suffix // "") as $suffix |
         if $suffix == "" then {sequence:0, slug:""}
         elif ($suffix | test("^[0-9]{6}\\z")) then {sequence:($suffix | tonumber), slug:""}
         elif ($suffix | test("^[0-9]{6}-" + $slug + "\\z"))
              and (($suffix[7:] | length) <= 40)
           then {sequence:($suffix[0:6] | tonumber), slug:$suffix[7:]}
         elif ($suffix | test("^" + $slug + "\\z")) and (($suffix | length) <= 40)
           then {sequence:0, slug:$suffix}
         else null end
       end) as $tail |
      if $tail == null then {unclassifiable:$key}
      else
        # Carry the body with the record. session-start.sh used to re-read
        # the selected key through handoff_recall, so a writer could replace
        # that key'"'"'s value between the snapshot and the recall and have the
        # hook inject a body that was never the one validated and selected.
        # One snapshot, one body - and one fewer store round-trip.
        {key:$key, value:$value,
         stamp:($parts.day + "t" + ($parts.hh // "00") + ($parts.mm // "00") + ($parts.ss // "00")),
         sequence:$tail.sequence, slug:$tail.slug}
      end;
    if length != 1 then error("expected exactly one memory document") else .[0] end |
    if type != "object" then error("expected memory object") else . end |
    [to_entries[] | select(.key | startswith($p))] as $under |
    # Inspect only the suffix after the resolved namespace; project names
    # may themselves contain dates. Drop dated keys of longer projects -
    # they are probably not this project'"'"'s keys at all, so they are not
    # classified - but retain malformed own suffixes.
    #
    # "Probably" is the whole problem, and why these are COUNTED rather than
    # silently discarded. Under prefix "session-handoff-widget-app-", the key
    # "session-handoff-widget-app-foo-2026-01-01" may be project
    # "widget-app-foo"'"'"'s trunk record or a malformed "widget-app" record;
    # the namespace cannot tell. Reporting zero skips here let a scope claim
    # a confident "fresh" while an own-prefix-matching key had been dropped.
    ([$under[] | select(.key | ltrimstr($p) | own_namespace | not)] | length) as $ambiguous |
    ([$under[] | select(.key | ltrimstr($p) | own_namespace) |
      # A non-string value is a per-key fault, not a store-level one: this
      # namespace is shared with non-handoff memories, and jq'"'"'s error() would
      # abort the whole program and discard every valid sibling record. The
      # governing invariant is satisfied either way - an unclassifiable
      # record must never claim positive membership in any scope - and
      # exclusion additionally keeps it from being reported as a confirmed
      # absence, because the count below caveats the note.
      if (.value | type) != "string" then {unclassifiable:.key}
      else classify(.key; .value) end
    ]) as $classified |
    # An unclassifiable key is EXCLUDED, not fatal. Aborting the whole read
    # on one stray key - and `bd remember` is user- and agent-callable with a
    # free-form key - bricked the store for reading: session-start degraded
    # permanently to indeterminate and write/show/list all exited nonzero, so
    # handoffs became unwritable until a human ran `bd forget`. Exclusion
    # still satisfies the invariant: a key that is not in the record set can
    # never claim the trunk scope (or any other), be selected as a
    # predecessor, or be injected. Report both counts ahead of the records so
    # no caller can mistake a partial read for a confirmed empty scope.
    ([$classified[] | select(has("unclassifiable"))] | length),
    $ambiguous,
    ([$classified[] | select(has("unclassifiable") | not)] | sort_by(.stamp, .sequence, .key))
  '
}

# Split a handoff_records_payload() result into HANDOFF_SKIPPED (excluded key
# count), HANDOFF_AMBIGUOUS (namespace-dropped key count) and HANDOFF_RECORDS
# (the record array). A payload that does not carry all three parts is not
# one this reader understands, so it fails rather than guessing: an
# unreadable snapshot must never collapse into an empty one. Sets globals
# instead of printing because a caller that needs the counts cannot read them
# back out of a command substitution.
handoff_payload_split() {
  local payload=${1-} count ambiguous rest
  case $payload in
    *$'\n'*) ;;
    *) beads_error "handoff snapshot is malformed: no record array"; return 1 ;;
  esac
  count=${payload%%$'\n'*}
  case $count in
    ''|*[!0-9]*) beads_error "handoff snapshot is malformed: no excluded-key count"; return 1 ;;
  esac
  rest=${payload#*$'\n'}
  case $rest in
    *$'\n'*) ;;
    *) beads_error "handoff snapshot is malformed: no record array"; return 1 ;;
  esac
  ambiguous=${rest%%$'\n'*}
  case $ambiguous in
    ''|*[!0-9]*) beads_error "handoff snapshot is malformed: no ambiguous-key count"; return 1 ;;
  esac
  HANDOFF_SKIPPED=$count
  HANDOFF_AMBIGUOUS=$ambiguous
  HANDOFF_RECORDS=${rest#*$'\n'}
}

# One wording for the excluded-key diagnostic, newline-terminated so it does
# not run into whatever writes to stderr next.
handoff_warn_skipped() {
  [ "${1:-0}" != 0 ] || return 0
  printf 'handoff: skipped %s unclassifiable key(s) under %s\n' "$1" "${HANDOFF_PREFIX:-}" >&2
}

# Same, for keys this project'"'"'s prefix matched but whose namespace could not
# be resolved to this project.
handoff_warn_ambiguous() {
  [ "${1:-0}" != 0 ] || return 0
  printf 'handoff: skipped %s key(s) under %s whose project namespace is ambiguous\n' "$1" "${HANDOFF_PREFIX:-}" >&2
}

# The record array alone, for callers whose audience is a terminal and so can
# see the stderr warnings. session-start.sh uses the payload form directly.
handoff_records() {
  local payload
  payload=$(handoff_records_payload) || return 1
  handoff_payload_split "$payload" || return 1
  handoff_warn_skipped "$HANDOFF_SKIPPED"
  handoff_warn_ambiguous "$HANDOFF_AMBIGUOUS"
  printf '%s\n' "$HANDOFF_RECORDS"
}

# Every lookup below operates on an already-fetched handoff_records() result
# so a caller that needs more than one view (session-start.sh, cmd_write)
# derives them all from a single consistent snapshot instead of independent
# bd memories reads that could race against a concurrent write.
#
# Unscoped lookup: the most recent record anywhere, regardless of slug. Used
# for key sequencing (handoff_next_key, which must stay global so two scopes
# cannot mint the same stamp/sequence) and for naming - never injecting - a
# cross-scope record so a user can opt into it deliberately.
handoff_latest_from() {
  printf '%s\n' "$1" | jq -c 'last // {key:"",stamp:"",sequence:0}'
}

# Branch-scoped lookup: the last record (by the same stamp/sequence/key
# order as handoff_records) whose key's slug component equals $2. Legacy
# date-only and sequence-only keys expose slug:"" from handoff_records and
# can never match a nonempty $2, so they surface only via the unslugged
# lookup below or the unscoped handoff_latest_from above. Legacy keys whose
# suffix is a bare word carry that word as their slug, so they form their own
# named chain and are invisible to both the unslugged lookup and any other
# branch's slug.
handoff_latest_for_slug_from() {
  local records=$1 slug=$2
  [ -n "$slug" ] || { printf '%s\n' '{"key":"","stamp":"","sequence":0}'; return 0; }
  printf '%s\n' "$records" | jq -c --arg slug "$slug" '
    [.[] | select(.slug == $slug)] | last // {key:"",stamp:"",sequence:0}
  '
}

# Legacy slug-free lookup: the last record whose key carries no slug component
# at all. Healthy automatic scopes always have a derived slug, so these are
# legacy or manually created records only. They remain readable for list,
# recall, and cross-scope discovery, but no automatic scope inherits them.
handoff_latest_unslugged_from() {
  printf '%s\n' "$1" | jq -c '
    [.[] | select(.slug == "")] | last // {key:"",stamp:"",sequence:0}
  '
}

# Derive a slug from the current session's own branch or detached commit (not
# the shared BEADS_ROOT, which always points at the common/main checkout and
# would collapse every worktree's slug to the same value).
# Neither a failed branch query nor a hash failure may silently return an
# empty slug. Slug-free records are legacy/manual data, not an automatic
# scope, so every healthy derivation must produce a nonempty slug.
#
# Lowercasing and collapsing every non-[a-z0-9] run to a single hyphen is
# lossy and not injective: "feature/a" and "feature-a" both normalize to
# "feature-a", and two branch names sharing the same first ~40 normalized
# characters collide under the slug's length limit. Either collision would
# make a handoff written on one branch appear branch-scoped (confidently
# belonging to the current branch) on a different, unrelated branch -- worse
# than the honest global fallback. To stay collision-resistant while
# remaining human-readable and within the existing 40-char
# ^[a-z0-9]+(-[a-z0-9]+)*$ slug constraint, keep a truncated normalized
# prefix of the branch name and append a short hex hash of the *original*
# (pre-normalization) branch name; the hash absorbs both punctuation
# differences and truncation collisions that the prefix alone cannot.
handoff_branch_slug() {
  local root branch status head_type head_desc head_oid hash prefix max_prefix slug
  # Only the resolved consumer checkout may answer the scope question. A `.`
  # fallback would satisfy the letter of "git must actually answer" while
  # letting git answer about an unrelated repository that happens to be the
  # invocation CWD - and if that repository were on main, it would hand back
  # a confident but unrelated slug for a session whose real
  # branch was never consulted. consumer_resolve always sets this, so this is
  # a contract assertion; keep it failing closed anyway.
  root=${WORKSPACE_ROOT:-}
  [ -n "$root" ] ||
    { beads_error "WORKSPACE_ROOT is unset; refusing to resolve the handoff scope against an unverified working directory"; return 1; }
  # symbolic-ref is the primitive that distinguishes the three cases a scope
  # decision depends on. It succeeds on an *unborn* branch - a `git init`
  # checkout with no commit yet, which bootstrap-project.sh routinely creates
  # - so a brand-new repository still resolves to its real branch name, and
  # an unborn `feature/x` gets that branch's slug rather than silently
  # joining a legacy slug-free chain. It reports not-a-symbolic-ref on a detached HEAD, which
  # cat-file -t then separates from genuine breakage. (`rev-parse
  # --abbrev-ref HEAD` cannot do this: it errors on an unborn HEAD,
  # indistinguishable from a broken repository.)
  #
  # Read the *full* ref, never `--short`. `--short` abbreviates to the
  # shortest unambiguous name, so an unrelated tag sharing the branch's name
  # turns `main` into `heads/main` and changes its derived scope; and by
  # discarding the namespace it reports a HEAD pointing at `refs/tags/x` as
  # the plain branch `x`. Requiring an explicit refs/heads/ prefix is both
  # ambiguity-proof and namespace-aware.
  branch=$(git -C "$root" symbolic-ref --quiet HEAD) && status=0 || status=$?
  if [ "$status" -ne 0 ]; then
    # Only git's specific not-a-symbolic-ref signal - status 1, the
    # non-zero-and-silent exit git is observed to use under --quiet - may
    # be read as a detached HEAD. Every other status is genuine breakage (a
    # missing repository, an unreadable HEAD), and treating it as detached
    # would invent a commit scope for a session that is really on a named
    # branch: the exact fail-open this lookup exists to prevent.
    if [ "$status" -eq 1 ]; then
      # HEAD must name a commit *directly* to be an ordinary detached HEAD.
      # Routine, so stay silent - --quiet has already suppressed git's
      # not-a-symbolic-ref message.
      #
      # Ask for HEAD's own object type rather than resolving it: `rev-parse
      # --verify HEAD` succeeds for *any* object HEAD names, so a .git/HEAD
      # holding a blob or tree id passed and was handed a detached scope; and
      # `rev-parse --verify HEAD^{commit}` still *peels*, so a
      # .git/HEAD holding an annotated-tag id passed it too. Either way a
      # corrupt checkout silently read and superseded detached memory.
      # Only a HEAD whose own type is `commit` is a detached HEAD git itself
      # would write: `git checkout <annotated-tag-oid>` stores the peeled
      # commit id, never the tag id. Anything else is corrupt-only state and
      # fails closed below. (An *unborn* HEAD never reaches here:
      # symbolic-ref succeeds on it, status 0.)
      head_type=$(git -C "$root" cat-file -t HEAD 2>/dev/null) || head_type=""
      if [ "$head_type" = commit ]; then
        head_oid=$(git -C "$root" rev-parse --verify --quiet HEAD) || return 1
        head_oid=$(printf '%s' "$head_oid" | tr '[:upper:]' '[:lower:]')
        slug="detached-${head_oid:0:31}"
        handoff_slug_valid "$slug" ||
          { beads_error "derived an invalid detached handoff slug \"$slug\"; refusing to use an empty handoff scope"; return 1; }
        printf '%s\n' "$slug"
        return 0
      fi
      # Do not re-run symbolic-ref to "surface" git's text here: without
      # --quiet it prints `fatal: ref HEAD is not a symbolic ref`, which
      # describes a perfectly healthy detached HEAD and says nothing about
      # the actual fault. Report the observed cause instead.
      head_desc="${head_type:+a $head_type object}"
      beads_error "cannot read the current branch in $root: HEAD is not a symbolic ref and names ${head_desc:-no readable object}, not a commit; refusing to invent a detached handoff scope"
      return 1
    fi
    # For any other status git has already printed its `fatal:` exactly
    # once - --quiet silences the not-a-symbolic-ref message alone, not
    # real errors - so do not re-run and print it again.
    beads_error "cannot read the current branch in $root; refusing to invent a handoff scope"
    return 1
  fi
  # A symbolic HEAD resolving outside refs/heads/ is not a branch at all, so
  # it has no branch scope to select. Fail closed rather than inventing one.
  case $branch in
    refs/heads/?*) branch=${branch#refs/heads/} ;;
    *)
      beads_error "HEAD in $root resolves to $branch, which is not a branch; refusing to invent a handoff scope"
      return 1
      ;;
  esac
  hash=$(printf '%s' "$branch" | handoff_sha256) ||
    { beads_error "cannot derive handoff slug for branch $branch"; return 1; }
  hash=${hash:0:8}
  prefix=$(printf '%s' "$branch" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g') || prefix=""
  prefix=${prefix#-}
  prefix=${prefix%-}
  # Reserve room for the "-<hash>" suffix within the 40-char slug budget.
  max_prefix=$((40 - 1 - ${#hash}))
  prefix=${prefix:0:$max_prefix}
  prefix=${prefix%-}
  if [ -n "$prefix" ]; then slug="$prefix-$hash"; else slug="$hash"; fi
  # The derivation above is total for every branch name git can report, so
  # this is a contract assertion rather than a reachable input case. Keep it
  # failing closed anyway: blanking the slug here would return no usable
  # scope with status 0 - the silent scope downgrade this whole lookup
  # exists to prevent - and this guard is exactly where a future change to
  # the hash or prefix rules would reintroduce it. Assert the *same* pair of
  # conditions the two write-side guards in session-handoff.sh apply - the
  # character class and the 40-character budget - so a future change that
  # overruns the budget fails closed on both sides instead of leaving read
  # and write disagreeing about which scope a branch belongs to.
  handoff_slug_valid "$slug" ||
    { beads_error "derived an invalid handoff slug \"$slug\" for branch $branch; refusing to use an empty handoff scope"; return 1; }
  printf '%s\n' "$slug"
}

handoff_recall() {
  bd recall "$1" --json | jq -er --arg key "$1" '
    select(.found == true and .key == $key) | .value |
    select(type == "string" and length > 0)
  ' || beads_error "could not recall a nonempty handoff at $1"
}

handoff_validate_body() {
  local next id
  next=$(jq -ner --arg body "$1" '
    ($body | split("\n")) as $lines |
    if ([$lines[] | select(test("\\S"))][0] // "" | test("^Session handoff: .*\\S") | not)
    then error("first nonblank line must be Session handoff: <nonempty summary>")
    else . end |
    def fields($name):
      [$lines[] | select(test("^(?:- )?" + $name + ":")) |
       sub("^(?:- )?" + $name + ":\\s*"; "") | gsub("\\s+$"; "")];
    if (fields("Supersedes") | length) != 0 then error("Supersedes is generated by the helper")
    elif (fields("Session IDs")[0]? // "" | test("agent_session_id=")) then
      error("agent_session_id is generated by the helper from COPILOT_AGENT_SESSION_ID; Session IDs must contain only project_session_id=<uuid>")
    elif all(["Session IDs","Completed","Active branch","Open PRs","Worktrees","Next work","Review state","Blocked","Decisions"][];
      fields(.) | length == 1 and .[0] != "") then
      (if (fields("Session IDs")[0] | test("^project_session_id=[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$") | not)
       then error("Session IDs must be exactly: project_session_id=<uuid> (agent_session_id is appended by the helper)")
       else fields("Next work")[0] end)
    else error("each required handoff field must appear once and be nonempty") end
  ') || return 1
  [ "$next" != "(none)" ] || return 0
  # Keep references mechanical; explanations belong on the actual task.
  [[ "$next" =~ ^[a-zA-Z0-9][a-zA-Z0-9.,\ -]*$ ]] ||
    { beads_error "Next work must be issue IDs separated by spaces/commas, or (none)"; return 1; }
  next=${next//,/ }
  for id in $next; do
    [[ "$id" =~ ^[a-zA-Z0-9]+(-[a-zA-Z0-9]+)+(\.[a-zA-Z0-9]+)*$ ]] ||
      { beads_error "invalid next-work issue ID: $id"; return 1; }
    bd show "$id" --json | jq -e --arg id "$id" '
      type == "array" and any(.[];
        type == "object" and .id == $id and
        (.status | type == "string" and length > 0) and .status != "closed")
    ' >/dev/null ||
      { beads_error "next-work issue is missing, closed, or unreadable: $id"; return 1; }
  done
}

handoff_next_key() {
  local latest=$1 now stamp sequence
  now=$(date -u +%Y-%m-%dt%H%M%S) || return 1
  [[ "$now" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}t[0-9]{6}$ ]] ||
    { beads_error "invalid UTC timestamp from date"; return 1; }
  stamp=$(printf '%s\n' "$latest" | jq -r .stamp) || return 1
  sequence=$(printf '%s\n' "$latest" | jq -r .sequence) || return 1
  # A clock rollback must not hide the new handoff behind its predecessor.
  if [[ "$now" > "$stamp" ]]; then stamp=$now; sequence=0; fi
  [ "$sequence" -lt 999999 ] ||
    { beads_error "handoff sequence exhausted for $stamp"; return 1; }
  printf '%s%s-%06d\n' "$HANDOFF_PREFIX" "$stamp" "$((sequence + 1))"
}

# A stable token for "what is this worktree's HEAD", used to build the scope
# identity below, which in turn detects a scope change between the moment the
# scope was resolved and the moment a handoff body is injected. The scope was
# previously read once and trusted for the rest of the run, so a checkout
# that switched branches in between had branch A's handoff injected into a
# branch B session: exactly the cross-scope leak this reader exists to
# prevent.
#
# Both halves are reported. The full symbolic ref names the scope; the
# resolved object id says where it currently points, which is the scope's
# own identity only on a detached HEAD. Callers comparing two reads across a
# window want handoff_scope_identity(), not this - see its comment. Prints
# nothing and fails when the repository, the symbolic ref, or the object id
# cannot be read - with one deliberate exception: a symbolic HEAD whose
# target ref is genuinely ABSENT is an unborn branch, a real and routine
# state (git init, bootstrap-project.sh), and gets the "(unborn)"
# placeholder.
#
# That exception used to swallow every HEAD resolution failure, so a corrupt
# or unreadable branch ref produced a token identical to a genuinely-unborn
# branch of the same name - an unreadable state reported as an unchanged one,
# which is exactly the positive membership claim the governing invariant
# forbids: an unclassifiable state must never read as either a confirmed
# scope or a confirmed absence.
handoff_scope_token() {
  local root ref oid status ref_file packed
  root=${WORKSPACE_ROOT:-}
  [ -n "$root" ] || return 1
  # Probe the repository itself first. Without this, a vanished or broken
  # checkout would make both reads below fall back to their placeholders and
  # produce a perfectly stable token: an unreadable state reported as an
  # unchanged one.
  git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || return 1
  ref=$(git -C "$root" symbolic-ref --quiet HEAD) && status=0 || status=$?
  if [ "$status" -ne 0 ]; then
    [ "$status" -eq 1 ] || return 1
    # Detached HEAD names an object directly; it has no target ref to be
    # unborn, so an unresolvable one is simply unreadable.
    ref="(detached)"
    oid=$(git -C "$root" rev-parse --verify --quiet HEAD) || return 1
    printf '%s %s\n' "$ref" "$oid"
    return 0
  fi
  if oid=$(git -C "$root" rev-parse --verify --quiet HEAD); then
    printf '%s %s\n' "$ref" "$oid"
    return 0
  fi
  # HEAD did not resolve through its target ref. Unborn only if that ref does
  # not exist; if it exists and still would not resolve, it is invalid or
  # unreadable and this function must fail closed. `show-ref --verify` cannot
  # make the distinction - absent, empty and garbage refs all report the same
  # status - so test existence directly, loose first and then packed.
  ref_file=$(git -C "$root" rev-parse --git-path "$ref" 2>/dev/null) || return 1
  # `--git-path` answers relative to the GIT process's CWD - i.e. to $root -
  # for a plain checkout, while the tests below run in the SHELL's CWD. The
  # hook never cd's and derives WORKSPACE_ROOT from `--show-toplevel`
  # precisely so it works from a subdirectory, so those two routinely differ
  # and the guard would stat a path that cannot exist, fall through, and call
  # a BROKEN ref absent. Anchor the relative answer to $root, the same idiom
  # install-git-hooks.sh and consumer-common.sh use. A linked worktree
  # already answers absolutely and is left untouched.
  case "$ref_file" in /*) ;; *) ref_file="$root/$ref_file" ;; esac
  # Only an exact loose ref FILE - or a symlink to one - is this ref
  # existing. A DIRECTORY at that path is the ref *namespace*, holding
  # descendant refs: a repository whose only branch is `main/topic` has a
  # `refs/heads/main/` directory while `refs/heads/main` itself is unborn.
  # `-e` is true for that directory, so a routine unborn trunk was reported
  # as an unreadable scope and suppressed the session's handoff. `-d` is
  # tested first so it also settles a symlink pointing at such a directory;
  # a dangling symlink is still a broken ref, not an absent one, and fails
  # closed below.
  if [ ! -d "$ref_file" ] && { [ -f "$ref_file" ] || [ -L "$ref_file" ]; }; then return 1; fi
  # for-each-ref matches by PREFIX, so asking about `refs/heads/main` also
  # returns `refs/heads/main/topic`: a nonempty result proves nothing about
  # the ref actually asked for. Require a line equal to the COMPLETE ref
  # name instead.
  #
  # This is deliberately NOT `printf ... | grep -qxF`. `grep -q` exits at the
  # first match, and for-each-ref sorts the exact ref FIRST, so on a listing
  # larger than the pipe buffer `printf` would die of SIGPIPE and `pipefail`
  # (inherited from session-start.sh) would make the pipeline fail - sending
  # a ref just PROVEN to exist down the "(unborn)" branch, a positive claim
  # in the direction the governing invariant forbids. A `case` has no exit
  # status to invert. Wrapping both the list and the ref in newlines keeps
  # the match whole-line exact (`refs/heads/main` cannot match inside
  # `refs/heads/main/topic`), and quoting "$ref" inside the pattern keeps it
  # a literal, so ref-legal glob characters such as `. + ( ) { } |` and even
  # `*` or `?` cannot widen it.
  packed=$(git -C "$root" for-each-ref --format='%(refname)' -- "$ref" 2>/dev/null) || return 1
  case $'\n'"$packed"$'\n' in *$'\n'"$ref"$'\n'*) return 1 ;; esac
  printf '%s %s\n' "$ref" "(unborn)"
}

# The scope IDENTITY: "which scope is this worktree in", with no claim about
# where that scope currently points. Derived from the token above, so it
# costs no extra Git read and cannot disagree with it.
#
# The token embeds the resolved object id, which makes it the right answer to
# "has anything about HEAD changed" and the WRONG answer to "is this still
# the same scope". An ordinary commit landing on the checked-out branch
# changes the object id while the scope is plainly unchanged, so callers
# comparing tokens across a window declared a perfectly legitimate branch
# session indeterminate and suppressed its handoff.
#
# The object id is dropped for a named ref only. On a DETACHED HEAD the
# object id genuinely IS the scope identity - there is no ref name to carry
# it - so it stays. The attached placeholder is a distinct literal from
# "(unborn)" so that a branch becoming unborn (or an unborn branch receiving
# its first commit) still reads as a changed scope, as does any move between
# the attached, unborn and detached classes.
handoff_scope_identity() {
  local token ref rest
  token=$(handoff_scope_token) || return 1
  # Git forbids whitespace in ref names and "(detached)" has none, so the
  # first space is unambiguously the separator this function printed.
  ref=${token%% *}
  rest=${token#* }
  case $ref in
    '(detached)') ;;
    *) [ "$rest" = "(unborn)" ] || rest="(attached)" ;;
  esac
  printf '%s %s\n' "$ref" "$rest"
}
