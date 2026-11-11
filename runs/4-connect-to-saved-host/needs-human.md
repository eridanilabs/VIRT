# Needs human: #4 at Spec

**Reason:** spec estimate over size limit: score 840, limit 400.

**Evidence:**
- `board.mjs size 4 --est 790 --notes-file …` printed `✓ #4: score 840 (est 790, 6 behaviours), limit 400: over the limit, added needs-split`.
- The spec's `## Size estimate` says `Estimate: 790 code lines` with 6 behaviours (score = 790 + 25 × (6 − 4) = 840).
- The run wasn't started with `--force`.

**Proposed split (from spec.md):**
- Part 1: Connect with the token and check the URL policy again: behaviours 1–2; AC1, AC2, AC6, and the token re-read in AC5; about 230 code lines
- Part 2: Tailnet check before connecting: behaviour 3; AC3; about 190 code lines
- Part 3: Failure reasons and reconnect state: behaviour 4; AC4 and the rest of AC5; about 210 code lines
- Part 4: Hosts screen status and app lifecycle: behaviours 5–6; AC7, AC8, AC9; about 160 code lines

**Next step:**
- `/factory revise 4 split` to file these parts as sub-issues and move #4 to Backlog
- `/factory revise 4 "carry on"` to build it anyway (approver-merge will escalate on size)
- `/factory reject 4 "<reason>"` to close it
