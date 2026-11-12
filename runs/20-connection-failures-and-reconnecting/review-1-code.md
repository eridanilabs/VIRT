# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (tests) Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift:`retriedFailureShowsItsReason`, `refusedTokenOrVersionStops`: the tests record the error synchronously inside the maker, before it throws. They never exercise the late-delegate-callback path that the spec's Assumptions describe (`HostConnector.recorded()`, either stopping the host or adding the reason to a reconnecting status). Fix: add one test where the recorder is called after the reconnecting state, for example from a `Task` in the maker, and expect the reason or `.failed(.tokenRefused)`.
- [nit] (robustness) Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:19-22 and ConnectionErrorRecorder.swift:42: `finishTasksAndInvalidate()` runs only in `didCompleteWithError`. `URLSessionWebSocketTransport.close()` before any `send` or `recv` creates no task, so that attempt's session, which holds the recorder strongly, is never invalidated. Fix: invalidate the session when the transport is closed without a task, or accept the rare leak and say so in a comment.
- [note] ConnectionErrorRecorder.swift:`record(_:)`: the recorder is reset only on `.connected`. A drop's own URLError (for example `networkConnectionLost` → `hostUnreachable`) is recorded before the state event arrives. The first `.reconnecting` after a real drop can therefore carry a reason instead of the spec's `nil`. A stale non-stop failure from an earlier attempt also stays as the reason on a later attempt that records nothing. The behaviour is reasonable, and the tests only cover the in-memory close.
- [note] ConnectionErrorRecorder.swift:`RecordingTransport`: a -32005 error reply to any request, not only `initialize`, is recorded. On a connected host it would stop the host through `recorded()`. This is unlikely given the protocol.
- [note] Only the delegate's mapping is tested, by calling `urlSession(_:task:didCompleteWithError:)` directly. No test drives a real `URLSession`. That fits the no-network rule.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, ConnectionErrorRecorder.swift, HostConnector.swift, HostConnectorTests.swift diff, README.md diff, and the upstream `URLSessionWebSocketTransport.swift`. I did not read `ConnectionErrorRecorderTests.swift`, apart from running it.
- Flows walked:
  - Connect → drop → `.reconnecting(1, nil)` → `.connected`.
  - Failed attempt with a reason → retry → `.reconnecting(n, reason)`.
  - 401 → `.failed(.tokenRefused)` with no further transport.
  - -32005 reply → `.failed(.protocolVersionMismatch)`.
  - Client gives up → `.failed(last recorded ?? .other)`.
  - Disconnect and stop clean up the recorder registration.
  - Secret exposure: statuses and failures hold only the mapped `Failure`.
  - No app code in `VIRT/` or `VIRTTests/` uses the changed API.
- Commands run: `swift test` in `Packages/VIRTKit` → 42 tests in 7 suites passed. I did not run the full `./scripts/test.sh` (simulator part).
- Earlier blockers: none (round 1).
