# Needs human: over the size limit, size only

**Reason:** approver-merge escalated on size alone. The run is 934 changed code lines against a limit of 400 (counted with origin/main's `board.mjs`); the spec estimated 620.

**Evidence:**
- At the Spec size gate, a human ran `/factory revise 35 "carry on"` to build it in one PR anyway, expecting a size escalation (revision-1.md).
- Round 2: all four selected reviewers passed. Round 1's security blocker #43 and UX nits #44, #45 and #46 are fixed.
- `./scripts/test.sh` exits 0: VIRTKit 70 passed, app 69 passed.
- All six acceptance criteria are met. The approver found no other reason to escalate.

**Next step:** `/factory approve 35` to merge it at this size, `/factory revise 35 split` to file the spec's proposed parts and close PR #42 unmerged, `/factory revise 35 "<instructions>"` (it can't fix a size escalation), or `/factory reject 35 "<reason>"`.
