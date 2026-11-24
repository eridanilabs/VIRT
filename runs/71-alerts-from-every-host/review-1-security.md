# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No blockers or nits. One observation:
- [note] VIRT/SessionAlertBanner.swift:22: Any saved host can now raise a banner, not just the one the user last tapped. The banner shows only the alert kind and the title the host sent, not which host it came from. So a host could pick a title that looks like another host's session. This has limited impact. The title is shown as plain text (`Text(verbatim:)`). A tap opens only the sending host's own sessions and chat, because `latestRows[alert.hostID]` and `hosts.first(where:)` both check the host. On the way, the sessions screen's title shows the user-entered host name. Adding the host name to the banner would change "the banner's look", which the spec lists as Out of scope, so this needs no action here.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, LOOP.md (Severity, Output contracts), README.md hunk, VIRT/SessionAlertPresenter.swift (full), VIRT/HostsViewModel.swift (load, delete, tapAlert, select, sceneDidChange, connect), VIRT/HostsView.swift hunk, VIRT/SessionAlertBanner.swift (full), VIRT/HostSessionsView.swift / HostSessionsViewModel.swift (title), VIRTTests diff (checked for tokens, URLs and UserDefaults)
- Flows walked:
  - Follow and unfollow per host: `load` calls `follow`, which uses `start` and `unfollow`. Cancelled tasks are guarded by `!Task.isCancelled` on the main actor, so a deleted host's late rows raise no alert.
  - Delete: only after the library delete succeeds does the host's queue get dropped and its current banner closed. A failed delete leaves the followed set unchanged.
  - Alert tap: the alert's `hostID` picks both the rows and the saved host, so one host's alert can't open a chat on another host. A deleted host's alert is a no-op.
  - Banner and VoiceOver: host text is shown verbatim, nothing is interpreted as markdown or HTML, and nothing new is logged.
  - Token handling: the diff stores, logs or shows no token. Tests use `InMemoryTokenStore` with placeholder tokens.
  - `ws://` and ATS: unchanged.
  - Supply chain: no new dependencies and no project or workflow changes.
  - Load and delete racing each other: an in-flight `load` that finishes after a delete could follow the deleted host again. The same race already exists for `hosts` and `connectAll` on main, and the token is already deleted, so this adds no new risk.
- Commands run:
  - `git diff --stat` and `git diff 296b067...HEAD` (README, VIRT, VIRTTests) → 6 files, 1 commit (05c3f3e)
  - `./scripts/test.sh` → exit 0. VIRTKit `swift test` and the VIRT scheme's `xcodebuild test` on the iPhone 18 Pro simulator both passed.
  - `git status --porcelain` → clean
