# Needs human: #10 at Approve

**Reason:** over the size limit, size only: 754 changed code lines, limit 400.

**Evidence:** approver-merge escalated with `Escalation: size` and nothing else. Its record is `approval.md`. All five reviews passed, the acceptance criteria are met, and `./scripts/test.sh` passes. Of the 754 lines, 354 are Swift tests that the counter doesn't exclude (`Packages/VIRTKit/Tests/…`, `VIRTTests/ATSTests.swift`), so 400 lines are non-test code.

**Next step:**
- `/factory approve 10` merges it at this size.
- `/factory revise 10 "<instructions>"` sends it back to the builder, but that can't fix the size.
- `/factory reject 10 "<reason>"` closes it unmerged.
