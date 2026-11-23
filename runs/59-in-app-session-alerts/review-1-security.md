# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No findings.
- [note] VIRT/SessionAlertBanner.swift:22: The banner shows the session title and the VoiceOver announcement exactly as the host sent them. It uses `Text(verbatim:)` and `accessibilityLabel(Text(verbatim:))`, so the host's text never becomes Markdown, links or HTML. The test at `VIRTTests/SessionAlertPresenterTests.swift:187` checks a title that contains Markdown and HTML characters. This meets the AGENTS.md rule to treat host data as untrusted.
- [note] VIRT/HostsView.swift:85: While the add or edit host form is open, the banner now shows on that sheet, over the form's token `SecureField`. The banner can show up to two lines of title text chosen by the connected host. Only the "Finished", "Needs input" or "Failed" label is fixed. The token still goes only to the Keychain, and tapping the banner just closes the form, so the host has no way to read the token. Host titles already appear elsewhere in the app, so this adds no real risk.
- [note] VIRT/SessionAlertPresenter.swift:114: The alert queue has no size limit. Its length is capped by the number of distinct session and kind pairs, because repeats are dropped, so it can't grow larger than the host's own row list. That makes it no new denial-of-service path.
## Coverage
- Files read: AGENTS.md, spec.md, found-1.md, build-1.2.md (tail), Packages/VIRTKit/Sources/VIRTKit/SessionAlert.swift, VIRT/SessionAlertPresenter.swift, VIRT/SessionAlertBanner.swift, VIRT/HostsViewModel.swift (full), VIRT/HostsView.swift (diff), VIRT/HostSessionsViewModel.swift (diff), VIRT/HostSessionsView.swift (diff), VIRT/SessionChatView.swift (diff), VIRT/VIRTApp.swift (diff), VIRT/HostFormView.swift, Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift (title), VIRTTests/SessionAlertPresenterTests.swift (title cases), README.md (diff)
- Flows walked:
  - **Host rows to alert to banner and announcement:** the title is plain text. `hostID` comes from the presenter, never from the host, so a host can't raise alerts that claim to be from another host.
  - **Changing the selected host:** `follow()` cancels the old tasks and drops the old banner and queue. The `self.hostID == hostID` guards stop updates from the old host arriving late.
  - **Tapping the banner:** the row is looked up only in the followed host's latest rows. The host must still be saved, so a deleted host only closes the banner. The form is closed and its model is released, and the token doesn't leave the Keychain.
  - **Banner over the host form sheet:** this is the token-entry form.
  - **Chat appearing and disappearing:** these events suppress alerts for that chat's session.
  - **Secrets:** nothing new is logged, no new `UserDefaults` or file writes, no new network calls or dependencies, and no changes to ATS, `Info.plist`, the project or workflows.
- Commands run:
  - `git diff --stat` and `git diff f18f9e9...HEAD`, reviewed.
  - `./scripts/test.sh 2>&1 | tail -40`: every test in the last 40 lines passed, including all `SessionAlertPresenterTests`. The exit code 0 is `tail`'s, so it doesn't confirm the script itself exited 0.
