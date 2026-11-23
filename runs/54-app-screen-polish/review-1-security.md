# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No findings.

- [note] VIRT/HostSessionsView.swift:66: The new VoiceOver announcement and the status line, which now wraps, only ever show `Status.text`. That text is built from fixed strings (`Failure.message`), plus a host-sent protocol version that is shown only if it matches `/[0-9A-Za-z.\-]{1,16}/`. The `reconnecting` reason is never shown. So no host-controlled text, token or URL reaches VoiceOver or the wrapped line.
- [note] VIRT/HostsView.swift:134: `HostLibrary.preview` builds a library in a throwaway `UserDefaults` suite with in-memory tokens. Before this change it was compiled into Release builds; now it sits inside `#if DEBUG`, which shrinks what ships.
- [note] VIRT/HostFormViewModel.swift:15-19: The new `didSet` handlers only clear `saveError`. Every value `saveError` can hold is a fixed string or a `HostURLPolicy` refusal message, so none of them holds the token.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, the full diff of VIRT/HostFormView.swift, VIRT/HostFormViewModel.swift, VIRT/HostSessionsView.swift, VIRT/HostSessionsViewModel.swift, VIRT/HostsView.swift, VIRT/HostsViewModel.swift, VIRT/SessionChatView.swift, VIRT/SessionChatViewModel.swift, VIRTTests/HostsViewModelTests.swift, VIRTTests/SessionChatViewModelTests.swift. Also read around the hunks: HostsViewModel.swift `Status.text`, `isPlainVersion` and `isActive` (lines 160-220), and Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (`Status`, `Failure.message`, and how `handle(_:)` drops `lastError` and `failed(reason:)`).
- Flows walked:
  - Status text from the host to the screen: connector → `HostSessionsViewModel.statusText` → status line, VoiceOver announcement and spinner. I also checked that the Hosts screen skips its own announcement while a sessions screen is open.
  - Failed host load and retry: corrupt `HostStore` data → `loadFailed` → Retry → `load()`.
  - Host form errors: the URL error text, then `saveError` set by a failed token write and cleared when a field is edited. The token stays in the Keychain path, and no error string includes it.
  - Chat scroll phase: `onScrollPhaseChange` → `scrollPhaseChanged`. Its inputs are only local scroll geometry.
  - What ships in Release: preview code is now inside `#if DEBUG`.
  - Trust boundaries and policy: no new dependencies, network calls, URL or ATS changes, logging, `UserDefaults` writes, or changes to `VIRTKit` or the project file.
- Commands run:
  - `git diff da68123…HEAD` (stat, app files and tests) → 10 files, 1 commit (8b7ffaa)
  - `grep` for `saveError` and `errorMessage` assignments → all fixed strings or policy refusal messages
  - `./scripts/test.sh` → exit 0. The VIRTKit suite and the app tests on the iPhone 18 Pro simulator passed. I filtered the output for pass/fail lines and the last lines showed no failures.
