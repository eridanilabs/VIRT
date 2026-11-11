`/factory groom`: go through the open Backlog cards with a maintainer, milestone by milestone: merge duplicates, close nits already fixed on `main`, close or split stale cards, schedule cards into a milestone or take them out of one, and mark what to build next. Like [Triage](#triage), this does no run work: no branch, no run records, no agents, and no card moves (but see the carry-forward in step 5). A human confirms every change, and each one is recorded as a comment on the issue and in the audit log. The one exception is sizing (step 2): `size <n> --est` rewrites the card's size block and sets or clears `needs-split` without asking, and it isn't logged.

1. List the cards: `node $B groom`. It shows every open issue whose card is in **Backlog**, **grouped by milestone**, one table per group in this order: the active milestone (with its `Done when`), the next milestone, every other milestone that holds a Backlog card (by title), then `Unscheduled (no milestone)`. Active and next are shown whenever they exist, even empty. Each table lists its cards by number, with their labels, age in days, source (`from-review` with the run it came from, or `request`), and links (parent or sub-issues, `#n` items under `## Merged findings`, `#n` mentions in the body). `node $B groom --json` gives the same as JSON. A milestone error (two active, or an active one with no `Done when`) prints `✗ <error>`: show it and stop, since the maintainer fixes it on GitHub. A milestone's `Polish: <milestone title>` issue, where its parked review nits collect, is its **last card**: it's listed after the group's other cards (first only when it's labelled `security`), it's built after them, and its spec covers every unchecked item under its `## Merged findings`.
2. Check each card against `main`. Read it (`gh issue view <n> --json title,body,comments`), then look at the code it names on a freshly fetched `origin/main` (`git fetch origin`, `git log origin/main -- <path>`, `git show origin/main:<path>`). Note the commit that fixed it, if one did, and any other card that covers the same thing. Then size **every card you review**, as in [Sizing a card](#sizing-a-card): estimate its code lines, list its behaviours in a notes file and run `node $B size <n> --est <lines> --notes-file $N`, so its size block and `needs-split` label are current.
3. **Propose** one decision per card, with its summary text, as a table:

   | Decision | When | Summary file holds |
   |----------|------|--------------------|
   | `keep` | It's still wanted and still open on `main`. | Why it stays. |
   | `merge` | Open card `#x` covers the same thing. | One line for the `## Merged findings` item in `#x`. Pass `--into <x>`. |
   | `close-fixed` | `main` already fixed it. | What fixed it. Pass `--commit <sha>`. |
   | `close-wont-do` | It's stale or no longer fits. | The reason. |
   | `split` | It's too big for one run. **Always propose it for a card labelled `needs-split` that has no sub-issues yet.** A `needs-split` card that already has sub-issues (the links column) was split before: `keep` it. | The parts, drawn from the behaviour list in its size block, each small enough for one run. |
   | `next` | Build it soon. **Only for a card in the active milestone.** | Why now. |
   | `schedule` | It belongs in a milestone. | Why it belongs there. Pass `--milestone <active\|next\|title>`; into the active milestone, also `--swap <x>` or a `Blocks "Done when": <text>` line. |
   | `unschedule` | It no longer belongs in its milestone. | Why it comes out. |

   **Carry-forward.** When a Polish issue's milestone is closed, its group ends with a line like `↪ #x: milestone closed; propose merge into Polish: <target>`, where `<target>` is the active milestone, or else the next one (`↪ #x: milestone closed; propose keep` when there's neither). Propose that decision for `#x` as written (`merge into Polish: <target>`), without a number: don't run anything yet. The target's issue is found, or created, only once the human confirms, in step 5.

   `merge` refuses when `#x` is closed, when `#x` or its parent has a card in Spec, Ready, Build, Review, Approve or Needs human, or when `<n>` is `external` and `#x` isn't; pick another target or `keep` it for now. A Backlog card whose issue has a `factory/<n>-*` branch is mid-spec ([Spec ahead](#spec-ahead)): treat it as busy too, and don't merge into it or close or split it until it reaches Ready or Needs human.

   **The active milestone's scope doesn't grow for free.** A `schedule` into the active milestone, named `active` or by its title, needs one of two things: a **swap**, `--swap <x>`, where `#x` is another open card in the active milestone with its card in Backlog, which is unscheduled to make room; or a summary line `Blocks "Done when": <text>` that says which part of the active milestone's `Done when` the card keeps from being true. Propose a swap first. `--swap` is refused for any other target.

   **`next` is only for the active milestone's cards.** For a card anywhere else, propose `schedule --milestone active` first; `next` on it is refused with the hint `schedule it first: groom <n> schedule --milestone active`. `unschedule`, and a `schedule` into any milestone that isn't active, remove the card's `next` label.
4. **A human confirms each decision**, one card at a time, before you act on it. Never groom without a yes; there is no auto-groom. If the human changes a decision or its text, use theirs. The order in which the human confirms `next` decisions is the build order.
5. Record each confirmed decision:

   ```bash
   S=$(mktemp "$W/summary.XXXXXX")    # the summary; never commit it
   node $B groom <n> <keep|merge|close-fixed|close-wont-do|split|next> [--into <x>] [--commit <sha>] --summary-file $S
   node $B groom <n> schedule --milestone <active|next|title> [--swap <x>] --summary-file $S
   node $B groom <n> unschedule --summary-file $S
   ```

   For a confirmed carry-forward `merge into Polish: <target>`, first run `node $B polish --milestone <target>` (`active`, `next` or the title): it prints `= #y` for the target's open Polish issue, or creates it (`+ #y created (polish)`, its card in Backlog) when there isn't one yet. Then run `node $B groom <x> merge --into <y> --summary-file $S`. This is the one card move groom makes, and only after a yes.

   For a confirmed `split`, once `groom <n> split` has commented: file each part with [`/factory add`](#add) (with the same milestone, if `<n>` has one), size each part as in [Sizing a card](#sizing-a-card), and make `<n>` their parent with `gh api -X POST repos/<repo>/issues/<n>/sub_issues -F sub_issue_id=<id>`, where `<id>` is `gh api repos/<repo>/issues/<part> -q .id`. If a link fails, stop and report the `gh` error with the part's number; it's safe to rerun once the cause is fixed: the parts are already filed and sized, so rerun only the links that failed. `<n>` stays open as the parent; it keeps `needs-split`, so it's never built itself. Once every part is closed, propose `close-fixed` for `<n>`, with the merge commit of the last part.

   It comments `🏭 Groom: <decision>` on `<n>`. `merge` first adds `- [ ] **#<n>** <summary>` under `## Merged findings` in `#x` (carrying `<n>`'s finding fingerprints, and, when they carry over, adding the `from-review` label and `<n>`'s severity and review-type labels to `#x`, blocker winning; never `<n>`'s title) and comments on `#x`. `next` adds the `next` label. `close-fixed` closes as completed, `close-wont-do` and `merge` close as not planned, and all three remove `next`. `keep` and `split` only comment. `schedule` sets `<n>`'s milestone and `unschedule` clears it; their comment names the milestone (and the swap), and with `--swap <x>`, `#x` is unscheduled first and gets its own `🏭 Groom: unschedule` comment naming `#<n>`. Every check runs before any write, so a refused `schedule`, `unschedule` or `next` changes nothing. Each call logs one `groom` entry (`#12: groom schedule into milestone v1 (swap #9)`, `#12: groom unschedule`); a milestone that fails to set or clear makes the entry unverified and exits 1. With `--swap`, a write that fails after `#x` is unscheduled stops the rest, and the entry's problem gives the `gh issue edit` to finish by hand, since rerunning the swap is refused.
6. Print a summary, then stop:
   - **Closed:** each closed card with its reason (`close-fixed` with the commit, `close-wont-do`).
   - **Merged:** each `#<n> → #<x>`.
   - **Scheduled:** each `#<n> → <milestone>`, with its swap (`swap #<x>`) or its `Blocks "Done when"` line when it went into the active milestone.
   - **Unscheduled:** each `#<n>` taken out of its milestone, swaps included.
   - **Split:** each `#<n>` with its parts and their size scores.
   - **Next:** the `next` cards in the order they were confirmed, each with its command, `/factory <n>`.
   - **Proposed milestones** (last): groups of unscheduled cards that point at the same unmet result, each with a draft `Done when:` sentence and its card numbers. These are proposals only, for a person to confirm: never create a milestone, set its `Status:`, or schedule the cards into it. A person creates it on GitHub, then the cards are scheduled with `schedule` at the next groom. Say `none` when no group stands out.
