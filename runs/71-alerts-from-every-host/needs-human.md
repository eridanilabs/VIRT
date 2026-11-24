# Needs human: #71

**Reason:** approver-merge escalated on size: 402 changed code lines, limit 400. The spec estimated 130.

**Evidence:**
- `node $P size` (pinned copy, base 296b067): `402 changed code lines, limit 400: over the limit`.
- App code is 163 lines (VIRT/HostsView.swift 3/0, VIRT/HostsViewModel.swift 22/17, VIRT/SessionAlertPresenter.swift 67/54). The other 239 lines are unit tests in `VIRTTests/` (SessionAlertPresenterTests.swift 180/44, HostsViewModelTests.swift 10/5). `size` counts those as code because they aren't under a `test/` or `tests/` folder and don't match `*.test.*`.
- All four selected reviewers (code, security, ux, ui-design) returned PASS with no blockers or nits. `./scripts/test.sh` passes. approver-merge found AC1–AC6 met in the code, and size is its only reason to escalate.
- AC5 (the sessions screen is re-created when an alert opens another host) is a manual simulator check that no one has run yet.

**Next step:** `/factory approve 71` to merge it at this size (after the AC5 simulator check, if wanted), `/factory revise 71 "<instructions>"` (it can't fix a size escalation), or `/factory reject 71 "<reason>"`.
