# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (polish) VIRT/HostsView.swift:51: VoiceOver may go quiet about connection status while a chat is open. The Hosts screen now skips its announcement whenever `sessions != nil`, and that includes while a chat is pushed on top. The sessions screen announces from `.onChange(of: model.statusText)`, and its status comes from `.task { await model.follow() }`. In a `NavigationStack`, that task is normally cancelled when another screen is pushed over it. If so, a "Reconnecting (attempt 1)…" or "Failed: …" while someone reads a chat is announced by neither screen, but the Hosts screen used to announce it. I didn't check this on a device. Fix: with VoiceOver on, open a chat and drop the host to confirm. If it's silent, let the Hosts screen keep announcing while a chat is open, for example by skipping only while the sessions screen itself is on top.
- [nit] (polish) VIRT/HostsView.swift:54-60: If Retry fails again, nothing on screen changes and VoiceOver says nothing, so the user can't tell the tap did anything. The view also gives no hint what to do if it keeps failing. Fix: add a short description under "Couldn't load hosts", for example "VIRT couldn't read the saved hosts.", and post an announcement when a retry fails.
- [note] VIRT/HostSessionsView.swift:66: `statusUpdates` sends the host's current status first. If the sessions screen subscribes before `select` reaches `connector.connect`, it shows "Not connected" (idle host) or "Failed: …" (failed host) before "Connecting…", and VoiceOver now announces it. In practice the button's `select` task usually reaches the connector first. The spec's Assumptions accept this first-status case and leave the fix to a later card.
- [note] VIRT/SessionChatView.swift:28-37: I walked the drag flow, including when you let go with content still streaming. Following turns off on `.interacting` and stays off through `.decelerating`, because `isInteracting` stays true until `.idle`. Scrolls by VoiceOver, keyboard or the status bar don't go through `.interacting`, so they keep their old behaviour. A short drag at the bottom while a reply streams can settle more than 24 pt above the bottom, which leaves following off. That matches AC4's "set from whether the chat is at the bottom".
- [note] VIRT/HostFormView.swift:31-35: Without the "Token" header, the SecureField still has the accessible name "Token" from its title and shows the prompt "Connection token" or "New token". So the field is still clearly labelled, both on screen and for VoiceOver.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, LOOP.md (Severity), VIRT/HostFormView.swift, VIRT/HostFormViewModel.swift, VIRT/HostsView.swift, VIRT/HostsViewModel.swift, VIRT/HostSessionsView.swift, VIRT/HostSessionsViewModel.swift, VIRT/SessionChatView.swift, VIRT/SessionChatViewModel.swift, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (`statusUpdates`)
- Flows walked:
  - **Host form:** an unparseable URL shows the new error copy. The CGNAT warning text is secondary with an orange icon. A failed save shows its error, and editing the name, URL or token clears it. A successful save empties the token. The Token field is still labelled without its header.
  - **Hosts list:** a failed load shows "Couldn't load hosts" with Retry. A retry that fails again, and one that succeeds and clears it. With the load failed, the rows are hidden and "Add host" still works. Long status lines now wrap. Announcements are skipped while a sessions screen is open.
  - **Sessions screen:** tapping an idle, failed, connecting or connected host sets the starting status. The spinner shows only while connecting or reconnecting. A VoiceOver announcement posts on each status change, including the race on the first status. The status while a chat is pushed on top.
  - **Chat:** start a drag, decelerate, settle at the bottom or above it. Content that grows during a drag. Scrolls by VoiceOver, keyboard or the status bar. A tap on a tool-call row, with the chevron on the first-text baseline.
- Commands run:
  - `git diff da68123…HEAD` (stat and full app diff) → 10 files reviewed
  - `./scripts/test.sh` → exit 0, all VIRTKit and app tests passed
  - `git status --short` → clean
