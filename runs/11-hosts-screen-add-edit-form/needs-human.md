# Needs human: #11 (PR #14)

**Reason:** approver-merge escalated on size: 697 changed code lines, limit 400 (spec estimated 280).

**Evidence:**
- The base's `board.mjs size` counts 697 changed code lines in `origin/main...HEAD`, over `settings.size_limit` 400.
- About 310 of those lines are Swift tests (`VIRTTests/HostsViewModelTests.swift` +270, `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift` +40). `size` leaves out only `test/`, `tests/` or `__tests__/` directories and `*.test.*`, `*.spec.*`, `*_test.*` files, so Xcode's `VIRTTests/` and `*Tests.swift` names count as code. Non-test code is about 387 lines.
- Tests pass (`./scripts/test.sh`: VIRTKit 21, app 18). AC1–AC8 are met. All four selected reviewers passed with 0 blockers; 7 nits went to Polish #13.
- Escalation: size only.

**Next step:** `/factory approve 11` to merge it at this size, `/factory revise 11 "<instructions>"` (it can't fix a size escalation), or `/factory reject 11 "<reason>"`. The spec has no proposed split.
