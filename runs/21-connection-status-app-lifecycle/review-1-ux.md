# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) VIRT/HostsView.swift:20-26: The status line changes in place with no announcement. A VoiceOver user who taps a host hears nothing when it goes from Connecting… to Connected or Failed. Fix: post an `AccessibilityNotification.Announcement` when `statusText` changes, or add `.accessibilityValue(status)` on the row so it is read with the row.
- [nit] (polish) README.md:62: "Tapping a host that is already connecting or connected does nothing" leaves out reconnecting. AC7 and the code both include it. Fix: say "connecting, connected or reconnecting".
- [nit] (polish) README.md:80: The last line still says "The milestone that adds connecting documents the exact setup." This change adds connecting, so the line is out of date. Fix: drop it, or point at where the setup is documented.
- [note] VIRT/HostsView.swift:31-36: The swipe actions put Delete first, so a full swipe deletes with no confirmation. That matches the old `.onDelete` behaviour. Edit is a tinted second action. This is fine.
- [note] VIRT/HostsViewModel.swift:90-98: `select` and `connect` apply the AC7 rules: a tap on an active host is ignored, a failed or idle host reconnects, and a tap on another host disconnects the first. The row shows "Connecting…" at once, then the connector's real status. Deleting or editing the connected host leaves it connected. The spec lists this as out of scope.
- [note] VIRT/HostsViewModel.swift:73-81: The status text matches AC8 exactly, including "Connected" when the protocol version is empty. The connector's `Failure.message` never includes the token. Long failure messages wrap, because the `Text` has no line limit. Failed rows are red, and the "Failed:" text means colour isn't the only signal.
- [note] README.md:60-69: The README now covers tap to connect, swipe for Edit and Delete, the four row statuses, and the background and foreground behaviour (AC10). The scaffold wording and "Tap a host to edit it" are gone.

## Coverage
- Files read: VIRT/HostsView.swift, VIRT/HostsViewModel.swift, VIRT/VIRTApp.swift, README.md, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (protocol, connect, disconnect, status publishing), spec.md, and the pre-change HostsView.swift from origin/main. I did not read AGENTS.md closely, build-1.md, or the test files.
- Flows walked: tap to connect, tap an active host (ignored), tap a failed host (retry), switch hosts, swipe to Edit and Delete, background then active for a connected host, and background with a failed or idle host (no reconnect). The empty state is unchanged.
- Commands run: `./scripts/test.sh` → the output tail shows the HostsViewModel tests passing. I did not check the VIRTKit portion or the exit code.
- Earlier blockers: none (round 1)
