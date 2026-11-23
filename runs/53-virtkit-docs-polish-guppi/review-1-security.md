# Review r1: security (default)

VERDICT: PASS
## Findings
- [nit] (main) Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift:82: The doc comment still says the check confirms that a plain `ws://` host "really is on the tailnet". README.md now says correctly that the check only looks at addresses, so a network that uses `100.64.0.0/10` itself, such as a carrier's, can still pass. A later security change could rely on the doc comment's stronger promise. This wording was already on `origin/main`. Fix: change it to say what the check does: the device has an address in a Tailscale range, and the host's address, or every address its name resolves to, is in one too.
- [note] AGENTS.md:54: As AC6 requires, the line says "`TailnetCheck` checks Tailscale first". That is a little stronger than the README's more careful account of what the check proves. The README is accurate, and the AGENTS.md line still points readers to the `.ts.net` name, so no change is needed.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:99,103,350: `client` and `handle(_:)` change from private to internal, and `registrations` becomes `private(set)`. They are only visible inside VIRTKit, for tests. No public API changes, and nothing that holds the token or the token URL is exposed. `handle` still drops `lastError` and `failed(reason:)`.
- [note] Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift:108-158: `SessionEndingTransport` keeps only the inner transport and the session, never the URL. It doesn't log, and errors pass through unchanged. `start()` and `close()` share one lock, so a `send` or `recv` after `close` throws `TransportError.closed` and opens no socket.
- [note] Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift:442: `webSocketTransportEndsItsSessionWhenClosedUnused` builds a real `URLSession` but closes the transport before any I/O, so it opens no network connection. The token in it is a placeholder, not a real secret.

## Coverage
- Files read:
  - .workbench/pin/loop/.github/agents/reviewer-security.agent.md
  - LOOP.md (Severity, Output contracts)
  - AGENTS.md
  - The spec
  - The full diff for README.md, AGENTS.md and VIRT/HostFormViewModel.swift, plus where `urlWarning` is used in HostFormView.swift
  - The diffs of every test file: HostConnectorTests, HostLibraryTests, HostURLPolicyTests and HostsViewModelTests
  - Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift lines 1-60, 92-110 and 155-380 (connect, disconnect, openTransport, tokenURL, stop, handle, recorded)
  - Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift, whole file
  - Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift, whole file
  - The HostURLPolicy.swift and HostLibrary.swift hunks
  - There is no CONTRIBUTING.md.
- Flows walked:
  - Connect and attempt: library, then policy, then tailnet check, then token, then `tokenURL`, then `webSocketTransport`, which now wraps the transport in `SessionEndingTransport`, then `RecordingTransport`. The token stays only in the transport URL and never reaches a status, a log or an error.
  - Close before I/O (session ended), close after I/O (the recorder ends it), and a close racing the first send or recv (`endIfClosed`).
  - `.connected` handling when the client has no host: nothing is published, and the recorder is still reset.
  - A late recorder call: a 401 stops the host, and a `cannotFindHost` error becomes the reconnect reason.
  - A token read that throws an error that isn't a `Failure`: it keeps retrying and never builds a URL or opens a transport, the same as before this branch.
  - Saving a host in the form: discarding `save`'s warning hides nothing, because `HostFormView` shows `urlWarning` before the save.
  - README and AGENTS.md security claims, checked against the code:
    - What `TailnetCheck` checks: a local Tailscale-range address, then the literal address or every resolved address, then it connects to the checked address.
    - Tailnet ACLs and the token as the only guards.
    - The served name appearing in Certificate Transparency logs.
    - Clearing the clipboard and any clipboard-history app.
    - Re-copying the token after a refused-token error.
  - Supply chain: no changes to `Package.swift`, `Package.resolved`, `Info.plist` (ATS), workflows, `.agents` or apm files, and no new dependencies or network calls.
  - Repo policy: no ATS weakening, and the token still lives only in the Keychain.
- Commands run:
  - `git diff c6f267b...HEAD` (stat and full) → 11 files changed
  - `git log c6f267b..HEAD` → 4 commits
  - `./scripts/test.sh` → exit 0 (`swift test` and the iOS simulator `xcodebuild test` both passed)
  - `git status --short` → clean
