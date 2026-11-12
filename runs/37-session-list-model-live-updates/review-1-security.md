# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [note] Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift:26-41: `title`, `folder`, `modifiedAt` and the parsed guppi owner and name are raw host text. Nothing strips control characters, newlines or bidi overrides, and the owner part can contain `/`. That's fine for a model that only holds plain text. When #38 shows these rows, it should use `Text(verbatim:)` or the `Text(_: some StringProtocol)` initializer, never a `LocalizedStringKey` or `AttributedString(markdown:)`. Otherwise host text could become Markdown links. That decision belongs to #38, not to this PR.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:154-161: `refreshSessions` checks `registrations[hostID] == id` again after the `await`. `received(_:_:_:)` checks the registration too. So rows from a registration that was disconnected, stopped or replaced can't overwrite a later host's rows or leak into them. I checked the TOCTOU windows in `connect` → `watchSummaries` and found them closed.
- [note] Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift:84-104: `RecordingTransport` treats any -32005 reply as a version mismatch, including a reply to the new user-triggered `listSessions`, so that reply stops the host. This is existing behaviour the builder already flagged. It gives a host no new ability, since a host could already send that code on any response.
- [note] HostConnector.swift:161 and SessionRow.swift: `try?` throws away the host's error message, and no new code logs anything. `SessionRow` gets no data from the token or the token URL. This meets the AGENTS.md rule that the token is never logged.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift (all of it), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (all of it), Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift (`RecordingTransport` and `stopsRetrying`), the diff of Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift, Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorSessionTests.swift (setup and first test), the diff of VIRTTests/HostsViewModelTests.swift
- Flows walked:
  - Host summary to row: state bits, folder, guppi title parsing (`Int` overflow, non-ASCII digits and empty parts fall back to the host's title), and sorting (no regex; the date-parsing cost grows linearly).
  - `sessionUpdates`: subscribe, connect, notifications, then disconnect or a stopping failure clears the rows.
  - `refreshSessions`: success, error reply, stale handle, host not connected, and a race between a disconnect or reconnect and an in-flight request.
  - Listener removal: one key in two maps; the keys are unique UUIDs.
  - Token handling: no new path to logs, rows or errors.
  - Tests: no network, all on `InMemoryTransport`.
- Commands run:
  - `git diff origin/main...HEAD` (stat and source) → read
  - `grep` for logging calls in Sources → none
  - `./scripts/test.sh` → exit 0
  - `swift test` in Packages/VIRTKit → 55 tests in 9 suites passed
