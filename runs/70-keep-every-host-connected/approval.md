# Approval: approver-merge (claude-opus-5.5)

DECISION: APPROVE
Reason: The tests pass, all six acceptance criteria are met, and none of the escalate conditions applies. The size is 365 changed code lines against a limit of 400.
Escalation: none

- **Tests:** there's no `package.json`, so I ran the repo's test command, `./scripts/test.sh`, instead of `npm test`. It exited 0: 84 VIRTKit tests passed, and the app tests passed on the iOS simulator, including `SessionAlertPresenterTests` with no changes. Nothing failed.
- **Acceptance criteria:** I checked each one against `VIRT/HostsViewModel.swift` and the new tests.
  - **AC1:** `load()` returns early when it fails, then connects every saved host it hasn't connected yet. A host that failed stays failed on a later load, which the spec's Assumptions ask for. A successful `delete` disconnects the host; a failed delete makes no call.
  - **AC2:** each host now has its own status and its own status task, so one host's status doesn't change another's row.
  - **AC3:** `select` sets `selectedHostID` and points alerts at that host. It connects only an idle or failed host, and it never disconnects anything.
  - **AC4:** going to the background disconnects every host the model connected. `.active` only does something after a background, and then it connects every host, failed ones included. A load or tap while in the background connects nothing.
  - **AC5:** a test checks that no token is read (`tokens.reads == 0`).
  - **AC6:** the README's "Connecting to a host" section describes all four behaviours the spec lists.
- **Reviewers:** all four selected reviewers passed (code, security, ux, ui-design), with no blockers and no parked security items. The one `[nit]` was filed to Polish #68. Skipping reviewer-ops was right: the diff touches only `README.md`, two files in `VIRT/` and one test file, with no scripts, agents, workflows or Xcode project changes.
- **Other checks:**
  - The issue's only label is `factory`, so it isn't external.
  - The diff adds no dependency or new storage access. The extra connections it opens are the behaviour the spec asks for.
  - No schema version constant changed, and `origin/main` has no `docs/board-reads.md`, so the `Consumers:` rule can't apply.

Merge still waits for the CI `test` check to pass.
