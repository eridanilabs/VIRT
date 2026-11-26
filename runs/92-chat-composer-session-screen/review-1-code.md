# Review r1: code (claude-sonnet-5.5)
VERDICT: CHANGES
## Findings
- [blocker] (ac) VIRTTests/SessionChatViewModelTests.swift:65: AC1 has no test for the composer appearing above the bottom navigation or remaining available with the keyboard visible; this test only checks that the model stores a multiline draft. Fix: add a view-level test that verifies the composer’s placement and keyboard-visible behavior.
## Coverage
- Files read: AGENTS.md, README.md, .eridanilabs/autofactory/runs/92-chat-composer-session-screen/spec.md, .agents/skills/factory/LOOP.md, VIRT/SessionChatView.swift, VIRT/SessionChatViewModel.swift, VIRT/AppNavigationView.swift, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift, VIRTTests/SessionChatViewModelTests.swift, Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorChatTests.swift, Packages/VIRTKit/Tests/VIRTKit/HostConnectorTests.swift, VIRTTests/HostsViewModelTests.swift; CONTRIBUTING.md and docs/board-reads.md are absent at the base.
- Flows walked: composer validation, send and error handling; default/first-chat selection and dispatch for active and idle turns; live chat updates and stream cleanup on disconnect.
- Commands run: `./scripts/test.sh` → passed (exit 0).
## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | VIRT/SessionChatView.swift:55,63 | none |
| AC2 | VIRT/SessionChatViewModel.swift:43,96; Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:293 | VIRTTests/SessionChatViewModelTests.swift › "sendRequiresNonblankDraftAndSubmitsToTheOpenSession", Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorChatTests.swift › "sendsToTheRequestedSessionsDefaultChat" |
| AC3 | VIRT/SessionChatViewModel.swift:96; Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:293 | VIRTTests/SessionChatViewModelTests.swift › "sendRequiresNonblankDraftAndSubmitsToTheOpenSession", Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorChatTests.swift › "sendsToTheRequestedSessionsDefaultChat" |
| AC4 | VIRT/SessionChatView.swift:65; VIRT/SessionChatViewModel.swift:96 | VIRTTests/SessionChatViewModelTests.swift › "failedSendKeepsDraftAndShowsSafeError" |