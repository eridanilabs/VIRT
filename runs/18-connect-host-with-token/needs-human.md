# Needs human: #18

**Reason:** approver-merge escalated on size only. The base's `size` reports 409 changed code lines against a limit of 400.

**Evidence:**
- Base `board.mjs size`: `409 changed code lines, limit 400: over the limit`.
- The spec estimated 300 code lines (score 300).
- About 206 of the 409 lines are Swift tests in `Packages/VIRTKit/Tests/`. They count as code because `size` leaves out only lowercase `test/`, `tests/` and `__tests__/` folders. The non-test code is about 203 lines.
- Every other approver check passes: tests (VIRTKit 26/26, app 18/18), all six ACs, no extra dependencies, no `external` label, no parked security blockers.
- Round 1 reviews (code, security, ops) all PASS with 0 blockers. 2 nits went to the Polish issue #13.

**Next step:** `/factory approve 18` to merge at this size, `/factory revise 18 "<instructions>"` (this can't fix the size), or `/factory reject 18 "<reason>"`.
