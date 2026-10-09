---
name: gh-issue
description: Interact with GitHub Issues in a repository via the gh CLI
---

# gh-issue

This skill teaches the agent how to read, create, and update GitHub Issues using the `gh` CLI.

## Repo targeting

Never hardcode an org/repo into a command. Instead:
- Pass `--repo <owner>/<repo>` explicitly on every `gh` command, or
- Export `GH_REPO=<owner>/<repo>` once in the environment and omit `--repo` thereafter.

If the calling project has a default repo (its own origin, or a documented set of related
repos it manages), resolve `<owner>/<repo>` from that context — never assume a fixed value.

**Never use MCP for issue reads/writes — always use the `gh` CLI directly.**

## Reading issues

```bash
# View a single issue
gh issue view <number> --repo <owner>/<repo> --json title,body,labels,state,number

# List all open issues
gh issue list --repo <owner>/<repo>

# List issues with a given label
gh issue list --repo <owner>/<repo> --label epic

# List issues assigned to a user or actor
gh issue list --repo <owner>/<repo> --assignee <username>
```

## Creating issues

```bash
# Create from a YAML template (interactive — prefer for human-initiated issues)
gh issue create --repo <owner>/<repo> --template epic.yml

# Create non-interactively with explicit fields
gh issue create \
  --repo <owner>/<repo> \
  --title "[EPIC] My epic title" \
  --body "$(cat body.md)" \
  --label epic

gh issue create \
  --repo <owner>/<repo> \
  --title "[FEAT] My feature title" \
  --body "$(cat body.md)" \
  --label feature
```

## Updating issues

```bash
# Overwrite the entire issue body (always read first — see below)
gh issue edit <number> --repo <owner>/<repo> --body "..."

# Add/remove labels
gh issue edit <number> --repo <owner>/<repo> --add-label "status:in-progress"
gh issue edit <number> --repo <owner>/<repo> --remove-label "status:in-progress"

# Close / reopen
gh issue close <number> --repo <owner>/<repo>
gh issue reopen <number> --repo <owner>/<repo>
```

## Updating a Section of the Issue Body (Read → Modify → Write Back)

Issue bodies are **full overwrites** — always read first, modify in memory, then write back.
Epic issues commonly contain a **Task Table** section that the agent updates incrementally;
use this pattern to update only that section without clobbering the rest of the body:

```bash
# Step 1 - read the current body
BODY=$(gh issue view <number> --repo <owner>/<repo> --json body --jq '.body')

# Step 2 - modify the relevant row in the task table (using sed, awk, or Python)
# Example: mark a task row as done
UPDATED_BODY=$(echo "$BODY" | sed 's/| ⬜ pending | My Task Title |/| ✅ done | My Task Title |/')

# Step 3 - write the updated body back
gh issue edit <number> --repo <owner>/<repo> --body "$UPDATED_BODY"
```

For complex edits (multiple rows, varied formatting), prefer a small Python or bash script
over inline sed to avoid quoting issues.

### Task Table convention

The task table lives inside the **Task Table** section of epic issue bodies:

```
| Status | Task | ID | PR | Owner |
|--------|------|----|----|-------|
| ⬜ pending | Short task title | proj-001 | #12 | agent |
| 🔄 in-progress | Another task | proj-002 | #13 | human |
| ✅ done | Completed task | proj-003 | #14 | agent |
| 🚫 blocked | Blocked task | proj-004 | #15 | both |
```

Status icons:
- `⬜ pending` — not started
- `🔄 in-progress` — claimed and active
- `✅ done` — closed
- `🚫 blocked` — has an open blocker

## Labels

```bash
# Create a label idempotently
gh label create "epic" --repo <owner>/<repo> --color "6E40C9" --description "Epic tracking issue" --force

# List labels
gh label list --repo <owner>/<repo>
```

## Notes

- **Never use MCP for issue reads/writes** — always use `gh` CLI directly.
- Always pass `--repo <owner>/<repo>` explicitly, unless `GH_REPO` is already set in the environment.
- Use `--json` output for programmatic processing; use default output for human-readable display.
- For bulk updates across multiple issues, script them with `gh issue list --json | jq` pipelines.
- For the epic/task sync protocol against a project-specific memory or task-tracking system,
  see that project's own task-tracking skill/agent docs — this skill only covers the `gh` CLI mechanics.
