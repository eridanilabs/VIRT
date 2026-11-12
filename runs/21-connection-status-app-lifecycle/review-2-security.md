# Review r2: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [note] VIRT/HostsViewModel.swift:136-158: the round 1 race (#30) is fixed. `connect(_:)` now sets `selectedHostID` before its first await. It also removes each other host from `requestedHostIDs` before awaiting that host's `disconnect`, so a later tap never finds a host it should drop already gone. After the disconnects, the guard `selectedHostID == hostID, !isInBackground` stops a tap that was taken over. I walked A→B→A, A→B→C, a background event during a tap, and background then active while the disconnect loop is still awaiting. In each case at most one host stays registered. That holds because `HostConnector.connect` sets `registrations[hostID]` before its first await (line 140-142), and `disconnect` removes it before its first await (line 164). Calls the main actor makes in order therefore change the actor's state in that order. The add that is still running then checks `registrations[hostID] == id` (lines 153 and 156) and drops a stale registration. The model is main-actor isolated (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), so its own state changes can't race each other.
- [note] VIRT/HostsViewModel.swift:102-105: the protocol-version check now holds against a hostile host. I ran the exact regex in Swift outside the app. It turns these down:
  - a combining accent (`1\u{0301}`)
  - a zero-width joiner (`1\u{200D}`)
  - 50 stacked combining marks
  - a right-to-left override (`\u{202E}1`)
  - a fullwidth `１`
  - a trailing newline

  Swift `Regex` matches whole graphemes, so a character with marks attached falls outside the ASCII ranges. That also blocks the stacked marks that draw text over the next row. The row then falls back to "Connected". Round 1's #31 is fixed.
- [note] VIRT/HostsView.swift:27,40-42: `accessibilityValue` and `AccessibilityNotification.Announcement` use the same status text as the row. That text is fixed strings, an `Int`, the checked version, or `Failure.message`, so no token or URL reaches VoiceOver.
- [note] The delta adds no dependencies, network calls, logging, plist, entitlement, workflow or `.agents` changes. The README edit removes one sentence and adds no secrets.

## Coverage
- Files read: AGENTS.md; the records in the folder: review-1-security.md, triage-1.md, triage-1.2.md, build-2.md. The code, read in full: VIRT/HostsViewModel.swift, VIRT/HostsView.swift lines 1-100, and Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (`connect`, `disconnect`, `openTransport` and the `registrations` guards). The diffs: VIRTTests/HostsViewModelTests.swift and README.md, plus the project.pbxproj isolation settings.
- Flows walked:
  - **Overlapping taps:** A→B→A and A→B→C while the first disconnect is held. Also a quick double tap on one host, which `isActive` stops early.
  - **Background:** going to the background mid-tap; then background → active while the disconnect loop is awaiting.
  - **Failed host in the background:** no registration is left, which matches the skipped triage item 8.
  - **Host data on screen and in VoiceOver:** the host-sent `protocolVersion` → row text, `accessibilityValue` and the announcement.
- Commands run:
  - `git diff 4588d24..HEAD` (stat and full) → 4 files changed.
  - `git log origin/main..HEAD` → the 3 delta commits.
  - The regex check above (`swift -enable-bare-slash-regex rx.swift`) → only `0.1.0` matched.
  - `./scripts/test.sh` → exit 0. All VIRTKit and app tests passed, including the new tests for overlapping taps, a background event mid-tap, and the hostile version strings.
- Earlier blockers:
  - #30 (the `select(_:)` race could leave two hosts connected; triage upgraded it from my round 1 nit) → fixed in 029834c.
  - I raised no other round 1 blockers.
