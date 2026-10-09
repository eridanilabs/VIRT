---
description: Branch-scoped session resume and validated chained handoff mechanics
applyTo: "**"
---

# Session resume and handoff

- The session-start hook injects `## Session Resume State` with the latest
  matching Beads handoff and, on main/master only, top open tasks through
  `additionalContext`. Beads is authoritative; do not write `.handoff-state.md`.
- On the first interaction, acknowledge relevant resume state and confirm
  scope when the user's request leaves it unclear. If the new request is
  unrelated, treat the handoff as background and follow the request.
- With no resume block, respond normally. Do not bulk-load Beads proactively.
- For deeper recovery, inspect current git status, worktrees, recent commit
  trailers, active PR/task/epic, and targeted memory. Do not assume all work
  was pushed merely because a prior handoff says so.

## When to hand off

Record a fresh structured handoff after a completed batch, before a context
clear/new session, at a meaningful pause, or when the user sends standalone
`handoff` or `:wq`. For those cues, write and verify the handoff without another
confirmation unless the workstream identity is ambiguous.

Use the installed helper:

```bash
.github/hooks/scripts/agent-harness/scripts/session-handoff.sh --help
.github/hooks/scripts/agent-harness/scripts/session-handoff.sh write <<'HANDOFF'
Session handoff: <one-line summary>.
- Session IDs: project_session_id=<actual-project-session-uuid>
- Completed: <completed work or (none)>
- Active branch: <current branch>
- Open PRs: <repo, number, status or (none)>
- Worktrees: <owned active paths and branches or (none)>
- Next work: <real non-closed Beads IDs or (none)>
- Review state: <cycles, accepted findings, or not applicable with reason>
- Blocked: <blockers or (none)>
- Decisions: <durable decisions or (none)>
HANDOFF
.github/hooks/scripts/agent-harness/scripts/session-handoff.sh show
```

The placeholders above are not valid IDs. Obtain `project_session_id` from
the host's session metadata or session-list tool; never invent one. The helper
appends `agent_session_id` from `COPILOT_AGENT_SESSION_ID`, which must have UUID
format and is validated before store access for writes. Both IDs matter
because they can diverge after a context clear. If the runtime cannot provide
required provenance, report the blocker rather than fabricating a handoff.

All nine fields are required exactly once and must be nonempty. Supply no raw
`Supersedes` field and no embedded `agent_session_id`; those are generated.
`Next work` must be comma/space-separated resolvable non-closed Beads issue IDs
or `(none)`, not prose. File the concrete next tasks before writing.
Consult the helper and shared validator for full enforced rules; malformed
input must fail rather than produce a success-shaped partial record.

## Commit provenance

A hook adds `Session-Id: agent_session_id=<uuid>` from
`COPILOT_AGENT_SESSION_ID`; commits outside a session carry none.
`project_session_id` belongs in the commit body.

## Branch isolation and history

Keys use `session-handoff-<project>-<UTC timestamp>-<suffix>[-<slug>]`.
The project identity is derived from the consumer repository, not the package.
Every healthy automatic scope has a nonempty derived slug; named branches,
including `main` and `master`, derive it deterministically and are distinct. A repository with no commit yet still resolves to its
real branch name, making unborn `main` and unborn `master` distinct from their
first write. A detached HEAD uses a stable commit-derived
`detached-<31 hex characters>` slug, so the same detached commit reproduces
the same scope while different commits remain separate. A scope with no
handoff starts fresh.

Legacy date-only and sequence-only keys with no slug remain readable through
`list` and `bd recall`, but are legacy/manual records only: `main`, `master`,
detached commits and other branches never inherit them. A legacy pre-sequence
key whose suffix is a bare word stays readable under its own named chain.

Without a flag, a write supersedes only the latest record in its exact scope.
An explicit `--supersede-global` keeps the minted key in the current scope but
takes `Supersedes:` from the globally latest classifiable handoff. Key
sequence allocation remains global. `show` and startup use the same exact
derived scope, so `show` can report `(none)` immediately after a write in
another scope; use `list` or `bd recall` to read across scopes.

Simultaneous sessions in the exact same derived scope are not
ownership-isolated and are currently unsupported. Cross-machine writers and
native writers are not serialized by the helper's local lock. Explicit
`--slug NAME` is a trusted override and can select another branch's literal
chain; it is not collision-protected. Use it deliberately, not as a
workaround for missing branch identity.

Never `bd forget` a previous handoff as a rotation step. New entries link back
through generated `Supersedes: <key>`, preserving an audit trail. Read history
with targeted `bd memories session-handoff` or exact-key recall. Native
`bd supersede` links issues, not plain `bd remember` records.

Historical handoffs remain readable even if they predate today's strict
new-write shape; do not rewrite old records merely to satisfy the new validator.
Verify each new write with `show` and report its key. Startup pull failures
yield explicitly local-only context; they do not prove remote synchronization.
