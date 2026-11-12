# Needs human: #35 at Spec

**Reason:** spec estimate over size limit: score 620, limit 400.

**Evidence:**
- writer-spec estimated 620 code lines across 4 behaviours (score 620). The card's earlier triage estimate was 330 (score 330).
- `board.mjs size 35 --est 620` printed `over the limit, added needs-split`.
- The run wasn't started with `--force`.

**Proposed split (from the spec):**
- Part 1: Chat items from chat state: the mapping behaviour, AC1, AC2, about 220 code lines
- Part 2: Live chat subscription in VIRTKit: the subscribe and unsubscribe behaviours, AC3, AC4, plus the `FakeHosts` and `FakeConnector` changes, about 240 code lines
- Part 3: Chat screen: the screen behaviour, AC5, AC6, about 170 code lines

**Next step:**
- `/factory revise 35 split` to file the parts as sub-issues and move #35 to Backlog
- `/factory revise 35 "carry on"` to build it anyway (approver-merge will escalate on size)
- `/factory reject 35 "<reason>"` to close it
