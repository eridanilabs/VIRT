# Milestones

Work is planned in [milestones](https://github.com/eridanilabs/VIRT/milestones), so related changes ship together. VIRT follows the same rules as [guppi](https://github.com/eridanilabs/guppi/blob/main/docs/milestones.md), because guppi reads them to pick VIRT's next card.

## The rules

1. **A milestone is a result you can ship, not a time box.** Its description has a one-line `Done when:` test. It closes when that test is true.
2. **One active milestone, at most one next.** Everything else is unscheduled or `planned`. guppi takes cards only from the active milestone (VIRT's [`.eridanilabs/guppi.json`](../.eridanilabs/guppi.json) sets `"milestone": "@active"`).
3. **New issues start unscheduled.** An issue joins the active milestone only if the milestone's `Done when` test can't be true without it.
4. **Nits don't get their own issues.** `/factory` files review nits into the active milestone's `Polish` issue as a checklist.
5. **Ship by milestone.** When a milestone closes, tag a release.

## Writing a milestone

Title: `<n>: <the result>`, for example `0: Connect to an AHP host`.

The description holds one fenced JSON block with the info string `factory-milestone`, and anything else around it. `status` is `active`, `next` or `planned`, and an active milestone needs a `doneWhen`, one checkable sentence:

````markdown
```factory-milestone
{ "schemaVersion": 1, "status": "active", "doneWhen": "VIRT on an iPhone connects to a guppi host over the tailnet, lists its sessions and shows one session's chat as it updates." }
```
````

`node .agents/skills/factory-board/board.mjs milestone` shows the active and next milestones and checks their blocks. The older `Status:` and `Done when:` lines still work, with a warning; don't use them. A person writes `doneWhen` and sets `status`, on the milestone page or with `board.mjs milestone set <number> --status active|next|planned`.

## Epics

A milestone holds at most one epic, labelled `epic`. guppi never builds an epic, or any issue labelled `blocked`; it builds the epic's sub-issues.

- Each sub-issue carries the milestone itself, because GitHub doesn't copy the epic's milestone to its sub-issues.
- The sub-issue order on the epic is the intended build order. Until guppi reads that order, mark the next card with the `next` label.
- An issue waiting on another gets a blocked-by link and the `blocked` label, with the reason in a comment. guppi skips it until a person removes the label.
- Close the epic when its last sub-issue is done.

## Closing a milestone

1. Check the `Done when` test is true.
2. Move what's left to the next milestone or unscheduled, including unchecked Polish items.
3. Close it and promote next to active: `node .agents/skills/factory-board/board.mjs milestone advance --next <number>`, where `<number>` is the milestone to mark next. When a merge closes the active milestone's last issue, `/factory` closes it and promotes next itself; then only mark a new next.
4. Tag the release. guppi picks up the new active milestone on its next rescan.
