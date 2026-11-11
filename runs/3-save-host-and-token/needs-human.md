# Needs human: #3 at Spec

**Reason:** spec estimate over size limit: score 580, limit 400.

**Evidence:** writer-spec estimated 480 code lines with 8 behaviours (`board.mjs size 3 --est 480`: score 580 = 480 + 25 × (8 − 4), limit 400; `needs-split` added). The run was not started with `--force`.

**Proposed split (from spec.md):**
- Part 1: Hosts model, URL policy and secure storage: the URL policy, carrier-grade NAT warning, Keychain storage, persistence, delete removing the token, and ATS with AGENTS.md (AC3–AC7), about 260 code lines
- Part 2: Hosts screen and form: the Hosts screen with its empty state, and the add and edit form with the masked token (AC1–AC2), about 220 code lines

**Next step:** `/factory revise 3 split` to file the parts as sub-issues and move #3 to Backlog, `/factory revise 3 "carry on"` to build it anyway (approver-merge will escalate on size), or `/factory reject 3 "<reason>"` to close it.
