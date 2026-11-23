# Review r1: code (default)

VERDICT: PASS
## Findings
- [nit] (polish) Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift:409: In `connectedWithoutAClientHostPublishesNothing`, the 200 ms `Task.sleep` after `await connector.handle(...)` does nothing. `handle` is awaited directly and `publish` runs synchronously on the actor, so any `.connected("")` is already in the stream before `disconnect`. Fix: remove the sleep so the test has no timing in it.
- [nit] (polish) Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift:442: The name `webSocketTransportEndsItsSessionWhenClosedUnused` says the session ends, but the test only checks `transport is SessionEndingTransport` and then closes it. Fix: rename it to something like `webSocketTransportIsSessionEnding`, or add an assertion that the session ends.
- [note] Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift:364: In the `.cannotFindHost` case of `lateRecorderCallStopsOrSetsReason`, the test can also pass through the `handle(.reconnecting)` path. That path reads the recorder's stored failure if a retry event arrives before `recorded(...)` runs. Either way the user-visible behaviour is right, and with a 250 ms initial backoff the late path is the usual one.
- [note] Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift:111: I walked the `close` vs first `send`/`recv` race in `SessionEndingTransport`. If `close` wins, `start()` throws `.closed` and `close` invalidates. If `start` wins and `close` lands before the inner `ensureTask`, the inner transport throws `.closed` and `endIfClosed` invalidates. If the inner task already exists, `close` cancels it and the recorder's `didCompleteWithError` invalidates. Invalidating twice does no harm. All three paths end the session.
## Coverage
- Files read: AGENTS.md, spec.md, LOOP.md (Severity, Output contracts), reviewer-code.agent.md, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (full), ConnectionErrorRecorder.swift (full), HostLibrary.swift (hunk), HostURLPolicy.swift (hunk), TailnetCheck.swift (resolver/interfaces), VIRT/HostFormViewModel.swift (save), VIRT/HostsViewModel.swift (status text), all changed test files (HostConnectorTests, HostLibraryTests, HostURLPolicyTests, VIRTTests/HostsViewModelTests), the README.md and AGENTS.md diffs, the upstream `URLSessionWebSocketTransport.swift` (lazy task creation, close semantics), and `ReconnectPolicy.exponential` (250 ms initial).
- Flows walked:
  - Connect, `.connected` event: the normal path, plus a host removed from the client, which now publishes nothing instead of `""`.
  - Transport lifecycle: closed before I/O, closed after a send, close racing the first send/recv, and a recv clean close, where the task completion lets the recorder invalidate.
  - Reconnect with an untyped token-read error: it retries and never stops.
  - A late recorder call: a 401 stops the host, and a `.cannotFindHost` becomes the reconnecting reason.
  - `HostFormViewModel.save`: add, edit with a token, edit without a token (`update` still uses `@discardableResult`, which is out of scope).
  - All `HostLibrary.save` callers: grep found none left without `_ =`.
  - README claims checked against the code: "Connecting…" and "Connected · protocol …" strings, the TailnetCheck semantics, and the token-refused message.
- Commands run:
  - `./scripts/test.sh` → exit 0. In the VIRTKit `swift test` stage, 79 tests in 12 suites passed, including all 6 new connector/transport tests and `missingHostAndUnsupportedSchemeSayWhatToDo`. The xcodebuild iOS-simulator tests passed. No `warning:` lines appeared in the output.
  - `git status --short` → clean.
  - `git diff c6f267b...HEAD` (stat, code, docs).
## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:51, Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:53, Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift:26, Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift:66 | Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift › "missingHostAndUnsupportedSchemeSayWhatToDo", Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift › "evaluates(_:)" |
| AC2 | Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift:26, VIRT/HostFormViewModel.swift:86, VIRT/HostFormViewModel.swift:93 | Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift › "failingTokenWriteSavesNoHost" (and the other `_ =` callers), VIRTTests/HostsViewModelTests.swift › "editWithANewTokenReplacesIt"; `./scripts/test.sh` build shows no unused-result warnings |
| AC3 | Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:363, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:46, Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift:111 | Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift › "connectedWithoutAClientHostPublishesNothing", "transportClosedBeforeAnyIOEndsItsSession", "transportClosedAfterASendLeavesItsSessionToTheRecorder", "webSocketTransportEndsItsSessionWhenClosedUnused" |
| AC4 | Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:34, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:15, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:158 | review only (doc comments, per the spec's test plan) |
| AC5 | Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift:14 (`failsReads`) | Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift › "untypedTokenErrorRetriesForever", "lateRecorderCallStopsOrSetsReason(httpStatus:code:)" |
| AC6 | README.md:75, README.md:76, README.md:78, README.md:97, README.md:102, README.md:105, README.md:118, README.md:134, README.md:137, AGENTS.md:54 | review only (markdown, per the spec's test plan) |
