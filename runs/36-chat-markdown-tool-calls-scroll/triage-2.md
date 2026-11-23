# Triage r2 for #36

Round 2: reviewer-code PASS, reviewer-security PASS, reviewer-ux PASS, reviewer-ui-design PASS (reviewer-ops skipped). No blockers.

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] (polish) VIRT/SessionChatView.swift:68: the tool call row's `HStack` centers the `DisclosureChevron`, so when details open, the chevron slides down away from the summary line. Fix: `HStack(alignment: .firstTextBaseline)` | reviewer-ui-design | polish #13 | #13 | Nothing open covers it outside this PR. #50 (the same row) closes with this PR, so it can't take a backlog nit. |
| [nit] (polish) VIRT/SessionChatViewModel.swift:53-59: a slow drag up from the bottom doesn't turn following off until it leaves the 24 pt margin, so streamed growth pulls the view back down. Fix: also call `setAtBottom(false)` on `.interacting`, and re-check on `.idle` | reviewer-ux | polish #13 | #13 | Nothing open covers it outside this PR. #49 (AC5 following) closes with this PR, so it can't take a backlog nit. |

`[note]` lines get no triage decision.

**Backlog from review:** both nits are filed `--as backlog` into the active milestone's Polish issue. There are no parked blockers.
