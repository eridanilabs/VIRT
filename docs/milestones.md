# Milestones

Work is planned in [milestones](https://github.com/eridanilabs/VIRT/milestones), so related changes ship together. VIRT follows the same rules as [guppi](https://github.com/eridanilabs/guppi/blob/main/docs/milestones.md), because guppi reads them to pick VIRT's next card.

## The rules

1. **A milestone is a result you can ship, not a time box.** Its description has a one-line `Done when:` test. It closes when that test is true.
2. **One active milestone, at most one next.** Everything else is unscheduled. guppi takes cards only from the milestone whose description has `Status: active` (VIRT's [`.eridanilabs/guppi.json`](../.eridanilabs/guppi.json) sets `"milestone": "@active"`).
3. **New issues start unscheduled.** An issue joins the active milestone only if the milestone's `Done when` test can't be true without it.
4. **Nits don't get their own issues.** Each milestone has one `Polish: <milestone>` issue, holding review nits as a checklist.
5. **Ship by milestone.** When a milestone closes, tag a release.

## Writing a milestone

Title: `<n>: <the result>`, for example `0: Connect to an AHP host`.

Description: a `Status:` line (`active` or `next`, or none), then the `Done when:` line, then anything else:

```text
Status: active
Done when: VIRT on an iPhone connects to a guppi-managed AHP host over the tailnet, lists its sessions and shows one session's chat live.
```

## Epics

A milestone holds at most one epic, labelled `epic`. guppi never builds an epic; it builds the epic's sub-issues.

- Each sub-issue carries the milestone itself, because GitHub doesn't copy the epic's milestone to its sub-issues.
- The sub-issue order on the epic is the intended build order. Until guppi reads that order, mark the next card with the `next` label.
- An issue waiting on another gets a blocked-by link and the `blocked` label, with the reason in a comment. guppi skips it until a person removes the label.
- Close the epic when its last sub-issue is done.

## Closing a milestone

1. Check the `Done when` test is true.
2. Move what's left to the next milestone or unscheduled, including unchecked Polish items.
3. Close the milestone and tag the release.
4. Change the next milestone's `Status: next` to `Status: active`, and mark a new next. guppi then picks up the new active milestone on its next rescan.
