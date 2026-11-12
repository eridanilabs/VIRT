# Review r2: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [note] VIRT/HostsViewModel.swift:~137-150: In the A, B, A tap sequence, `connect(A)` can start while B's earlier `disconnect(A)` is still in flight. This is safe with `HostConnector`. `disconnect` removes the registration before it awaits `client.remove`, and the new connect registers under a fresh `HostId`. The test fake mirrors that ordering, so no action is needed.
- [note] VIRT/HostsViewModel.swift:~118-125: `requestedHostIDs` is mutated inside a `for` loop over itself. This is safe because Swift iterates a copy of the set.

## Coverage
- Files read: AGENTS.md, VIRT/HostsViewModel.swift, VIRT/HostsView.swift, the `4588d24..HEAD` diff (README.md, HostsViewModelTests.swift), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (connect/disconnect), build-2.md, triage-1.2.md, review-1-code.md
- Flows walked:
  - Overlapping taps (A then B then A, and A then B then C) with a held disconnect. The earlier tap bails at its `selectedHostID` guard, and only the last-tapped host is registered.
  - Background during an in-flight tap. Nothing connects until `.active`, then the selected host connects.
  - Background while connecting or connected, then active. The host reconnects.
  - Failed host: tapping it again and moving to the background.
  - Row text for hostile protocol versions. A newline, a space or more than 16 characters fall back to "Connected".
  - VoiceOver: `accessibilityValue`, the hidden status line, and the announcement on `selectedStatusText` changes.
- Commands run: `./scripts/test.sh` → passed. The tail showed all `HostsViewModelTests` cases passing, including the new concurrent-tap, background-during-tap and row-text cases.
- Earlier blockers: none raised in round 1 (the verdict was PASS). The round 1 nits are triaged as skip or wontfix, and I did not raise them again.
