DECISION: ESCALATE
Reason: The official `board.mjs size` line reports 754 changed code lines against a limit of 400 (the spec estimated 310). Tests, acceptance criteria and reviews are all clean, so a human only needs to decide whether to accept the size. 354 of those lines are Swift tests under `Packages/VIRTKit/Tests/` (capital T) and in `VIRTTests/ATSTests.swift`, which the counter doesn't exclude. That leaves 400 lines of non-test code, which is within the limit.
Escalation: size

- **Tests:** there's no `package.json`, so `npm test` doesn't apply. I ran the repo's test command, `./scripts/test.sh`, and it exited 0. `swift test` passed 18 tests in 4 suites, and `xcodebuild test` passed 4 app tests on an iPhone 18 Pro simulator, including the 3 `ATSTests`.
- **Acceptance criteria (AC1 to AC8):** all are met. The policy table test, the token-store, host-store and library tests, and the ATS plist test cover AC1 to AC7. I read the AGENTS.md and README changes myself: they cover AC8, including the WireGuard and carrier-grade NAT wording and naming card #10 as the ATS exception card.
- **Nothing else escalates:**
  - The labels are given and don't include `external`.
  - No new dependency: the only imports are Foundation, Security and Synchronization, all system modules.
  - No network calls, file access or logging. The only storage is the Keychain and the injected `UserDefaults`, which the spec asked for.
  - The selection skipped no reviewer, and all five passed.
  - There are no parked or downgraded security blockers. `triage-1.md` has only polish rows for the 5 nits, filed to Polish issue #13.
- **For the human:** if you want this under the limit later, the counter could exclude Swift's `Tests/` directories or names like `*Tests.swift`. That's a change to the base's `board.mjs`, not to this branch.
