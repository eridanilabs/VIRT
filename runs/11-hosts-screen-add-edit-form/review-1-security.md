# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [note] VIRT/HostFormViewModel.swift:87: In edit mode, you can change a host's URL to a different server and leave the token blank. The saved token is kept, so once #4 adds connecting, it goes to the new server. AC7 allows this on purpose, and only the device's user can make that edit. A follow-up card could ask for the token again when the URL's host changes.

No other findings.

## Coverage
- Files read: AGENTS.md, spec.md (the run's spec), Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift, Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift, Packages/VIRTKit/Sources/VIRTKit/Host.swift, VIRT/HostFormViewModel.swift, VIRT/HostFormView.swift, VIRT/HostsViewModel.swift, VIRT/HostsView.swift, VIRT/VIRTApp.swift, the README.md diff, the HostLibraryTests.swift diff, VIRTTests/HostsViewModelTests.swift (where the tests check the token).
- Flows walked:
  - **Add host:** the URL text is trimmed and parsed with `URL(string:)`. `canSave` checks it against the policy. `HostLibrary.save` checks the policy again before it writes, so the check can't be skipped between enabling Save and saving. The token is written to the Keychain before the host.
  - **Edit host, blank token:** `update(_:)` checks the policy and throws `hostNotFound` for an unknown id. It never reads or writes the token store.
  - **Edit host, new token:** goes through `save(_:token:)`.
  - **Delete:** deletes the token, then the host. If that fails, the host stays and the message holds only the host name.
  - **Save failures:** a refusal shows `Refusal.message`. Any other failure shows a generic message that doesn't include the token.
- Checks:
  - **Token in a URL:** the policy refuses a user name, password, query or fragment. So a pasted `?tkn=` URL can't be saved to `UserDefaults`, and the list's `absoluteString` can't show a token.
  - **Token exposure:** the token field is always a `SecureField`. The token is cleared after a successful save. `description`, `debugDescription` and `customMirror` leave the token out, and a test checks this.
  - **Edit form never reads the token:** a test confirms the edit form doesn't read the token store.
  - **Logging:** the diff adds no `print`, `Logger` or `os_log` calls.
  - **Policy and supply chain:** the diff doesn't touch App Transport Security, Info.plist, project.pbxproj, entitlements, dependencies or workflows. It adds no network calls.
- Commands run:
  - `git log origin/main..HEAD`, `git diff --stat origin/main...HEAD` and `git diff origin/main...HEAD` → read.
  - `./scripts/test.sh` → passed. VIRTKit ran 21 tests in 4 suites, all passing. The app tests (VIRTTests, ATSTests, HostsViewModelTests) all passed on the iPhone 18 Pro simulator.
- Earlier blockers: none (round 1).
