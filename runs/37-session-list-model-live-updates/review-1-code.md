# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:14-15: The protocol doc says rows are "`[]` while the host isn't connected". That isn't true while a host is `.reconnecting`. The pinned client keeps its `sessionSummaries` cache across a dropped connection and replaces it only after the next successful `listSessions`. Nothing in `HostConnector` clears the rows on `.reconnecting`, so a new subscriber gets the last known rows. Keeping them looks like the intended behaviour, since AC4 only lists `disconnect` and a stopping failure as the times rows become `[]`. But #38 will build on this doc, and as written it promises something else. Fix: reword it, for example "`[]` until the host first lists its sessions, and again after `disconnect` or a failure that stops it. While the host is reconnecting, the last rows stay."
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:267: There is a small timing gap inside the client's `sessionSummaries(host:)`, not in this diff. It reads its first snapshot and subscribes to `hostEvents` from two separate tasks it starts itself. If a connection finishes between those two tasks running, the `.connected` update can be missed, and the rows stay `[]` until the next notification. A real network handshake is far slower than starting a task, so this shouldn't happen in practice. If it ever does, the fix is to also publish `client.host(id)?.sessionSummaries` from `handle(.connected)`.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:166: A `listSessions` error reply with code -32005 still stops the host, because `RecordingTransport` checks every response for that code. That was already true on `origin/main` (the client's on-connect `listSessions` could trigger it). `refreshSessions` is a new way to reach it, but a host isn't expected to reply -32005 to `listSessions`. The builder reported this.
- [note] Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorSessionTests.swift:109,130: These lines assert on a single `updates.next()`. The builder says the client stream can send the same rows twice, and a duplicate `[older]` or `[older, newer]` still waiting here would fail the test. It passed 10 of 10 filtered runs and the full suite here, so the risk looks low. For line 109, `next(&updates) { … }` would be safer. Line 130 has to stay a single `next()`, because it proves the failed refresh yielded nothing.
- [note] Packages/VIRTKit/Sources/VIRTKit/SessionRow.swift:79: An issue or attempt with leading zeros (`07`) shows as `#7`. The spec doesn't cover this and no test does. The builder reported it.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:166: AC5's "stale handle" case has no test of its own. It goes through the same `try?` failure path that the error-reply test covers. The spec's test plan doesn't ask for it, and the builder reported the gap.
## Coverage
- Files read:
  - Spec, build-1.md, AGENTS.md, and the Severity section of `.agents/skills/factory/LOOP.md`
  - `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift` (whole file) and `SessionRow.swift`
  - `ConnectionErrorRecorder.swift` (grep for -32005 and `stopsRetrying`)
  - `HostConnectorSessionTests.swift`, `SessionRowTests.swift`, and the `HostConnectorTests.swift` diff (`FakeHosts`, the generic `next`)
  - The `VIRTTests/HostsViewModelTests.swift` diff, and every `HostConnecting` conformer and caller (`VIRT/HostsViewModel.swift`)
  - In the pinned AHP 1.0.0 client (`5f16d81`): `MultiHostClient.sessionSummaries(host:)` and `client(for:)`, the on-connect `listSessions` and cache replacement in `HostRuntime`, and `HostShared.snapshot()`
- Flows walked:
  - `sessionUpdates`: a host that was never connected; connect, then the first rows; each `root/session*` notification; `disconnect`; a later connect on the same stream; several listeners and how they're removed
  - Stopping failure (401 on reconnect): rows cleared, summaries task cancelled, a late `received` dropped by the registration check
  - `refreshSessions`: not connected or unknown host; success; error reply; stale handle (`try?` plus the registration check after the `await`); a disconnect or reconnect during the request
  - `connect` races: `disconnect` during `client.add` or during `sessionSummaries`, both guarded before and after the await; `deinit` cancelling the summaries tasks
  - `SessionRow`: status bit order, folder, sort comparator (a strict weak ordering, ties and nil dates handled), ISO 8601 parsing, guppi title parsing (dotted names, empty parts, non-ASCII digits, `Int` overflow)
- Commands run:
  - `./scripts/test.sh` → exit 0; all `xcodebuild` app test cases passed
  - `swift test` (VIRTKit) → 55 tests in 9 suites passed
  - `swift test --filter "HostConnectorSessionTests|SessionRowTests"` 10 times → 12 of 12 passed every time
  - A swift script checking `ISO8601FormatStyle` parsing → `Z`, `+02:00`, and 1-, 3- and 6-digit fractions parse; a date without a time, or without a zone, gives nil
