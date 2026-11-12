# Review r2: ux (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [note] README.md:62,80: Both round 1 README nits are fixed. The no-op tap list now includes "reconnecting", and the stale "The milestone that adds connecting…" sentence is gone.
- [note] VIRT/HostsView.swift:20-30: The status line is hidden from VoiceOver and exposed as `.accessibilityValue` on the row, so it is read once with the row. `.onChange(of: model.selectedStatusText)` posts an announcement when the selected host's status changes. An idle host has no announcement, and the value is an empty string.
- [note] VIRT/HostsView.swift:79-96: A failed status shows a red warning icon next to secondary-coloured text. That fixes the red-on-white contrast, and the icon plus "Failed:" mean colour isn't the only signal. Failed text can wrap, and the other statuses are limited to one line. The Edit swipe action now uses `.accentColor` instead of a fixed blue.
- [note] VIRT/HostsViewModel.swift:88-99: A host-sent `protocolVersion` is shown only if it matches `[0-9A-Za-z.\-]{1,16}`. Otherwise the row reads "Connected" with no version, so odd input can't distort the row.
- [note] VIRT/HostsViewModel.swift:110-150: The round 1 security blocker (two hosts connected after a tap during a disconnect) is handled from the user's side. The tapped row shows "Connecting…" at once and every other requested host is disconnected. A tap superseded during a disconnect, or a background during a tap, ends without connecting, and the host reconnects when the scene is active again.

## Coverage
- Files read: README.md (delta), VIRT/HostsView.swift (full), VIRT/HostsViewModel.swift (delta and the connect, select and scene sections), triage-1.md, triage-1.2.md, review-1-ux.md. I did not read the test diff beyond the test names in the output.
- Flows walked: tap to connect, tap an active host (ignored), tap a failed host (retry), rapid taps on two hosts, background during a tap, background then active with a connected host, a non-plain protocol version, and a VoiceOver status change on a row.
- Commands run: `./scripts/test.sh` → exit 0, and the HostsViewModel tests pass, including the new concurrent-tap and background-during-tap tests.
- Earlier blockers: I raised none in round 1. The security blocker from round 1 (two hosts connected after a tap during a disconnect) looks fixed from the user's side.
