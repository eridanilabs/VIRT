# Needs human: #5 List a host's sessions

**Reason:** spec estimate over size limit: score 565, limit 400.

**Evidence:**
- writer-spec estimated 540 code lines across 5 behaviours. That scores 540 + 25 × (5 − 4) = 565, and the limit (`settings.size_limit`) is 400.
- At triage, the estimate was 380 (score 380, within the limit). The spec added the sessions screen's navigation and the pull-to-refresh `listSessions` path as their own behaviours, and counts the Swift tests under `VIRTTests/` and `Packages/VIRTKit/Tests/` as code lines.
- `board.mjs size 5` printed: `score 565 (est 540, 5 behaviours), limit 400: over the limit, added needs-split; was score 380 (est 380)`.
- Spec: `runs/5-list-host-sessions/spec.md` on `factory-log`.

**Proposed split (from the spec):**
- Part 1: Session list model and live updates in VIRTKit: rows, guppi names, live updates and refresh (AC2–AC5, with their VIRTKit tests). About 330 code lines.
- Part 2: Host sessions screen: the screen, its view model, navigation, pull to refresh and the fake connector update (AC1, plus wiring AC4 and AC5 into the UI). About 210 code lines.

**Next step:**
- `/factory revise 5 split` files the two parts as sub-issues and moves #5 to Backlog.
- `/factory revise 5 "carry on"` builds it anyway; approver-merge will escalate on size.
- `/factory reject 5 "<reason>"` closes it.
