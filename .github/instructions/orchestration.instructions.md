---
description: Delegation, isolated worktrees, and implementation orchestration
applyTo: "**"
---

# Orchestration and worktrees

**Consumer overrides: the identity block wins.** Where the project-owned block
of the consumer's `AGENTS.md` contradicts anything below, follow the identity
block. These are the defaults for a project that has not said otherwise, not
rules the consumer has to argue its way out of. The exceptions are the
authorization limits in the next bullet, which an identity block cannot widen.

- Respect the user's request, the consumer's identity block and git policy,
  and the host's tool/permission constraints. These procedures are not permission
  to commit, push, merge, create worktrees, or delete data without authorization.
- In orchestrator mode, delegate implementation and fixes to the Implement
  persona and code review to the Review persona. Do not bypass the review
  history with a "quick" direct fix. The orchestrator gathers context, triages
  evidence, coordinates work, and tracks completion.
- Use the installed agent names exposed by the host, not a hardcoded
  `agent_type` spelling. APM can namespace installed persona filenames.
  If a role is unavailable, report that limitation and agree on a substitute;
  do not claim that an independent review happened.
- Research belongs with the researcher/research-writer personas; agent
  definition work belongs with agent-builder. Answer ordinary questions directly.
- Read the active task or epic, acceptance criteria, dependencies, existing PRs,
  and current git state before selecting work. A successful implementer return
  is an implementation pass, not task completion.
- Parallelize only independent work. Give each code-writing worker an isolated
  checkout and owned branch when the host and user authorize it. Never run
  concurrent writers against the same files, branch, or task metadata keys.
- Do not switch an in-place user-owned checkout, rename its branch, or create
  worktrees merely because these examples describe a worktree workflow.

## Delegate with enough context

An implementation prompt supplies the absolute working directory, already
checked-out branch, bounded deliverables, acceptance tests, existing types and
patterns, architecture constraints, language/toolchain, and allowed git actions.
Do not duplicate the persona's full instructions.

A review prompt supplies the absolute working directory, exact diff command
(for example `git --no-pager diff main...<branch>`), architectural context,
scope, and expected file/line evidence. Review is read-only.

A fix prompt includes only findings verified against the source, the relevant
diff or PR, the expected behavior, and enough architecture context to fix the
cause. Re-test and re-review the updated diff after every fix pass.

Escalation runs from worker to orchestrator to human. Resolve concerns from
evidence when possible; surface unresolved design questions instead of silently
discarding them. Host model defaults apply unless the user specifies otherwise.

## Branch and worktree naming

For host-managed session worktrees, name the branch with the host's supported
rename tool when authorized. Use a short task-specific kebab-case slug before
the first commit. Do not rename the host-owned worktree directory or bypass
host metadata with `git branch -m`. If an open PR prevents renaming, retain it.

For explicitly created task worktrees, the recommended branch pattern is:

```text
<type>/ep<N>-<agent>-<task-slug>
feat/ep42-implement-add-jwt-middleware
```

`type` is a conventional-commit type, `N` is the epic issue number, `agent` is
the owning role, and `task-slug` is a concise kebab-case description (normally
at most 25 characters). Use a real task identifier instead of inventing an epic
when the consumer has no GitHub epic. Consumer naming policy takes precedence.

`workbench/<branch-leaf>` is a suggested, gitignored workspace root, not a
required repository directory. The leaf is the part after the final `/`.
Consumers may choose another root. Put authorized external checkouts in a
similarly explicit reusable location; never clone again when one exists.

| Branch exists | Worktree exists | Action |
| --- | --- | --- |
| No | No | `git worktree add -b <branch> <root>/<leaf>` |
| Yes | No | `git worktree add <root>/<leaf> <branch>` |
| Yes | Yes | Reuse the existing checkout |

Before reuse, confirm that the checkout actually owns the expected branch.
After a completed batch, inspect `git worktree list` and git status. Remove only
owned, finished worktrees after work is safely preserved and deletion is
authorized; prefer `git worktree remove <path>` without `--force`. Prune stale
registrations, and delete only branches confirmed merged/closed and no longer
in use. Never enforce "only main remains" against unrelated user work.

## Completion

Finish the Review-Fix Loop before opening a PR or marking work complete.
Merge only with authorization and in dependency order. Update the consumer's
task/epic tracker and changelog when present, file actionable deferred findings,
record reusable decisions, and write a structured session handoff. Preserve
unrelated edits in shared issue bodies. Clean up only the resources this task
owns. Report blocked commits, pushes, or sync explicitly; never silently treat
local-only work as published.
