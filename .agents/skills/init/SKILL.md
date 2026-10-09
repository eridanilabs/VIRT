---
name: init
description: Explicit-invocation only. Use ONLY when the user asks to initialize or bootstrap agent-harness in this project (for example "run init"). Never trigger automatically. Runs the deployed bootstrap and hook-install scripts after user confirmation and creates or fills AGENTS.md when it is missing or its PROJECT-OWNED section is exactly the scaffold placeholder.
---

# init

Set up agent-harness in a consumer project after `apm install`.

The skill stays installed and is never self-removing. It is a managed APM
primitive, so `apm update` would redeploy it anyway, and a removed skill cannot
be re-run on the next clone or after a change in the project. Lifecycle rules:

- **Explicit invocation only.** Never trigger automatically.
- **Re-running after a successful init is a safe no-op.** Bootstrap preserves
  existing descriptors, the hook installer is idempotent once its marker is
  present, `bd bootstrap` reports "Nothing to do" against an existing database,
  and an `AGENTS.md` with real content is left untouched. Start at step 0 and
  report rather than redoing work.
- **Re-running after a FAILED init is not a recovery.** See the failure rule in
  step 1; repair first.

It only runs the already-deployed scripts and asks questions; do not write new
scripts, state files, or detection logic.

Scripts live in `.github/hooks/scripts/agent-harness/scripts/` (run them by this path from the repo root; bare names exit 127). Prerequisites:
`jq`, `python3` (3.9+, required by bootstrap), and `bd`.

Run `bd --version` and check it against 1.2.2, 1.3.0-rc.1, or 1.3.0 before
anything else. Nothing in the bootstrap path enforces this: `bd init` and
`bd bootstrap` accept any version, and the check in `bd.sh` happens later, at
session time. An unsupported version therefore initializes a store the hooks
will then refuse to read. Report the mismatch and stop.

Run everything from the main checkout (`BEADS_ROOT`). If
`git rev-parse --show-toplevel` differs from the first entry of
`git worktree list`, you are in a linked worktree: stop and ask the user to run
from the main checkout.

## 0. Is this already initialized?

Run `.github/hooks/scripts/agent-harness/scripts/doctor.sh`. It is read-only.
If it reports no failures and the `prepare-commit-msg` wrapper is in place, the
project is already initialized: show its output, say so, and ask whether the
user still wants to continue rather than running bootstrap again. Continuing is
safe, but it is usually not what was intended.

## 1. Bootstrap, then hooks (one confirmation)

1. Test the disk, not git: does `.beads/` exist? If NOT, use `--init-beads`. If it
   exists (tracked or not, fresh clone or earlier init), do NOT pass `--init-beads`.
2. If `BEADS_DIR`, `BEADS_DB`, `BD_DB` or any `BEADS_DOLT_*` is set in the
   environment (checked on BOTH paths, before `bd bootstrap` too), report it and
   stop; never unset them yourself.
   Dry run: `.github/hooks/scripts/agent-harness/scripts/bootstrap-project.sh --skip-agents-md [--init-beads] --dry-run`.
3. Show the dry-run output and, as information only, the current hooks location:
   `git config core.hooksPath` and `git rev-parse --git-path hooks`. Empty output
   with exit 1 from `git config` means `core.hooksPath` is unset (default hooks
   dir); that is not a failure. Say that bootstrap may change `core.hooksPath`
   (`bd init` sets it to `.beads/hooks`, even if it was `.git/hooks` or an in-repo
   dir like `.githooks`). Record the OLD value. If it is currently set, say plainly
   that confirming lets bootstrap's `bd init` repoint it to `.beads/hooks`.
4. ASK ONCE for confirmation covering the real bootstrap, `bd bootstrap`, and the
   hook install. A dry run is not consent. Run none of them without a yes.
5. Run the bootstrap command without `--dry-run`.
6. If `.beads/` existed, run `bd bootstrap`. It is a no-op ("Nothing to do") only
   when the database already exists; on a fresh clone it creates a local database
   ("Bootstrap plan: create fresh database"). If it errors, stop and report. Never
   run `bd init` when `.beads/` exists; on a fresh clone it forks the Beads identity.
7. Immediately before the installer, RE-RUN `git config core.hooksPath` and
   `git rev-parse --git-path hooks`. If the location differs from what the user
   saw (same empty/exit 1 = unset rule), tell them the old value and that hooks in
   the old directory are no longer the active hooks directory. They can restore it
   with `git config core.hooksPath <old>` (or `git config --unset core.hooksPath`
   if it was unset). Re-ask before continuing. Also, if the final hooks dir
   is inside the repo (for example `.beads/hooks`, tracked) or OUTSIDE this repo's
   `.git/hooks` (for example a global `~/.githooks`, which affects every repo),
   the user decides before the installer runs. The installer does not require
   that directory to exist: it runs `mkdir -p` on whatever path git resolves and
   writes there. With a global `core.hooksPath` that means creating and
   populating a hooks directory used by every repository on the machine.
8. Check whether `prepare-commit-msg` already exists in that final hooks
   directory. If it does, say before running the installer that the existing
   hook will be renamed to `prepare-commit-msg.agent-harness.previous` and
   called first by a wrapper. After `--init-beads` the hooks directory is
   usually `.beads/hooks`, so that existing hook is commonly bd's own and may
   be a tracked file, which makes the rename a visible working-tree change.
9. Run `.github/hooks/scripts/agent-harness/scripts/install-git-hooks.sh` (bootstrap never calls it).

Bootstrap also pins apm's deployment target: if `apm.yml` exists and has no
`targets:` key, it appends `targets: [copilot]`. apm only auto-detects a target
while exactly one runtime layout is present, and `bd setup codex` adds `.codex/`
next to the Copilot layout, so an unpinned consumer starts failing or prompting
on later `apm update` runs. An existing `targets:` key is never rewritten, and
a consumer with no `apm.yml` is reported, not changed. To pin a different target
afterwards, run `.github/hooks/scripts/agent-harness/scripts/pin-apm-target.sh
--target <name>`. Tell the user to commit the change so every clone resolves the
same target.

Failure rule: key this on the error text, not on the presence of a success
line. "Runtime published" prints only on the `--init-beads` path, so its
absence does not mean nothing was written.

- Nothing was written, and it is safe to stop and report: a preflight failure,
  which names the specific precondition (ownership, a required asset or tool, a
  routing override, a collision, a symlink) and reports no stage.
- Something WAS written: any message containing "runtime committed before
  subsequent failure", "private staging cleanup failed", or a failed `bd init`,
  as well as any failure after "Runtime published" on the `--init-beads` path.
  A staging-cleanup failure in particular reports leftover files, not an
  unwritten runtime.

In the second case tell the user to inspect and repair; retrying is not a
recovery, because `.beads/` may now exist and init would be skipped.

The bootstrap warning "skills, personas, and instructions were not installed ...
run apm install" is an unconditional informational message; ignore it if
`apm install` already ran.

## 2. Hook installer refusals

`install-git-hooks.sh` refuses: a non-shell existing `prepare-commit-msg`, a
symlinked or non-regular destination, a filename-sensitive hook (uses `$0` or
`BASH_SOURCE`, e.g. Husky), a foreign existing hook whose `.previous` backup
(`prepare-commit-msg.agent-harness.previous`) already exists and would be
overwritten, and a live lock `$HOOKS_DIR/.agent-harness-install.lock`. A lock is
reclaimed automatically only when its recorded owner process is provably gone.
It is idempotent when the hook already carries the agent-harness marker:
re-running leaves an existing `.previous` alone and exits 0. If `core.hooksPath`
points inside the working tree (`bd init` sets `.beads/hooks`), the installer
excludes its machine-local files through `.git/info/exclude` and reports a
tracked hooks directory once. Report refusals; never work around them, and NEVER
delete the lock file.

## 3. AGENTS.md

Read `AGENTS.md`. Act only if it is missing, or it has exactly one PROJECT-OWNED
BEGIN and one END marker, in order, and the section between them contains nothing
except the exact scaffold placeholder HTML comment (shown below). Any other text
in that section counts as non-empty: skip and report. If the markers are
duplicated, out of order, or only one is present, leave AGENTS.md untouched and
report. An existing file lacking BOTH markers is also left untouched and reported:
never add the scaffold to it or write into existing user content. When skipping,
go to step 4.

Ask the user a few short questions in chat (project name and purpose, domain
constraints, local preferences). Show the proposed PROJECT-OWNED text and get a
yes before writing it inside the PROJECT-OWNED block.
If the file is missing, create it from this scaffold (apm does not deploy
`templates/AGENTS.md`, so it is embedded here):

```markdown
<!-- PROJECT-OWNED:BEGIN -->
<!-- Project identity, purpose, domain constraints, and local preferences.
     This region belongs to the consuming project, not agent-harness. -->
<!-- PROJECT-OWNED:END -->

<!-- HARNESS-OWNED:BEGIN -->
Shared procedures are the agent-harness instruction files in `.github/instructions/`.
<!-- HARNESS-OWNED:END -->
```

The project-owned block always comes first: it is the part a reader of this
repository needs, and the part you edit. The harness-owned block is a pointer
to the instruction files and nothing more; it carries no procedures of its own,
so there is nothing in it to keep in sync by hand.

If the file exists with markers, edit only between the PROJECT-OWNED markers.

## 4. Report

Run `git status --short` and tell the user what to commit. Do not assert an exact
status: the installer writes to the active hooks directory and stages nothing.
Note that `bd init`'s own commit and its `core.hooksPath` change are native,
version-dependent Beads behavior, not something these scripts guarantee.
Summarize what ran, what was skipped, and any refusals.

Two consumer decisions belong in that report, because nothing else prompts for
them. First, whether the apm deploy directories are committed or gitignored —
both are valid, but mixing them produces a clone that works only for whoever
ran the install. Second, if the project uses graphify, that `.gitattributes`
needs `**/graphify-out/graph.json merge=graphify`; the matching git config is
machine-local and does not survive a clone. Commit `apm.lock.yaml` either way.

Then run `scripts/doctor.sh` from the harness scripts directory and show the
user its output. It is read-only and reports on every side effect an install
leaves behind: required tools, the `bd` version, the git hooks directory and
`prepare-commit-msg` wrapper, the session id variable, the apm target pin, and
the graphify wiring. It exits non-zero only on a `FAIL`. Report what it says
rather than re-deriving the same checks by hand.
