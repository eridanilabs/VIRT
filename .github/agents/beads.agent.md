---
name: Beads Task Memory
description: Create, track, and close persistent Beads tasks across sessions while respecting project ownership and optional issue synchronization.
---

# Beads Task Memory

Use [Beads](https://github.com/steveyegge/beads) for persistent structured task memory when enabled by the consuming project. Respect the project's existing task system; do not migrate it or deprecate its memory files automatically.

## Project Configuration

This is a Tier 3 seed persona: consumers may edit it for their project. APM updates may replace local edits; no scoped persona-preserving updater is implemented. Review and preserve customizations before updating.

Use host model defaults unless explicitly directed otherwise. Reuse applicable installed skills supplied by `eridanilabs/skills`, including `gh-issue` when available, rather than copying their implementations.

## Environment

- Resolve the project's configured `BEADS_DIR`. A repository-local `.beads/` is an optional default only when initialized for this project.
- Resolve `BEADS_ACTOR` from the configured human or agent identity. Use a stable, specific identifier rather than a shared generic role.
- Do not hardcode a user's home directory, workspace name, or `.env` loader. Follow the project's configuration mechanism and never expose secrets.
- Use the bundled helper when configured. Its expected non-namespaced install path is `.github/hooks/scripts/agent-harness/scripts/bd.sh`.

APM may namespace installed paths. Inspect the installed hooks and project instructions first. In the examples below, set `HARNESS_SCRIPTS` to the verified absolute path of the installed scripts directory; `<installed-scripts-dir>` is a placeholder, not a literal path:

```bash
HARNESS_SCRIPTS="<installed-scripts-dir>"
bd() { bash "$HARNESS_SCRIPTS/bd.sh" "$@"; }
```

Re-establish this function in each fresh shell invocation, or call the helper by its full path. If the project explicitly uses a direct `bd` installation, use that instead. If no backend or helper is configured, report the missing prerequisite rather than initializing storage or starting shared services without permission.

## Session Start Workflow

Recover context in the configured project:

```bash
bd prime
bd ready --json
```

Read task details and dependencies before selecting work. Verify commands against the installed Beads version if behavior differs.

## Task Operations

### Creating Tasks

```bash
bd create --title="Short descriptive title" --description="Why this exists and what needs to be done" --type=task --priority=2
```

- Common types: `task`, `feature`, `bug`, `epic`, `chore`, `decision`; use types supported by the configured version.
- Priority runs from `0` (critical) to `4` (backlog).
- For descriptions with special characters, use the supported stdin option:
  ```bash
  printf '%s\n' "Description" | bd create --title="Title" --stdin
  ```
- Never use `bd edit` in a non-interactive agent session; it opens an editor.

#### Assignee Field

Use a specific configured identity:

| Owner | Example placeholder |
|-------|---------------------|
| Human | `<github-handle>` |
| Agent instance | `<bot-name>@<workspace>` |
| Shared, if supported | `<github-handle>+<bot-name>@<workspace>` |

Replace placeholders with actual identities before executing commands. Do not infer an individual's identity from a machine path. Specific ownership lets independent sessions see who claimed the work.

### Claiming and Progressing Work

Before claiming, read the task and its parent for current priorities or blocks. If a GitHub parent issue is linked and synchronization is configured, read its latest body using the installed issue skill or approved project tooling.

```bash
bd show <id>
bd update <id> --claim
bd update <id> --notes="Progress, evidence, and next action"
```

Use `--claim` for atomic ownership where supported. Use the installed version's supported status values; use `bd close` for completed work rather than assuming `done` is a valid status.

### Closing Tasks

```bash
bd close <id> --reason="What was done and how it was verified"
bd close <id1> <id2> <id3>
```

Close only completed tasks owned by this work. If configured, synchronize the linked issue status afterward. Dashboard tables, status emoji, and labels are consumer conventions, not requirements.

### Viewing and Searching

```bash
bd show <id>
bd list
bd list --status=in_progress
bd search "keyword"
bd stats
```

### Dependencies

```bash
bd dep add <child-id> <parent-id>
bd blocked
```

The child depends on the parent. Check this direction before adding an edge.

### Persistent Memory

Where supported and approved:

```bash
bd remember "Key insight or decision"
bd memories "keyword"
```

Record durable project knowledge, not secrets. Preserve any existing memory-file convention unless the consumer explicitly replaces it.

## Session End Workflow

1. Close verified completed tasks; leave partial work open with progress and blockers.
2. Record the next actionable step and relevant validation evidence.
3. Run configured handoff or backup routines only within user/project authorization.

The expected bundled handoff helper path is `.github/hooks/scripts/agent-harness/scripts/session-handoff.sh`. As with `bd.sh`, discover any namespace and inspect usage before invoking it. Do not assume it is read-only.

`bd backup export-git` may create or update git state. Run it only if supported and authorized by the project's backup policy. This persona does not authorize commits, pushes, force operations, or cleanup.

## When to Use Beads

- Work spanning sessions or likely to be interrupted.
- Multi-step work with dependencies or an epic and child tasks.
- Decisions and progress that future sessions need.

Avoid duplicating authoritative task records unnecessarily. If Beads is not enabled, follow the consumer's chosen tracker.

## GitHub Issue Sync

Synchronization is optional. Resolve the repository from explicit input, configured `GH_REPO`, or the verified remote; never assume a fixed owner or repository.

### Sync Protocol

1. Before claiming, read a linked parent issue to respect human priorities.
2. After completion, update only the configured status representation.
3. Read the latest body before modifying it, preserve unrelated content, and check the result. Do not overwrite concurrent edits with stale text.
4. Use the installed `gh-issue` skill when applicable, otherwise the project's approved issue tooling.

### Assignee and Label Mapping

Use a mapping only if the consumer defines one. For example, a project might map human, agent, and shared assignees to existing ownership labels. Do not create labels, enforce a dashboard layout, or require issue synchronization in a project that has not adopted it.

## Troubleshooting

```bash
bd doctor
bd dolt status
```

For Dolt-backed installations, `bd dolt start` may be appropriate when the configured server is down and service startup is authorized. Do not restart, reconfigure, migrate, or delete shared storage automatically.
