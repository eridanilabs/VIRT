# Spec: Actionable connection failures and the reconnecting state

## Goal
When a saved host fails to connect or drops, VIRT gives a short reason the person can act on, such as "token refused" or "can't reach the host". After a drop it shows that it is reconnecting, with the attempt number, until it connects again. When retrying can't help, it stops.

## Acceptance criteria
- AC1: `HostConnector.Failure` gains `tokenRefused`, `hostUnreachable`, `tlsFailed`, `protocolVersionMismatch` and `blockedByATS`. Each has a short, fixed `message`. `other` keeps "Couldn't connect to the host."
- AC2: Errors map to cases like this. HTTP 401 or 403 on the upgrade → `tokenRefused`, even when a URLError comes with it. URLError `cannotFindHost`, `cannotConnectToHost`, `timedOut`, `notConnectedToInternet` or `networkConnectionLost` → `hostUnreachable`. `secureConnectionFailed` and the server/client certificate codes (-1200…-1206) → `tlsFailed`. -1022 (`appTransportSecurityRequiresSecureConnection`) → `blockedByATS`. A JSON-RPC error response with code `AhpErrorCodes.unsupportedProtocolVersion` (-32005) → `protocolVersionMismatch`. Anything else → `other`.
- AC3: Each attempt records its typed error in two places. A `URLSessionTaskDelegate` on the default transport's own `URLSession` records URLErrors and the HTTP status. A wrapper around the transport sees a -32005 error response. This is needed because `MultiHostClient` 1.0.0 only reports errors as strings. Only the mapped `Failure` is kept, never the `URLError` or its failing URL.
- AC4: `Status` gains `reconnecting(attempt: Int, reason: Failure?)`. After a drop, the status is `.reconnecting(attempt: 1, reason: nil)` and then `.connected` again. A failed attempt that will be retried shows its mapped reason.
- AC5: `tokenRefused` and `protocolVersionMismatch` stop the host. The status becomes `.failed(that case)` and no further transport opens. Other failures keep retrying under the reconnect policy. When the client gives up, the status becomes `.failed(last recorded failure ?? .other)`.
- AC6: No status, message or description contains the token or a `tkn` URL, including when a URLError's userInfo holds the token URL.

## Out of scope
- Showing the status or messages in the app's views and view models (a later part of #4).
- A manual reconnect action, path monitoring (`NWPathMonitor`) and changes to backoff tuning.
- New ATS exceptions, and the `NWConnectionWebSocketTransport`.

## Assumptions
- I couldn't read the #4 spec, because I can't run `git` here, so AC4 and AC5 are restated from the issue text.
- `TransportMaker` becomes `(URL, ConnectionErrorRecorder) throws -> any AHPTransport`. The default maker builds a per-attempt `URLSession` with the recorder as its delegate and calls `finishTasksAndInvalidate()` when the attempt ends. Tests record errors through the recorder.
- The delegate callback can arrive after the client's state event. If so, recording a failure updates the status, or stops the host, at the moment it is recorded.
- ATS and TLS failures keep retrying, because the issue lists only token refused and version mismatch as stop cases.
- The existing `reconnectReadsTheTokenAgain` test now expects `.reconnecting(attempt: 1, reason: nil)` in place of `.connecting`.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: the new `Failure` cases, the `reconnecting` status, the stop rules and the maker signature.
- `Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift` (new): the error mapping, the URLSession delegate and the transport wrapper that watches for -32005.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift`: `FakeHosts` gains -32005 replies and the new maker signature.
- `Packages/VIRTKit/Tests/VIRTKitTests/ConnectionErrorRecorderTests.swift` (new): the mapping table.

## Test plan
- AC1, AC2 → `ConnectionErrorRecorderTests.swift`: parameterized over each URLError code, 401, 403, 401 with a URLError, 500, -1022 and -32005, checking the case and the exact message.
- AC3 → `ConnectionErrorRecorderTests.swift`: the delegate callback records the mapped case, and a wrapped `InMemoryTransport` that receives a -32005 reply records `protocolVersionMismatch`.
- AC4 → `HostConnectorTests.swift`: connect, close the server-side `InMemoryTransport`, then expect `[.reconnecting(attempt: 1, reason: nil), connected]`. A second test has the maker record `cannotFindHost` and expects `.reconnecting(attempt: n, reason: .hostUnreachable)`.
- AC5 → `HostConnectorTests.swift`: a 401 and a -32005 initialize reply each end in `.failed(...)`. After 700 ms, the transport count hasn't grown.
- AC6 → `HostConnectorTests.swift`: `expectNoSecret` passes on statuses from a recorded URLError whose `NSURLErrorFailingURLErrorKey` is the token URL.

## Size estimate
Estimate: 295 code lines
- Typed failures with short messages, mapped from URLErrors, HTTP statuses, ATS and -32005
- Recording the typed error per attempt through a URLSession delegate and a transport wrapper
- A reconnecting status with the attempt number and reason, then connected again
- Stop retrying on token refused and version mismatch
