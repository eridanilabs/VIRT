# Needs human: size only

**Reason:** approver-merge escalated on size only. 498 changed code lines, limit 400; the spec estimated 160.

**Evidence:**
- Base `board.mjs size` on `origin/main...HEAD`: `498 changed code lines, limit 400: over the limit`.
- `size-trend`: sizeOnly true, latest 498, estimate 160 (4 behaviours), no carry-on, no revise growth.
- Of the 498 lines, 291 are Swift tests (`VIRTTests/HostsViewModelTests.swift` +271/−9, `HostConnectorTests.swift` +11). `board.mjs` counts these as code because it only excludes `test/`, `tests/`, `__tests__/` and `*.test.*`-style paths. The app and package code is 207 lines: HostsViewModel.swift +117/−9, HostsView.swift +47/−7, HostConnector.swift +12/−1, VIRTApp.swift +10/−4.
- Everything else is clean:
  - All 4 selected reviewers passed in round 2.
  - The round 1 blocker #30 is fixed and confirmed.
  - Tests pass: 43 VIRTKit and 58 app.
  - All ACs (AC7 to AC10) are met.
  - No parked blockers.
  - The issue is not external.
- The spec has no `## Proposed split`.

**Next step:** `/factory approve 21` to merge at this size, `/factory revise 21 "<instructions>"` (can't fix a size escalation), or `/factory reject 21 "<reason>"`.
