# Needs human: #37 at Approve

**Reason:** approver-merge escalated on size: 438 changed code lines, limit 400.

**Evidence:**
- The base's `board.mjs size` counted `438 changed code lines, limit 400: over the limit`.
- The spec estimate scored 435, and a human ran `/factory revise 37 "carry on"` at the Spec size stop.
- reviewer-code and reviewer-security both PASS. `scripts/test.sh` passes, and all six ACs are met. approver-merge gave no other reason.
- PR #39 @ 94ca691.

**Next step:**
- `/factory approve 37` merges it at this size.
- `/factory revise 37 split` files the spec's proposed parts as sub-issues, closes PR #39 unmerged and moves #37 to Backlog.
- `/factory revise 37 "<instructions>"` sends it back to the builder. That can't fix a size escalation.
- `/factory reject 37 "<reason>"` closes it unmerged.
