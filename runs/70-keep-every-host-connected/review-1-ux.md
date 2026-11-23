# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [note] README.md:62: The README now says every host connects while VIRT is open and a tap opens its sessions. The row hint ("Opens this host's sessions"), the `HostsView` doc comment and the README all agree with that. AC6 is met.
- [note] VIRT/HostsViewModel.swift:106: `statuses` is per host, so each row shows its own status. After a background, `disconnect` publishes `.idle`, so the rows lose their status lines. The foreground `connectAll` then sets each host back to "Connecting…". That matches the README.
- [note] VIRT/HostsView.swift:56: `selectedStatusText` still announces only the selected host. `selectedHostID` is nil until the first tap, so the screen doesn't announce a burst of statuses while every host connects on load. The sessions model is set before `select`, so a tap announces at most once. That matches the spec's stated assumption.

## Coverage
- Files read: AGENTS.md, spec.md, README.md (diff and section), VIRT/HostsView.swift (full), VIRT/HostsViewModel.swift (diff and the connecting section), VIRT/HostSessionsViewModel.swift (`announcesStatus`), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (`disconnect` and `statusUpdates`)
- Flows walked: launch and load (each host shows its own status), tap on a connected host (reused, with no disconnect), tap on a failed host (retries and the sessions screen starts at Connecting), delete (disconnects and the row disappears), background then foreground (every host disconnects, then reconnects, failed hosts included), VoiceOver announcement and hint
- Commands run: `./scripts/test.sh` → the tail of the output shows only passing cases (HostsViewModelTests, SessionAlertPresenterTests); I did not check the exit code or a summary line
- Earlier blockers: none (round 1)
