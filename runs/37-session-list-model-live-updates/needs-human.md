# Needs human: #37 at Spec

**Reason:** spec estimate over size limit: score 435, limit 400.

**Evidence:**
- `board.mjs size 37 --est 410`: `score 435 (est 410, 5 behaviours), limit 400: over the limit, added needs-split; was score 330 (est 330)`.
- The spec ([spec.md](https://github.com/eridanilabs/VIRT/blob/9e9200a0bab9ba3a47f975ff5fb8a0639a51a332/runs/37-session-list-model-live-updates/spec.md)) estimates 410 code lines for 5 behaviours. Triage had estimated 330 for 4 behaviours. The spec's estimate counts the new Swift test files, which the size counter treats as code lines.
- The run wasn't started with `--force`.

**Proposed split (from the spec):**
- Part 1: Session row model: state and folder mapping, sort and guppi titles (AC1–AC3), about 180 code lines
- Part 2: Live session updates and refresh on `HostConnecting`: `sessionUpdates` and `refreshSessions` (AC4–AC6), about 230 code lines

**Next step:**
- `/factory revise 37 split` to file the two parts as sub-issues and move #37 to Backlog
- `/factory revise 37 "carry on"` to build it anyway (approver-merge will escalate on size)
- `/factory reject 37 "<reason>"` to close it
