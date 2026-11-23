# Review r2: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No findings.
- [note] VIRT/HostSessionsView.swift:66: `.id(ObjectIdentifier(chat))` now builds a fresh `SessionChatView` when a banner tap swaps the chat. When the old view goes away, its `.task { await model.follow() }` is cancelled, so session A's subscription ends and none of A's messages reach B's screen. `chatDisappeared` only clears `onScreenChat` when it still names the session that left (SessionAlertPresenter.swift:106), so if A's disappear event arrives after B's appear event, it doesn't clear B's suppression. The id comes from the app's own object reference, not from host data, so a host can't choose or collide it.
- [note] VIRT/SessionAlertPresenter.swift:33: `usesAssistiveTech` can be written from outside, but only `SessionAlertBanner` sets it, from SwiftUI's own accessibility settings. It only picks how long the banner stays up (4 s or 20 s). No host data reaches it, and the close task still holds `self` weakly.
## Coverage
- Files read: the reviewer-security instructions, the `## Severity` section of LOOP.md, AGENTS.md (layout and tests), review-1-security.md, triage-1.md, triage-1.2.md, build-2.md, the full delta `git diff 93b2756..HEAD` (VIRT/HostSessionsView.swift, VIRT/HostsViewModel.swift, VIRT/SessionAlertBanner.swift, VIRT/SessionAlertPresenter.swift, VIRTTests/SessionAlertPresenterTests.swift), the chat appear, disappear and task hooks in VIRT/SessionChatView.swift, and `chatAppeared`, `chatDisappeared` and `isOnScreen` in VIRT/SessionAlertPresenter.swift
- Flows walked:
  - **Banner tap over open chat A to chat B (#65 fix):** the view identity resets, A's follow task is cancelled, nothing leaks between sessions, and appear and disappear events in either order leave suppression right.
  - **Banner auto-close under VoiceOver or Switch Control (#66):** the value comes only from the app's environment, the duration is chosen when the banner shows, and the task is cancelled when the banner is replaced.
  - **Change to the `tapAlert()` comment (#68 declined):** it's a comment only, with no change in behaviour.
  - **Secrets and supply chain:** the delta adds no dependencies, network calls, logging, storage writes, or project, plist or workflow changes.
- Commands run:
  - `git log --oneline 93b2756..HEAD` showed 2 commits (ab0f228, 284c25d).
  - `git diff --stat` and `git diff 93b2756..HEAD`, reviewed.
  - `./scripts/test.sh` exited 0, with 110 "passed on" lines for the app tests, including `theBannerStaysLongerWithVoiceOverOrSwitchControl` and `tapOverAnotherSessionsChatReplacesItWithANewChatModel`. The log has no failed tests; the only matches for "failed" are test names.
- Earlier blockers: none. Round 1 was a PASS with no blockers.
