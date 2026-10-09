---
description: Project-local Beads task capsules, durable memory, and targeted recall
applyTo: "**"
---

# Beads memory and task discipline

- Beads is the durable project-local task and memory system. Do not create
  `MEMORY.md` files or competing markdown task lists as a second source of truth.
  Host-required ephemeral planning tools are not replacements for durable tasks.
- Load the installed `beads` skill for its native command semantics. Skills come
  from `eridanilabs/skills`; do not edit deployed Tier-1 skill content locally.
- Invoke `bd` through the installed harness wrapper in linked/child sessions:
  `.github/hooks/scripts/agent-harness/scripts/bd.sh <arguments>`.
  Check the deployed hook JSON/README if your installer uses another bundle name.
- From the consumer checkout, use `where --json` and `context --json` through
  that wrapper to confirm its existing common-checkout store. Current-worktree
  `git rev-parse --show-toplevel` alone does not identify a shared Beads store.
- A different repository uses its own store. Never export another project's
  `BEADS_DIR` globally or synthesize database enrollment to "fix" routing.
  Unset stale inherited overrides; deliberate foreign-store access must use
  the helper's explicit opt-in and be authorized.

## Operational capsule

The task issue is the capsule. Read it, claim it when authorized with
`bd update <id> --claim`, and read it back. Assignee plus `in_progress` signals
ownership; neither is proof that a process is still running.

Append progress with `bd note`. For supported metadata operations, read, merge,
write, and read back without dropping fields. Keep the working capsule compact
(roughly 1,500 tokens). `decisions`, `active_refs`, and `blockers` are
single-writer fields for the current claim-holder. An orchestrator annotating
another worker's task uses a disjoint flat key such as
`metadata.orchestrator_note`, never rewrites the worker's nested keys.
This convention is not concurrent-write protection.

Turn actionable follow-ups into real child issues:

```bash
bd create --parent <task-id> --title "Concrete follow-up" -t task
```

Only non-closed, resolvable issue IDs belong in a handoff's `Next work` field.
Task status belongs in issues, not `bd remember`. Reconcile task/epic state
before presenting progress if the consumer uses both Beads and GitHub issues;
preserve human edits and make ownership conflicts explicit.

## Write durable knowledge immediately

Use `bd remember "Self-contained fact, including why."` as soon as you discover:

- A non-obvious decision, resolved trade-off, gotcha, or workaround.
- A critical configuration value or path.
- A reusable review anti-pattern or operational incident.
- Anything that would take more than five minutes to rediscover.

Do not batch knowledge until session end. End hooks can back up only what was
already recorded. Use `bd forget <key>` only for genuinely erroneous/stale
facts or reversed decisions, never to rotate session handoffs.

An available `store_memory` tool is an optional cold-start mirror, not the
load-bearing store. Mirror only critical stable orientation (locations,
validated commands, conventions, incident lessons). Do not mirror transient
task status. A one-line handoff pointer is optional when useful.

## Recall narrowly

- `bd memories <keyword>` searches a topic before implementation, research,
  or review; `bd recall <exact-key>` reads a known fact.
- Never run unfiltered `bd memories` to preload the entire store.
- Read `bd ready --json` lazily when task context is needed or the injected
  main/master list is insufficient, not for every greeting or unrelated question.
- Off main/master with no handoff and no initial prompt, ask before fetching
  open tasks.
- The session-start context is sufficient for initial orientation; deeper
  recovery uses targeted memory, git status/log/worktrees, and the active task.

## Store and process boundaries

The wrapper/hook exports apply only inside that process; they do not configure
subsequent tool calls. An explicit actor is preserved. Session-derived actors
can differ across sub-agents and host sessions; do not assume a parent's claim
authorizes a child's write. Have the owner make the update or deliberately
delegate an actor according to the backend's ownership rules.

The default route uses a version-checked embedded Dolt store. The optional
server route requires operator enrollment and direct-SQL project/database
attestation, and supports only a restricted command set. Do not initialize,
reset, restart, or reconfigure real stores to bypass errors. Raw `bd` can bypass
wrapper protections. Helper handoff locks serialize only local helper writers,
not native writes, other machines, or arbitrary metadata edits.

## Content graphs are not memory

Content graphs describe static relationships; they are not memory. Tasks,
rationale, and session state stay in Beads, which is authoritative. Graph usage
is `graphify.instructions.md`'s subject, not this file's. Package dependencies
supply skills, not a shared cross-project knowledge corpus or database.
