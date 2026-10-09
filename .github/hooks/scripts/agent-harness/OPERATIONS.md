# Hook bundle operations

This bundle requires Bash 3.2+, Git, jq, `/usr/bin/perl` with
`Time::HiRes::CLOCK_MONOTONIC`, and a SHA-256 provider on `PATH`:
`openssl`, then `shasum`, then `sha256sum` in availability order. A broken
provider or missing/invalid digest fails branch handoff routing explicitly,
never silently falling back to the global chain. The separately pinned macOS
server route still requires `/usr/bin/openssl` for native binary attestation.
Embedded routing accepts only Beads (`bd`) **1.2.2,
1.3.0-rc.1, or 1.3.0**. The selected store must already contain embedded
Dolt metadata and `embeddeddolt/<database>/.dolt`. No automatic store
initialization or fallback runs in hooks or wrappers.

## Installation and invocation

APM reads the root `hooks.json` descriptor. Its commands are
`bash "./session-start.sh"` and `bash "./session-end.sh"`. APM resolves
these `./` paths relative to the source descriptor and rewrites them
relative to the deployed bundle root. Do not use
`${PLUGIN_ROOT}/.apm/hooks/...` here: APM 0.31.0 retains that package-relative
nesting in the deployed command rather than flattening it.
The runtime scripts are a bundle: APM copies subdirectories beneath
`.github/hooks/scripts/<package>/`, excluding root descriptors. No nested
JSON descriptors are needed. Helpers always resolve relative to their
script directory, not `.github/scripts` or the current directory.

Run commands **from the consumer checkout or one of its linked worktrees**:

```sh
<bundle>/scripts/bd.sh context --json
<bundle>/scripts/session-handoff.sh show
<bundle>/scripts/session-handoff.sh write < handoff.txt
```

Both `session-handoff.sh --help` and `session-handoff.sh write --help`
print usage and exit successfully without resolving a store or running Beads.

Here `<bundle>` is the installed bundle directory, or `.apm/hooks` when
developing this package. There is no `.apm/scripts` primitive.

Git's common checkout owns the default `.beads` store. A linked worktree
can explicitly select its own existing store with `BEADS_DIR`, or carry a
single-hop `.beads/redirect`. Non-Git, bare, separate-git-dir, nonexistent,
ambiguous, chained, or cross-repository routes fail with diagnostics.
The package's checkout is never a fallback. Moving the package into
`apm_modules` does not change consumer identity or routing.

Project identity comes from the **common checkout's origin repository
basename**, normalized to lowercase alphanumerics/hyphens (trailing `.git`
removed). Without origin, the common checkout basename is used. Identity
therefore stays consistent across linked worktrees. Changing the remote
basename changes the namespace; set a stable slug if renaming a repository.
Repositories sharing a store and the same basename should use distinct
explicit slugs.

## Configuration

| Variable | Meaning |
| --- | --- |
| `AGENT_HARNESS_PROJECT_SLUG` | Explicit stable project identity; 1–80 lowercase alphanumeric/hyphen characters, no leading/trailing/repeated hyphens. An empty explicit value is rejected. |
| `BEADS_DIR` | Existing store, relative to invocation CWD or absolute. Symlinks are canonicalized; redirects must resolve to one existing store. Empty explicit values are rejected. |
| `AGENT_HARNESS_BEADS_ALLOW_EXTERNAL` | `0` (default) or explicit `1` to use a store outside the consumer's Git common directory. The consumer still determines actor/handoff identity. |
| `BEADS_ACTOR` | Explicit actor, preserved. Otherwise `<project-slug>[:<COPILOT_AGENT_SESSION_ID>]`. |
| `COPILOT_AGENT_SESSION_ID` | UUID-shaped agent provenance, automatically appended to handoffs and commit trailers. Required and validated before store access for handoff writes. A nonempty malformed value rejects commit provenance without changing the message. |
| `DASHBOARD_REPO` | Optional `[host/]owner/repo`; otherwise use the consumer common checkout's origin, never ambient `GH_REPO`. |
| `DASHBOARD_ISSUE` | Required positive issue number to opt into dashboard operations. There is no dashboard search or creation. |

`BEADS_DB`, `BD_DB`, and ambient `BEADS_DOLT_*` routing overrides are
rejected, as are wrapper flags that select another database/directory/server.
Server routing also rejects other ambient `BEADS_*` and `BD_*` variables,
except the selected route/actor and metrics/event-flush disables. Internal
`BEADS_ROUTE`, `BEADS_SERVER_HELPER`, and deadline variables are implementation
details, not configuration. No hook exports survive into subsequent tools.

## Handoffs and failures

Keys are `session-handoff-<project>-YYYY-MM-DDtHHMMSS-NNNNNN[-branch-slug]`.
A branch slug is lowercase alphanumeric and hyphens, at most 40 characters.
A slug may begin with a six-digit component (`123456-fix`): the minted key
carries its own sequence before the slug, so such a key still classifies as a
branch record. One ambiguity remains and is tracked for a v2 prefix-free key
format: a sequence-less legacy key `...-<stamp>-000001-foo` is textually
identical to a sequence-qualified one, so it reads as sequence 1 with slug
`foo`. Both readings are branch readings; neither reaches the trunk scope.
The local store lock covers predecessor selection, writing, and exact
readback. Timestamp rollback advances the latest sequence; exhausted
sequences fail. Never steal a live or stale lock automatically.
Reads match the complete project namespace at the timestamp boundary, so
`foo` does not consume `foo-bar` handoffs.

Read faults split in two. PER-KEY faults exclude that one key, warn with a
count on stderr, and let the read continue: no date in the suffix, a
malformed date, an impossible calendar date (`2026-02-30`), a suffix matching
no recognized arm, and a value that is not a string. The value type is a
property of one key, not of the store: the Beads memory namespace is shared
and legitimately carries non-handoff keys with non-string values
(`schema_version` is a number), so treating one as fatal discarded every
valid record. An excluded key is absent from the record set, so it can never
claim a scope, be selected as a predecessor, or be injected, and it
disappears from `show`/`list` while every other record stays readable. If a
record vanished from `show`, check the skip count on stderr and in
session-start's scope note, then inspect the key with `bd memories`.
STORE-LEVEL faults remain fatal because they make the whole snapshot
untrustworthy: `bd` being unavailable, unparseable JSON, `bd memories` not
returning exactly one top-level document, and a document that is not an
object. These abort the read so a caller degrades instead of acting on a
partial view. One stray key must never brick the store for reading.

New handoffs require a first nonblank line `Session handoff: <summary>`
and exactly one nonempty field for each of:

- `Session IDs: project_session_id=<uuid>` (agent ID is generated)
- `Completed`
- `Active branch`
- `Open PRs`
- `Worktrees`
- `Next work` (existing non-closed Beads IDs, or `(none)`)
- `Review state`
- `Blocked`
- `Decisions`

Do not supply `Supersedes`; the helper generates it. Every healthy automatic
scope has a nonempty slug and never silently inherits another scope's
narrative. Named branches, including `main` and `master`, use the same
collision-resistant normalized/hash derivation. A repository with no commit
yet still resolves to its real branch name, so unborn `main` and unborn
`master` are distinct scopes from their first write. A detached HEAD uses a
stable `detached-<31 hex characters>` slug derived from the commit ID; the
same detached commit reproduces the same scope and different commits do not
alias.

Legacy date-only and sequence-only keys with no slug remain readable through
`session-handoff.sh list` and `bd recall <key>`, but slug-free records are now
legacy/manual records only. They are not migrated or automatically inherited
by `main`, `master`, a detached commit, or any other healthy scope. A legacy
pre-sequence key whose suffix is a bare word (`...-otel`) remains readable in
its own named chain because that shape is structurally indistinguishable from
a hand-written foreign key.

A scope with no handoff names the globally latest key and, when different,
the latest legacy slug-free key, but injects neither body. `--slug` is an
explicit trusted chain override. `--supersede-global` preserves its explicit
cross-scope contract: the minted key keeps the current slug, while the
`Supersedes:` predecessor is the globally latest classifiable handoff.
Without that flag, every ordinary auto-derived scope supersedes only its own
latest record. `show` and startup use that same exact derived scope, so
`show` can print `(none)` immediately after a write in another scope. Key
sequencing remains globally derived, so two slugs writing through the helper
against one local store cannot mint the same key.

The local lock serializes one helper write, but it is not ownership isolation.
Simultaneous sessions in the exact same derived scope are currently
unsupported. Cross-machine writers and native writers are not serialized by
the helper's local lock.

Startup reads one memories snapshot, bounded-pulls for up to five seconds,
and warns visibly when it must use local state. Failed initial clock
sampling skips embedded synchronization but still allows local reads.
Malformed/failed memory reads abort instead of pretending no handoff exists.
Failed ready reads are reported as unavailable, not zero open tasks.

Startup injects the top ten ready tasks (`**Top open Beads tasks:**`) only
when the resolved scope is exactly `main` or `master`, with or without a
handoff. Any other scope - a feature branch, a detached HEAD, or an
indeterminate scope - gets no list and no `bd ready` call, and no empty
header: a branch with a handoff receives only its own handoff, and a fresh
branch is told to start fresh. A fresh non-trunk scope whose SDK payload
carries no initial prompt (`initialPrompt`, or `initial_prompt` in the
VS Code-compatible payload; any non-blank string counts, slash commands
included) additionally instructs the agent to ask the user whether to fetch
open items instead of fetching them. The payload is advisory: empty,
missing or invalid JSON means no prompt and never aborts the hook.
Session end pushes existing state only, never synthesizing handoffs; failed
pushes return nonzero. Uncertain writes/commit/readback failures retain the
allocated key and instruct inspection before retrying, without rollback.

### Commit provenance details

The `prepare-commit-msg` hook reads `COPILOT_AGENT_SESSION_ID`, so a commit made
outside a live session (by a human or CI) carries no `Session-Id:` trailer and
its absence is not a finding. It refuses a malformed value rather than stamping
a bad ID, and it leaves an existing `Session-Id:` line alone, so a hand-written
or chained trailer wins. `project_session_id` is deliberately not in the
trailer: it cannot be read deterministically from the runtime, and a provenance
line that is sometimes invented is worse than one that is narrower than you
would like.

## Operator-enrolled server route

Presence of `server-enrollment.json` selects the strict, existing server
route. It is **macOS-only** (BSD `stat`, `lsof`) and requires Dolt **2.2.0**
plus `bd` **1.3.0-rc.1 (9c6a69ec1)** or **1.3.0**. No server is started,
discovered, initialized, migrated, or adopted. Enrollment and password must
be operator-supplied, gitignored, untracked regular files. The password
requires current-user ownership and mode `600`.

Enrollment is an exact JSON object with:

```json
{
  "version": 1,
  "database": "consumer_database",
  "project_id": "11111111-1111-4111-8111-111111111111",
  "host": "127.0.0.1",
  "port": 3317,
  "user": "operator_user",
  "password_file": "server-password",
  "server_pid": 12345,
  "commit_policy": "all-versioned-tables"
}
```

These are illustrative values, not service defaults. Metadata must exactly
match enrollment and contain `backend:"dolt"`, `database:"dolt"`,
`dolt_mode:"server"`, `dolt_database`, `project_id`, `dolt_server_host`,
`dolt_server_port`, and `dolt_server_user`. `config.yaml` must use this
exact JSON policy (JSON is a YAML subset):

```json
{
  "backup.enabled": false,
  "sync.auto-push": false,
  "dolt.auto-commit": "off",
  "dolt.auto-start": false,
  "dolt.shared-server": false,
  "routing.mode": "explicit",
  "routing.default": "."
}
```

Duplicate keys and local `.env`, `config.local.yaml`, or redirect files are
rejected. Inputs are captured in a mode-700 process-owned directory under
the consumer's common `.git`, then removed on exit. Passwords are never
passed on argv. Executable hashes, enrolled PID's exclusive loopback
listener and executable, exact database/project identity, native context,
and the fixed Dolt ignore policy are attested. Identity is rechecked before
every operational dispatch. The ignored tables are `bd_events_journal`,
`bd_events_seq`, `events`, `ignored_schema_migrations`, `leases`,
`local_metadata`, `repo_mtimes`, `wisp_%`, and `wisps`.

Only context/info/ready/show/list/recall/memories, create/remember, guarded
update, and Dolt commit/push/pull are exposed. Update requires `--claim` or
`--if-assignee` matching the actor. Metadata updates are excluded. Mutation
commits cover **all versioned tables**, not a private transaction, and
postcommit dirty state fails. Sync requires an existing origin remote,
without adoption. See `beads-server.sh` for the exact argument allowlist.

## Consumer-local hooks

APM owns `.github/hooks/agent-harness-hooks.json` and everything under
`.github/hooks/scripts/agent-harness/`; both are listed in the consumer's
`apm.lock.yaml` and are rewritten on update. Project-specific stages belong in
a second descriptor, `.github/hooks/local-hooks.json`, with scripts under
`.github/hooks/scripts/local/`. A distinct filename cannot be overwritten by
deployment, so local stages survive `apm update`.

Each entry needs an explicit `cwd`, because descriptor commands resolve
relative to it. Ordering across descriptor files is unspecified: every stage
registered for an event runs, but a local stage must not assume the
agent-harness stage ran first. Local stages are expected to be fail-soft and
exit 0 on conditions they can only report, since a non-zero session stage can
block the session. `templates/local-hooks.json` and `templates/local-hook.sh`
are copyable examples.

## Bootstrap and optional tools

`scripts/bootstrap-project.sh [consumer-path]` is a **standalone alternative
to APM deployment**, not an automatic lifecycle action. It copies this
bundle into `.github/hooks/scripts/agent-harness` and writes its own
`.github/hooks/agent-harness-hooks.json`, matching APM's default generated
name. A later APM installation replaces that descriptor rather than creating
a second set of session events. Run from the checkout root when using the
standalone descriptor. Newly generated commands use explicit `bash` invocation,
matching the package descriptor. Repeat bootstrap preserves existing descriptors,
including the original standalone bare-path form.

- Bootstrap requires Python 3.9+ and macOS/Linux atomic rename support.
  Ownership, required assets/tools, routing overrides, collisions, and symlinks
  are checked before writes, including repeats and installed self-invocation.
  A complete hooks subtree is privately staged on the same filesystem before
  exclusive publication or atomic directory exchange. There is no unsafe
  two-rename fallback on unsupported platforms/filesystems.
- Atomicity covers the hooks subtree, not the entire consumer: new `AGENTS.md`
  seeding is separate, with rollback on ordinary publication errors. Explicit
  native `bd init` runs after publication; a native failure reports that
  initialization may be partial rather than claiming rollback of database state.
  Keep external filesystem writers quiescent during bootstrap. This is not a
  crash-durable or cross-process transaction for arbitrary consumer files.
- `--dry-run` writes nothing and invokes no native tools.
- A repeat invocation preserves an existing marked bundle; `--force`
  refreshes that bundle only. Unowned descriptors or symlinked destinations
  are rejected rather than overwritten.
- Existing `AGENTS.md` and identity files are never rewritten, including
  existing `<!-- PROJECT-OWNED:BEGIN -->` / `<!-- PROJECT-OWNED:END -->`
  blocks. An absent `AGENTS.md` gets both `PROJECT-OWNED` and `HARNESS-OWNED`
  marker pairs, seeded byte-identical to `templates/AGENTS.md`: an empty
  identity block and a one-line pointer to the instruction files. The seed
  carries no procedure of its own, because a copy of the instructions here
  would drift from the instructions themselves. Use `--skip-agents-md` to
  disable the seed.
- Only `--init-beads` opts into native initialization of an absent common
  store (`bd init --non-interactive --skip-agents`). It never initializes an
  existing store. Initialization does not guarantee a supported route:
  verify with the wrapper's `context --json` before enabling hooks.
- No skills/APM dependencies, labels, dashboard workflows, remote issues,
  or services are installed implicitly. Identity updating is separate work.

Bootstrap deploys **only the runtime bundle and optional absent AGENTS seed**;
it does not install the complete package's skills, personas, or instructions.
Its completion output explicitly warns about this partial setup. To finish,
declare agent-harness in the consumer's `apm.yml` and run `apm install`;
APM installs the manifest's four declared skills rather than adding an
independent bootstrap skill set. The source bootstrap's automatic skills
installation and `--skip-skills` switch are intentionally removed.

Startup installs commit provenance nonfatally. The extra runtime asset
`scripts/git-hooks/prepare-commit-msg-session-id.sh` is necessary because
the source installer depended on an otherwise missing git hook. Installation
uses `git rev-parse --git-path hooks` from the consumer worktree, honoring
absolute and relative `core.hooksPath` settings. Relative configured paths
follow that worktree; the default hooks directory is shared across worktrees.
The installer preserves an existing shell hook as a chained executable and
copies the provenance helper into the resolved hooks directory, so package
or worktree relocation does not leave a live-source reference in the shim.
Non-shell shebangs, symlinked hook files, and conflicting saved hooks are refused.
Unmanaged shell hooks referencing `$0`, its braced parameter expansions
(such as `${0##*/}`), or `BASH_SOURCE` are also
refused: renaming them for chaining can change their dispatch target. This
includes Husky's generated dispatcher. Integrate provenance through that
hook manager manually; automatic session startup leaves it unchanged and warns.
This conservative text check is not a shell dependency analysis: review any
custom hook's sourced helpers before opting into chaining.
A private `mkdir` lock serializes harness installers (bounded wait, no stale-lock
stealing). Complete executable files are staged inside the lock directory and
published with atomic rename, with the wrapper last. Traps clean owned staging
on exit/signals; a saved original remains available if a later publication fails.
This lock does not coordinate unrelated third-party hook installers.

Git's existing hook runs first and can fail the commit. A valid UUID is required
when a Copilot session ID is supplied; human commits without one are unchanged.
`git interpret-trailers` appends provenance without breaking existing trailer
groups or patch text; existing Session-Id lines remain unduplicated on retries.
Session-start installation failures remain visible stderr warnings, not resume
failures. Unlike the upstream nonfatal provenance shim, an invalid session ID
in an installed hook is a commit failure here, rather than silently dropping
requested provenance.
`install-git-hooks.sh --help` and `-h` only print usage; unknown arguments
fail before resolving or modifying any checkout.

These hardening rules were ported from
[eridanilabs/replicant-harness#5](https://github.com/eridanilabs/replicant-harness/pull/5)
at source commit `5f68f9cd16046ea395ab22978c020821de13cde4`, preserving this
package's consumer-path resolution and existing hook chaining.

`setup-labels.sh --apply [--repo [host/]owner/repo]` explicitly installs the
optional example type/priority/owner/status catalog. It requires `jq` and
authenticated `gh` with write access. It reads every page of existing labels,
keeps identical definitions, and creates missing labels without `--force`.
Conflicting colors/descriptions abort the entire plan before any writes.
`--dry-run` prints the plan without changes; add `--overwrite-existing` to preview
or explicitly apply reconciliation of consumer definitions. Missing-label
creation still refuses a label created concurrently instead of overwriting it.
An API failure while applying a plan is reported; previously applied label
operations are not a transaction.

`update-dashboard.sh --dry-run` requires `gh`, Python 3, and `DASHBOARD_ISSUE`.
It reads a snapshot and prints a proposed body to stdout, with a proposal-only
notice on stderr. Calls without `--dry-run` fail before any API call.
**Automatic issue-body writes are disabled**, not protected by a pretend lock:
[GitHub documents that unsafe-method conditional requests are unsupported
unless an endpoint says otherwise](https://docs.github.com/en/rest/using-the-rest-api/best-practices-for-using-the-rest-api#use-conditional-requests),
and issue update has no documented compare-and-swap contract. Checking
`updated_at`/ETag immediately before a PATCH still leaves a race; a process or
filesystem lock does not coordinate GitHub UI users or other API clients.
Review/reconcile proposals manually; never blindly pipe them into `gh issue edit`.

Row commands default to the exact `Active Work Streams` Markdown heading.
Use `--section <exact heading>` before the command to select a different section.
Exactly one five-column table with leading `Status` and `Repo` headers must
exist there. Only its contiguous data rows are candidates; headings, header and
separator rows, fenced code, and other sections are not. Update/remove require
exactly one literal pattern match; missing/ambiguous rows and malformed tables
fail without partial output. Cell inputs containing pipes or newlines are
rejected rather than injecting extra rows. `add-note` defaults to an exact
`Notes` section; `refresh-timestamp` requires exactly one visible `Last refreshed`
line (optionally section-scoped).

## Offline validation and limits

```sh
find .apm/hooks -name '*.sh' -exec bash -n {} \;
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p 'test_*.py' -v
```

Tests require Python 3.9+ standard library, Git, jq, Bash, Perl and OpenSSL.
Fixtures are created below `tests/.fixtures` and removed afterward. Native
`bd`, `dolt`, GitHub calls, and server PID/listener inspection are doubles;
Git operations use isolated fixture repositories, HOME and configuration.
No production store, service, remote issue, or source checkout is changed.
Lifecycle tests use real, fixture-owned child/grandchild processes: timeout,
SIGTERM, and SIGINT must remove both recorded PIDs while an unrelated sentinel
stays alive. A fixture-only mutation disabling cleanup was verified to fail
these assertions even though the timeout still returned 124.
Server-specific tests skip on non-macOS. This validates packaged paths,
consumer/worktree routing, handoff semantics, strict failures, attestation
boundaries and bootstrap preservation, **not live native compatibility,
APM installer implementation, app delivery, or concurrent server safety**.
Version support retains the source's verified-version allowlist; this
migration does not claim new native-version verification.
