# The loop

**This file is the factory.** `/factory` rereads it on every run, so changes to stages, models, or rules take effect on the next feature. It ships with the `/factory` skill and sits next to its `SKILL.md`: change it in the skill's source (in autofactory, under `.apm/skills/`), then run `apm install`. A repo's own settings live in `settings` in `.eridanilabs/autofactory/board.json` (see [Settings](#settings)).

```text
   request form / gh issue create ──► /factory triage ──► accept ──┐   (duplicate · reject · needs-info)
                                      /factory add #<n> ──────────┤
                                                                   ▼
            feature   or   /factory <issue#>  ◄── Backlog ──► /factory spec <n>: writer-spec, size ──► Ready
                       │                             ▲                    (over the limit ──► needs-human)
                       │                /factory add <feature text>
                       ▼
                  writer-spec        opus
                       │
                       ▼
                  builder-app        opus   ◄──────────────────────┐   ◄── /factory <issue#> on Ready: overlap 2, stale
                       │                                           │
                       ▼                                           │
            board.mjs reviewers: pick by changed paths             │
     ┌───────────┬─────┴─────┬───────────┬────────────┐            │
     ▼           ▼           ▼           ▼            ▼            │
 reviewer-   reviewer-   reviewer-   reviewer-    reviewer-        │
   code      security       ops         ux        ui-design        │
  sonnet       opus        opus       sonnet       sonnet          │
 (always)    (always)   (by path)   (by path)    (by path)         │
     └───────────┴─────┬─────┴───────────┴────────────┘            │
                       ▼                                           │
                 WAIT FOR ALL ──── any CHANGES ────────────────────┘
                 selected reviews  resume builder (up to max_rework_rounds, +1 per revise)
                       │           triage first: fold into / group / skip
                       │           this run's blockers → sub-issues; others parked → Backlog
                       │           nits → sub-issues if fixed, else Backlog
                       │
                       ▼ all PASS
                 approver-merge      opus   APPROVE when all reviews pass, unless: tests or an AC fail · `external`
                  ┌────┴─────┐              or no labels · an unrequested dependency, network call or storage access · size
          APPROVE ▼          ▼ ESCALATE     over the limit or missing · a skipped reviewer's area touched (then ESCALATE)
           merge to main   needs-human ◄── /factory stop <n> [--orphaned]  (from Spec · Build · Review · Approve,
                 │ ▲         │   │   │                                    via the factory:stop label)
                 │ └ approve ┘   │   └─ /factory reject <n> "<reason>" ──► PR closed unmerged, sub-issues closed,
                 │               │                                        issue labeled `rejected`, closed not planned
                 │               └─ /factory revise <n> "<instructions>" ──► builder-app (+1 rework round; selected reviews again)
                 │
                 ▼  issue closes (merged, or rejected) → GitHub's project workflow moves the card to Done
               Done  (merged, or closed unmerged when labeled `rejected`)
```

## Settings

A repo's own settings live in the `settings` block of `.eridanilabs/autofactory/board.json`, never in this file, so a repo that installs the factory sets them without editing the skill. `board.mjs init` writes the defaults, and `board.mjs` fills in any key that's missing from them. A repo set up before the move may still have the old `factory/board.json`: for one release, `board.mjs` falls back to it when the new file is missing, and `refresh` prints the `git mv` that moves it.

| Key in `settings` | What it sets |
|-------------------|--------------|
| `max_rework_rounds` | How many times the builder is resumed after review; still CHANGES after that means needs-human. The default is 3. Each `/factory revise` grants one extra rework round, with no limit on how many times it's used: the budget is `max_rework_rounds` plus `board.mjs revisions <n>`, the verified `Needs human → Build` moves in the `factory-log` audit log. Only the orchestrator writes that log, so builder replies (which go into the build records verbatim) never add to the count. `board.mjs budget` reads it. |
| `test_command` | The command `board.mjs merge --pre-check` runs after it rebases. It's split on whitespace and run without a shell, so it can't use quotes, pipes or `&&`. |
| `merge_method` | How a PR merges. `board.mjs merge` doesn't read it yet and always squashes. |
| `done_wait` | Seconds that `move … Done` waits for GitHub's workflow before setting Done itself. `board.mjs` doesn't read it yet and always waits 30 seconds. |
| `size_limit` | The most changed code lines a run may have and still merge without a human. `board.mjs size` counts them (added plus removed lines, leaving out, at any depth, markdown (`*.md`, `*.markdown`, any case), unit tests (a `test/`, `tests/` or `__tests__/` directory, or a `*.test.*`, `*.spec.*` or `*_test.*` file), the lockfiles `package-lock.json`, `npm-shrinkwrap.json`, `yarn.lock`, `pnpm-lock.yaml` and `apm.lock.yaml`, and an installed copy whose `.apm/` source also changed) against this setting in the base's `board.json`, never the branch's, and approver-merge escalates when the count is over this or missing, or when `size` reports a binary file outside those paths or a changed `.gitattributes`. Its unit is code lines. Known limitation: logic placed in a test path and imported from code outside the test paths counts only as the import line, so reviewers reading the full diff are the guard against it. Triage and groom also hold each card's *estimate* to this limit before it's built: `board.mjs size <n> --est <lines>` scores it and labels it `needs-split` when it's over ([Intake and triage](#intake-and-triage)). Spec is the backstop: writer-spec estimates the spec's size, the orchestrator records it with the same command, and a score over the limit stops the run in Needs human at Spec with a proposed split, unless the run was started with `--force`. |

These stay in this file, with the models in [Stages](#stages):

| Setting | Value |
|---------|-------|
| `commit_style` | [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/) with a `Refs: #<issue>` footer (see `AGENTS.md`, if the repo has one) |

## Stages

| # | Stage | Agent(s) | Model | Board status | Orchestrator writes |
|---|-------|----------|-------|--------------|---------------------|
| 1 | Spec | `writer-spec` | `claude-opus-5.5` | Spec | `spec.md` |
| 2 | Build | `builder-app` | `claude-opus-5.5` | Build | `build-<round>.md` |
| 3 | Review (the selected reviewers, in parallel; see [Reviewer selection](#reviewer-selection)) | `reviewer-security` | `claude-opus-5.5` | Review | `review-<round>-security.md` |
| | | `reviewer-ops` | `claude-opus-5.5` | | `review-<round>-ops.md` |
| | | `reviewer-ux` | `claude-sonnet-5.5` | | `review-<round>-ux.md` |
| | | `reviewer-ui-design` | `claude-sonnet-5.5` | | `review-<round>-ui-design.md` |
| | | `reviewer-code` | `claude-sonnet-5.5` | | `review-<round>-code.md` |
| 4 | Approve | `approver-merge` | `claude-opus-5.5` | Approve | `approval.md` |
| 5 | Merge | orchestrator | n/a | Done | `size.json` |
| n/a | Escalated | orchestrator | n/a | Needs human | `needs-human.md` and `size.json`; `/factory revise` adds `revision-<round>.md` with the human's instructions |
| n/a | Rejected | orchestrator | n/a | Done (labeled `rejected`) | `rejection.md` |
| n/a | Parked | orchestrator | n/a | Backlog | issue from `finding --as backlog`, from `/factory add <feature text>` (files a feature to Backlog without starting the loop), or accepted by `/factory triage` / `/factory add #<n>` |
| n/a | Untriaged | maintainer + orchestrator | n/a | off the board | a triage comment (`🏭 Triage: <decision>`) and a `triage` log entry |

All records go on the `factory-log` branch, in `runs/<issue>-<slug>/`, through `board.mjs record`, never on `main` or the run's branch. Each is written once; a run that escalates again or is approved again gets a numbered copy (`needs-human.2.md`). The orchestrator and agents read them from `.eridanilabs/autofactory/runs/<issue>-<slug>/`, a git-ignored copy that `board.mjs records` refreshes.

## Intake and triage

Anyone, a person or an agent in another repo, can ask for a feature by opening an issue with the **Factory request** form (`.github/ISSUE_TEMPLATE/factory-request.yml`) or `gh issue create --label needs-triage`. The repo's `CONTRIBUTING.md` says how. Those issues stay **off the board** until a maintainer triages them; there is no Triage column.

- `/factory triage` runs `board.mjs intake`, which lists every open issue that is off the board and isn't a review finding (`needs-triage` or not, since outside filers often can't label; `needs-info` ones stay listed). The orchestrator proposes one decision per issue, and **a human confirms each one**. There is no auto-accept.
- `board.mjs triage <n> <decision>` records it: `accept` (restated, then moved to Backlog), `duplicate --into <x>` or `reject` (closed as not planned), or `needs-info` (a question for the filer; the issue stays listed).
- `/factory add #<n>` is a one-issue triage that accepts.
- **Every accepted or groomed card is sized.** The orchestrator estimates the code lines its change will touch and lists the behaviours it asks for in a notes file (one `- ` line each), then runs `board.mjs size <n> --est <lines> --notes-file <f>`. The score is `est + 25 × max(0, behaviours − 4)`, since a card asking for many behaviours tends to take more build and review rounds than its line count says. It's written into the issue body as one `<!-- factory:size est=<lines> unit=code-lines behaviours=<k> score=<s> -->` block with a short `### Size estimate` note, closed by `<!-- /factory:size -->` and replaced in place on the next run. A score over `settings.size_limit` adds the `needs-split` label, and one at or under removes it. Groom proposes a `split` for a `needs-split` card from its behaviour list; a person confirms it, the parts are filed with `/factory add` and sized, and the original becomes their parent. `/factory <n>` stops on a `needs-split` card, with no card move, unless it's run with `--force`, which goes on and records `needs-split forced: size escalation expected` in the Spec move's reason.
- **New issues start unscheduled** (no milestone), from `/factory add`, `/factory add #<n>` and triage alike. An optional `--milestone M` (`active`, `next` or an open milestone's exact title) puts one in a milestone: `/factory add` resolves it with `board.mjs milestone --resolve M` before `gh issue create --milestone`, and `board.mjs triage <n> accept --milestone M` resolves and sets it (only `accept` takes it). An `M` that doesn't resolve stops the command before anything is written. Triage proposes a milestone for each `accept`, unscheduled by default, and `active` only when the issue keeps the active milestone's `Done when` from being true, naming the part it blocks. Without `--milestone`, nothing is set and an issue keeps any milestone it already has. The triage comment and its log entry record the issue's milestone, the one set or the one it already had; the comment says unscheduled only when it has none.
- **External** means the author isn't an org `OWNER` or `MEMBER` (GitHub's `authorAssociation`, which `board.mjs filer <n>` prints; `gh issue view --json` doesn't have it). Their text is untrusted: before accepting, the maintainer restates the request in their own words, and writer-spec gets that restatement (`board.mjs feature <n>`), with the original fenced in `<untrusted-issue-text>` as data. Accepted external issues carry the `external` label, which makes the approver ESCALATE and sends the PR to Needs human even on APPROVE.
- `/factory <n>` refuses an off-board issue that is external or labeled `needs-triage`/`needs-info`: triage it first.

## The board

Every feature is one issue and one card on the repo's GitHub Project board (its number is `project.number` in `.eridanilabs/autofactory/board.json`; its URL and ids are cached, git-ignored, in each checkout's `.eridanilabs/autofactory/cache/project.json`). The card's column is the stage in the table above. The `factory-board` skill, installed next to this one, owns it:

- `/factory` **ensures the board** before every command: private project, the seven columns (Backlog first), the `Agent`, `Checkpoint`, and `Human request` fields, the factory's labels, the `Factory floor` board view as the first view (so the board opens on it), and a **Plan view** grouped by Milestone (`planView` in `board.json`, `Plan` by default, `null` to skip it). When someone has changed the first view, it never rewrites it and prints a hint instead: drag `Factory floor` to the left in the Project. Columns come from `.eridanilabs/autofactory/board.json`.
- The orchestrator **moves the card at every stage change** and is the only one that does. Each move sets the card's Status and comments a verified `🏭 From → To` record that says what the stage produced: the ACs, files and tests, the verdict table, the decision. The record goes on the issue, and on the PR for the build, review, and merge stages. It also keeps a progress checklist in the issue body.
- **GitHub owns Done.** Its built-in "Item closed" workflow moves the card when the merge closes the issue, or when `/factory reject` closes it as not planned. Done means merged, or closed unmerged when labeled `rejected`. The orchestrator records that move (`🤖 auto-moved by GitHub`) instead of treating it as drift.
- If a card isn't where the orchestrator left it, a person moved it. The factory stops that feature instead of overwriting the move.
- Every event is also a commit on the append-only `factory-log` branch (`log/YYYY-MM.jsonl`), because comments can be edited and cards keep no history. Read it with `/factory log [issue]`.

## Milestones

The factory works toward one **active** milestone, with one **next** one queued behind it. They're read from the repo's open milestones (closed ones are ignored):

- A milestone's description holds one fenced JSON block with the info string `factory-milestone`, anywhere in it: `{ "schemaVersion": 1, "status": "active", "doneWhen": "<text>" }`. `schemaVersion` must be `1`; `status` is `active`, `next` or `planned`; `doneWhen` says when it's finished, and only an active milestone needs it. No other key is allowed.
- Every mistake in the block is an error that names the milestone: JSON that doesn't parse, isn't an object or has no closing fence; a missing `schemaVersion` or one that isn't `1`; a `status` that isn't one of the three; an unknown key; an active block with no `doneWhen` or an empty one; more than one block in the description. A broken block never just drops the milestone out.
- **Legacy fallback:** a description with no block is still read from the deprecated lines: a line that is exactly `Status: active` or `Status: next` (whitespace around it doesn't matter), and a `Done when: <text>` line. `board.mjs milestone` then warns `⚠️ milestone "<title>" uses deprecated Status:/Done when: lines; use a factory-milestone block`. When a description has both, the block wins and the lines are ignored. A description with neither has no status.
- It's also an error when more than one open milestone is active, more than one is next, or a legacy active one has no `Done when:` line. Each error names the milestones involved.
- `board.mjs milestone` prints both, with their issue counts and Backlog cards, and the count of unscheduled Backlog cards; an error makes it (and `--json`) exit 1, listing every error. `board.mjs status` shows the active milestone's progress above the table, or one `✗ <error>` line per error (still exit 0). `board.mjs groom` exits 1 with every error. With no active milestone nothing else changes. `board.mjs milestone --resolve M` and `board.mjs triage <n> accept --milestone M` read them too, to schedule a new issue (see [Intake and triage](#intake-and-triage)).
- A person always writes a milestone's `Done when` and edits its `status`. The factory never creates a milestone, and closes, promotes or edits one only through `board.mjs milestone set <number> --status active|next|planned [--done-when "<text>"]` and `board.mjs milestone advance [--next <n>] [--force]`: `milestone set` and `milestone advance` do it when a person asks, with one automatic case: after a merge moves `#<n>` to Done, Merge runs `board.mjs milestone advance --after <n>`, which closes the active milestone and promotes next only when `#<n>` was its last open issue (with no next, it still closes it and warns `⚠ no active milestone`), and otherwise prints one `skip:` line. Otherwise it only asks and proposes. `set` rewrites only the milestone's `factory-milestone` block and refuses two active, two next or an active one with no `doneWhen`; `advance` closes the active milestone (refused while it has open issues, unless `--force`), promotes next to active and makes `<n>` next. Both verify, log a `milestone` entry, and on a partial failure exit 1 and print the `gh api` commands that finish it by hand. The rules: start a milestone from one checkable `Done when` sentence, never a list of issues; ask about a new milestone at close and during groom; keep at most two later milestones (open, and `planned` or with no status); split a milestone whose `Done when` joins two results that could ship separately with "and"; review the unscheduled cards at every close. An epic takes the milestone of its last open sub-issue.
- At close, if no later milestone is a good next, ask the person to write one: never leave an active milestone with no next. Then each `no:milestone` card, epics' unscheduled sub-issues included, joins next or a later milestone, stays unscheduled on purpose, or is closed.
- `board.mjs milestone` warns, still exiting 0, with the legacy `⚠️ milestone "<title>" uses deprecated …` line, `⚠ active milestone "<title>" has no next milestone`, `⚠ <k> later milestones (at most 2): "<t1>", …`, and `⚠ epic #<n> is in the active milestone but #<a> (unscheduled), #<b> (in "<title>") are not`. `milestone --json` gives the same texts in `warnings`. Show them to the person; don't act on them.
- `/factory <n>` starts with `board.mjs milestone --issue <n>`: when an active milestone exists and `#<n>` isn't in it, it prints `⚠ #<n> is outside the active milestone "<active>" (in "<other>" | unscheduled); running anyway`, and the run goes ahead. It prints nothing when there's no active milestone or `#<n>` is in it, and `✗ <error>` (still exit 0) when the milestones can't be read.
- A review sub-issue (`finding --as sub`) gets its parent issue's milestone, and `move --pr <p>` gives the run's PR the issue's milestone, so a milestone's merged PRs can be listed for its release notes. A parent or issue with no milestone sets none, and `--into` and `--as backlog` change no milestone (the Polish issue is created in the active one).

## Reviewer selection

Each round, `board.mjs reviewers` picks the reviewers the change needs from the paths in `git diff origin/main...HEAD`, using the `reviewers` rules in `.eridanilabs/autofactory/board.json`. The rules come from `git show <base>:.eridanilabs/autofactory/board.json` (the base's copy, never the branch's, so a branch can't switch off its own reviewers); it falls back to `<base>:factory/board.json` when the base has only the old path. `reviewer-code` and `reviewer-security` always run, whatever the rules say, and `reviewer-ops`, `reviewer-ux` and `reviewer-ui-design` run when a changed path matches their globs. It fails safe: a path no rule matches, a failed diff, an empty diff, or a change to `.eridanilabs/autofactory/board.json` (or the old `factory/board.json`) or anything under `.apm/skills/factory-board/`, `.agents/skills/factory-board/` or `.github/skills/factory-board/` selects every reviewer. If the base has no valid `reviewers` list, every reviewer in the branch's list runs. A spec line `Reviewers: +ux` adds a reviewer but can't remove one, and, without `--since`, a reviewer that ran in an earlier round always runs again, so its blockers are checked. From round 2, `reviewers --since <last-reviewed-sha>` matches the rules only against the delta: a reviewer that ran before is kept only when the delta touches its domain or its latest record on the log branch has an open `[blocker]`, the fail-safes still select everyone, and a sha that isn't an ancestor of `HEAD` falls back to the full diff. Edit the rules in `board.json`; no code change is needed, and the edit applies once it merges. Skipped reviewers show as `⏭ skipped` in the verdict table, with the reason.

## Rules

1. Each feature runs on branch `factory/<issue>-<slug>`, in **its own git worktree**, cut from a freshly fetched `origin/main`: every run, never the primary checkout or `main`, so two runs never share a checkout. Runs are **serial by default**. A new run may start while others are in flight, running in parallel, only under the **minimal overlap** rule in [Parallel runs](#parallel-runs).
2. The selected reviewers start together and the orchestrator waits for **all selected** results before deciding.
3. Any `CHANGES` sends every blocker finding from every reviewer back to the **same** builder (resumed, not respawned). Then the selected reviewers run again: the selection is rerun on the full diff, and every reviewer that already ran is kept. From round 2 the review scope is the delta, `<last-reviewed-sha>..HEAD`, with the full diff for context. `<last-reviewed-sha>` is the checkpoint of round `r-1`'s `→ Review` move, read from the audit log before this round's own move. The scope falls back to the full diff `origin/main...HEAD` when that sha isn't an ancestor of `HEAD` or can't be found. Reviewers also get the triage history (every earlier `triage-*.md` and `revise-triage-*.md`), so they don't raise a triaged finding again.
4. If reviews still contain `CHANGES` once the rework budget is used up, go to needs-human. The budget is `max_rework_rounds` (3 by default) plus one per `/factory revise`.
5. All `PASS` goes to the approver. A `CHANGES` review counts as `PASS` only when its verdict parsed as `CHANGES`, it listed at least one `[blocker]`, and every one was triaged `park`; a missing or unreadable verdict, or a `CHANGES` with no parked blocker, stays `CHANGES`. A blocker triage downgraded to a nit counts like a parked one, and a `PASS` review with a nit triage upgraded to a blocker counts as `CHANGES`. The approver approves unless one of its listed conditions holds (see approver-merge). `APPROVE` merges: running `/factory <feature>` is your merge authorization for that run. `ESCALATE` goes to needs-human. An issue labeled `external` goes to needs-human even on `APPROVE`.
6. Needs-human posts the question on the PR and links it on the card. The human answers with one of three commands, each taking an issue or PR number:
   - `/factory approve <n>` merges on your behalf and moves the card to Done.
   - `/factory revise <n> "<instructions>"` records the instructions as `revision-<round>.md`, moves the card back to Build, and resumes the builder with the instructions. The rework goes through the selected reviews again and grants one extra rework round. Findings that come with a revise (a Copilot or human PR review, or the instructions) are triaged and filed first, once a human confirms the split: related ones become sub-issues the builder fixes, and net-new ones go to Backlog or `needs-triage` (rule 9). All PASS then goes to approver-merge as usual, which may auto-merge; an `external` issue still goes to needs-human.
   - `/factory reject <n> "<reason>"` records `rejection.md`, comments the reason, closes the PR unmerged and deletes its branch, closes the open review sub-issues, labels the issue `rejected`, closes it as not planned, and moves the card to Done.
   `revise` and `reject` without their text stop and ask for it. Used outside Needs human, they say where the card is and stop.
7. A failed merge (a conflict, a failing CI check, or a CI check that never reported) goes to needs-human, never to Done, and so does a PR the merge queue removed (`removed from merge queue: <reason>`) or one still queued when the wait ran out (`merge queue timed out`). When `main` has a merge queue, `merge` waits for the queue to merge the PR; without one, it merges directly, as before.
8. A missing or unreadable verdict counts as `CHANGES`. A missing or unreadable decision counts as `ESCALATE`.
9. **Triage findings before filing them.** Once all selected reviews are in, the orchestrator triages every `[blocker]` and `[nit]` against the open backlog (`board.mjs backlog`) and against the round's other findings, judging severity by [Severity](#severity). Each one gets a decision, `new`, `into #x`, `group`, `polish #x`, `park`, `skip` or `wontfix`, recorded in `triage-<round>.md`. Fold a finding into an existing issue (`finding --into <x>`) or group it with similar findings whenever possible. Create a new issue only as a last resort. No-action nits ("Fix: none required") are `skip`: they stay in the review record and aren't filed. A real nit not worth doing is `wontfix`, with a one-line reason: it isn't filed either, and later rounds' reviewers get it in the triage records and don't raise it again. `[note]` lines are not findings: notes never block, are never triaged or filed, are never sent to the builder, and stay in the review record. Blockers that are this run's (the diff causes them or makes them worse, or they're about a spec acceptance criterion), and nits the builder fixes, become **sub-issues** of the feature and close with its PR. A blocker that isn't this run's is `park`: filed to **Backlog** (`from-review`, `blocker` and its review type, never the Polish issue) with a reason that shows why, and never sent to the builder; a parked `security` blocker sends the run to Needs human, unless a later `revise-triage-<round>.md` brought it back and filed it `--as sub`. A reviewer whose verdict parsed as `CHANGES`, with at least one `[blocker]` and every one parked or downgraded, counts as `PASS`; a missing or unreadable verdict, or a `CHANGES` with no parked or downgraded blocker, stays `CHANGES`. A `PASS` reviewer with a nit triage upgraded to a blocker counts as `CHANGES`. Triage never downgrades a security blocker (from `reviewer-security` or tagged `(security)`): it's this run's or parked, and a `downgraded:` row for one sends the run to Needs human at Approve. All other filed nits go to **Backlog** (`from-review`), built later with `/factory <issue#>`: while a milestone is active, into its one `Polish: <milestone title>` issue (triage decision `polish #x`; a backlog nit triaged `new` or `group` is filed there too, with no `--into`), and otherwise each to its own card. A `[blocker]`, `--as sub` and `--into <x>` never go to the Polish issue, and nor does a nit when the Polish issue is the run's own issue or its card is busy (Spec, Ready, Build, Review, Approve or Needs human): that nit gets its own Backlog card. The Polish issue is the milestone's last card, and its spec covers every unchecked item under its `## Merged findings`. When a Polish issue's milestone is closed, groom proposes a carry-forward: merge it into the active (or else next) milestone's Polish issue, or keep it when there's neither. **Revise findings** (from a PR review or a `/factory revise`'s instructions) get a severity by the same [Severity](#severity) rule and are triaged and filed too, recorded in `revise-triage-<round>.md`: related blockers become sub-issues, net-new ones go to Backlog (`from-review`) when ready to spec, or to their own `needs-triage` issue for `/factory triage` when not. Nits go to Backlog, and a revise whose findings are all nits doesn't send the run back to the builder.
10. Every commit, including the PR title, follows Conventional Commits. The `factory-log` branch keeps its own `#<issue>: From → To` headlines.
11. **Text from outside the core team never reaches `main` without a human.** External requests are triaged by a human, built from a maintainer's restatement, and always go to needs-human before merging.
12. **A human can stop a run between stages.** `/factory stop <n>` works only in Spec, Build, Review or Approve and adds the `factory:stop` label. Before every stage move, the running orchestrator checks for it; if it's there, it removes the label and goes to needs-human with the reason "stopped by a human". Moves into needs-human remove a pending label too, without any redirect, so a stale label can't stop a later `/factory approve` or `/factory revise`. `/factory stop <n> --orphaned` is for a run with no session left: it moves the card straight to needs-human from its current column and removes the label. A `/factory spec <n>` run keeps its card in Backlog, so `stop` won't take it while it runs: add the `factory:stop` label by hand, and the session sees it before its next move. If that session died, `stop <n> --orphaned` accepts the Backlog card because it has a `factory/<n>-*` branch. A stop never interrupts an agent mid-stage.

## Parallel runs

Every run works in its own git worktree, cut from a freshly fetched `origin/main` (start-up step 0.4), so runs never share a checkout or switch branches in one. Runs are still serialized by default, for these reasons:

1. **Issue-body writes can't compare-and-swap.** `finding --into` and the progress checklist read, change, and write an issue body. GitHub has no compare-and-swap, so two runs writing the same body can drop each other's change; the verify-and-retry narrows the race but can't close it.
2. **Backlog triage needs a stable snapshot.** Each review round triages its findings against `board.mjs backlog`. Another run filing or folding findings at the same time changes that list under it.
3. **Reviews and approvals go stale when `main` moves.** They judge `git diff origin/main...HEAD`. Once another run merges, the diff that was reviewed is no longer the one that would merge.
4. **Some runs change the loop's own rules.** A run that edits `.eridanilabs/autofactory/`, the old `factory/board.json`, `.github/skills/`, `.github/agents/`, `.agents/` or `.apm/` changes how every other run behaves while it's still going.

A run is **in flight** when its card is in Spec, Build, Review or Approve. Cards in Needs human, Backlog, Ready or Done are not in flight. A Ready card has a spec written ahead by `/factory spec <n>` but nothing built, so it never blocks another run's overlap check. When `/factory <n>` picks it up, it runs overlap check 2 against the runs in flight at that moment, then `board.mjs stale <n>` (a Likely file changed on `main` since the spec stops it, unless `--force`), before it moves the card `Ready → Build`.

A new run may start while others are in flight only under **minimal overlap**, which needs both of these to be true:

- **No shared files.** The new run's expected files (its `spec.md` `## Likely files`) share no path with any in-flight run's changed files. An in-flight run's changed files are `git diff --name-only origin/main...<branch>` plus the Likely files in that run's spec.
- **No protected paths.** Neither run touches a protected path: `.eridanilabs/autofactory/`, `factory/board.json` (the old config path), `.github/skills/`, `.github/agents/`, `.agents/`, or `.apm/`. Run records live on `factory-log`, so they never show up in a run's diff.

The orchestrator checks this by hand with `git` and `board.mjs status`: once before Spec (any in-flight run on a protected path blocks, and so does an in-flight run with no branch or no `spec.md` yet, since its files can't be known), and once after `spec.md` is saved and before Build (any file overlap, or the new spec on a protected path, blocks). `/factory revise` reruns both checks before it sends a run back to Build. A block names the blocking run `#<m>` and the shared paths. Every run, parallel or not, works in its own git worktree. A parallel run never takes `finding --into` an in-flight run's feature issue or its sub-issues, and rebases onto `origin/main` and reruns `test_command` right before it merges. When `main` has a merge queue, GitHub also tests each queued PR on top of the PRs queued ahead of it, so two parallel runs that each pass alone can't break `main` together: `merge` waits for the queue, and a PR the queue removes (`removed from merge queue: <reason>`) or still holds after 60 minutes (`merge queue timed out`) goes to needs-human, never to Done.

## Severity

This is the one rule for `[blocker]` versus `[nit]`. Every reviewer, triage, the approver and a person judging a Copilot or human finding in `/factory revise` use it, and nothing else restates it.

A **`[blocker]`** is a change that can't merge as it is, for one of these reasons. The reason is the finding's rule tag:

- `ac`: an acceptance criterion isn't met, or no test fails without the change.
- `test`: a test fails.
- `regression`: the diff breaks a flow it touches.
- `security`: the diff adds a security risk.
- `contract`: CLI flags, exit codes, file formats or docs break, and the spec doesn't say so.

A **`[nit]`** is anything else worth fixing, plus any problem that was already on `origin/main` before this branch, whatever its kind. Its rule tag is `main` when the problem was already on `origin/main`, and `polish` otherwise.

Each finding line names its rule right after the severity, so anyone can check the call: `- [blocker] (regression) path:line: …`. Each reviewer gives **at most 3 nits**, highest value first. A review with no findings is normal.

A `[blocker]` takes only `ac`, `test`, `regression`, `security` or `contract`; one tagged `main`, `polish` or anything else isn't a valid blocker. Triage may downgrade a `[blocker]` to a `[nit]` when its stated rule doesn't hold, or it names none, and records why, but never a security blocker (one from `reviewer-security` or tagged `security`). It never upgrades a nit without a recorded reason.

## Output contracts

Reviewers end with this shape (the first line is parsed):

```text
VERDICT: PASS | CHANGES
## Findings
- [blocker] (rule) path:line: problem. Fix: suggestion.
- [nit] (rule) path:line: problem. Fix: suggestion.
- [note] path:line: observation.
## Coverage
- Files read, flows walked, and commands run.
```

`(rule)` is the [Severity](#severity) rule the finding meets, for example `- [blocker] (regression) path:line: …`. Only `[blocker]` findings justify `CHANGES`. Nits never block. A `[note]` is an observation that needs no action: notes never block, are never triaged or filed, and stay in the review record. `## Coverage` shows what the reviewer checked, so a thin review is visible.

The approver ends with:

```text
DECISION: APPROVE | ESCALATE
Reason: one or two sentences.
Escalation: none | <list>
```

The `Escalation:` list is comma-separated and uses only `size`, `protected-path`, `human-call` and `other`; a missing line or an unknown word counts as `other`.

## Size records

Each time a run reaches Merge or Needs human, the orchestrator runs `board.mjs size-record`, which writes `size.json` to the run's records (`size.2.json` and so on for a repeat): the card's size estimate and score, the run's changed code lines, the limit, the build and revise counts, and why it escalated. On Merge it runs after APPROVE and before `board.mjs merge`, with `--escalation none`. On every move to Needs human it runs with the approver's `Escalation:` line if there is one; a Spec-stage size stop uses `size`, and any other escalation uses `other`. The count is `null`, not 0, when nothing is built yet (no `build-*` record, or `HEAD` still at the merge-base) or the checkout isn't on the run's branch, so a Spec-stage stop doesn't skew the report. `board.mjs size-report` reads every `size.json` and shows how well estimates and scores predicted "over the limit".

When approver-merge escalates on size alone (the latest size record has `needs-human`, escalation exactly `size` and at least one build, and was written after the last revise, so a failed `size-record` write after a revise doesn't count), `board.mjs size-trend <issue>-<slug>` shows the run's counts oldest first, whether a human already accepted the size at Spec, and how many lines a revise added. The Needs human comment then recommends `/factory approve <n>` or `/factory revise <n> split`, which can split a run that has a PR: it files the parts, closes the PR unmerged and moves the card to Backlog. A revise with instructions can't fix a size escalation.
