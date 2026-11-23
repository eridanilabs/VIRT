# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [note] VIRT/HostsView.swift:62: The load-failure announcement joins the title and the description: "Couldn't load hosts. VIRT couldn't read the saved hosts." That reads well. It fires on every failed Retry, even though the on-screen view doesn't change, and a failed Retry is the case AC8 asks for.
- [note] VIRT/HostsView.swift:53: The announcement split follows AC7. The Hosts screen announces unless the sessions screen is on top with no chat open. The sessions screen announces only while `chat == nil`. So with a chat open, exactly one screen (Hosts) announces a status change.
- [note] README.md:78 and README.md:137: The AC5 sentence matches the spec text exactly. The refused-token step now names the real controls, swipe the host, **Edit**, **Save**. These match the swipe action "Edit" in `HostsView`. I did not check the form's Save button.
- [note] VIRT/HostSessionsView.swift:52: `.controlSize(.small)` is applied before `.accessibilityHidden(true)`, so the spinner stays hidden from VoiceOver as before.
## Coverage
- Files read: VIRT/HostsView.swift, the diffs of VIRT/HostSessionsView.swift, VIRT/HostSessionsViewModel.swift, VIRT/HostsViewModel.swift, VIRT/SessionChatViewModel.swift, README.md, TailnetCheck.swift, HostConnectorTests.swift, VIRTTests/HostsViewModelTests.swift, the spec, AGENTS.md
- Flows walked: a failed load followed by a failed Retry (the counter changes each time, so the announcement fires, and the description shows). A status change with Hosts on top, with the sessions screen on top, and with a chat open. Reading the README text and doc comments against AC3–AC6.
- Commands run: `./scripts/test.sh` → exit 0, all tests passed, including the new failure-count and one-announcer tests
- Earlier blockers: none (round 1)
