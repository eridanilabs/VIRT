# Needs human: #59

**Reason:** approver-merge escalated on size: 750 changed code lines, limit 400 (the spec estimated 330).

**Evidence:**
- `node $P size` (pinned board.mjs, f18f9e9): `750 changed code lines, limit 400: over the limit`.
- Most of the gap is tests. `board.mjs` counts Swift test files as code: VIRTTests/SessionAlertPresenterTests.swift (+336) and Packages/VIRTKit/Tests/VIRTKitTests/SessionAlertTests.swift (+64) together add 400 of the 750 lines. App and VIRTKit code is about 350 lines.
- Nothing else blocks it: tests pass, AC1–AC5 are met, and all four selected reviewers passed in round 2 (code, security, ux, ui-design; ops was skipped). No blocker was parked or downgraded.
- approval.md: approver-merge's decision, `Escalation: size`.

**Next step:** `/factory approve 59` to merge at this size; `/factory revise 59 "<instructions>"` (it can't fix size, since approver-merge escalates on size again); `/factory reject 59 "<reason>"`. The spec has no proposed split.
