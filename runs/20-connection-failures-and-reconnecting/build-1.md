# Build r1 (claude-opus-5.5)

## Summary
When a saved host fails to connect, VIRT now gives a typed reason with a short fixed message. After a drop, it shows `.reconnecting(attempt:reason:)` until it connects again. A refused token or a protocol version mismatch stops the host, other failures keep retrying, and if the client gives up the status is `.failed(last recorded failure ?? .other)`. The full `./scripts/test.sh` run passed: `swift test` on VIRTKit and `xcodebuild test` on the iOS simulator. I also ran the connector tests 10 more times and none failed.

## Changes
- **`ConnectionErrorRecorder.swift`** (new):
  - **The recorder:** `ConnectionErrorRecorder` acts as the delegate for each attempt's `URLSession`. It records URLErrors and the HTTP status from the upgrade, then shuts that session down when its task finishes. It keeps only the mapped `Failure`, never the `URLError` or the URL with the token in it.
  - **The mapping:** `Failure(error:httpStatus:)` follows the table in AC2. A task VIRT cancels itself records nothing, so a clean close doesn't show up as a failure.
  - **The -32005 check:** `RecordingTransport` wraps the transport and records `protocolVersionMismatch` when an `AhpErrorCodes.unsupportedProtocolVersion` (-32005) error reply comes back. It only decodes a frame a second time if the frame contains that code.
  - **Stop cases stick:** once a token refusal or version mismatch is recorded, a later error doesn't replace it.
- **`HostConnector.swift`** (extended the existing actor):
  - **New cases:** `Failure` gets the five new cases and their messages, and `Status` gets `reconnecting(attempt:reason:)`.
  - **Maker signature:** `TransportMaker` is now `(URL, ConnectionErrorRecorder)`. The default maker, `webSocketTransport`, opens an ephemeral `URLSession` with the recorder as its delegate.
  - **One recorder per connection:** each `connect` gets one recorder, shared by all its attempts and cleared when the host connects.
  - **Stop and give-up rules:** `handle()` maps the client's reconnecting and failed states using the recorder's failure, and stops the host on a stop case. The existing `openTransport()` wraps every transport in `RecordingTransport`, and the existing `stop()` handles stopping.
  - **Late errors:** a new `recorded()` handles a delegate callback that arrives after the client's state event. It either stops the host or adds the reason to the current reconnecting status.
- **`HostConnectorTests.swift`**:
  - `FakeHosts` can now refuse the upgrade with an HTTP status (recorded with the token URL in the URLError's userInfo) or reply to `initialize` with an error code, and it uses the new maker signature.
  - `reconnectReadsTheTokenAgain` now expects `.reconnecting(attempt: 1, reason: nil)` instead of `.connecting`.
  - The old `clientErrorFailsWithTheFixedMessage` test became the parameterized give-up test below.
- **`ConnectionErrorRecorderTests.swift`** (new): the mapping table, the messages, the delegate, and the transport wrapper.
- **`README.md`**: one paragraph on failure reasons, reconnecting and the stop cases.

## AC coverage
- **AC1** → `ConnectionErrorRecorderTests` › `hasAFixedMessage` (6 cases, including `.other`'s "Couldn't connect to the host.")
- **AC2** → `ConnectionErrorRecorderTests` › `mapsErrorsAndStatuses` (20 cases: each URLError code, -1200…-1206, -1022, 401/403 with and without a URLError, 500, other) and › `ignoresNoErrorAndCancelling`. The -32005 case is in › `transportRecordsAVersionMismatch`.
- **AC3** → `ConnectionErrorRecorderTests` › `delegateRecordsTheMappedFailure` and › `transportRecordsAVersionMismatch` (a wrapped `InMemoryTransport`: -32005 is recorded, -32603 isn't).
- **AC4** → `HostConnectorTests` › `reconnectReadsTheTokenAgain` (`[.reconnecting(attempt: 1, reason: nil), connected]`) and › `retriedFailureShowsItsReason`.
- **AC5** → `HostConnectorTests` › `refusedTokenOrVersionStops` (401 and -32005; after 700 ms there is still only one transport) and › `givingUpFailsWithTheLastRecordedFailure` (`.other`, and `.hostUnreachable` when it was recorded).
- **AC6** → `expectNoSecret` runs in all three new connector tests, where the URLError's `NSURLErrorFailingURLErrorKey` is the token URL.

## Tests
- **VIRTKit (`swift test`):** `✔ Test run with 42 tests in 7 suites passed after 1.053 seconds.` (0 failed)
- **App (`xcodebuild test`, iPhone 18 Pro simulator):** 19 test cases passed, 0 failed. `./scripts/test.sh` exited 0.

## Commits
- `9632d9c` feat(virtkit): give actionable connection failures and a reconnecting status (`Refs: #20`)

That's 299 lines added and 20 removed, under the 400-line limit. Nothing is pushed.

**Open points for review:**
- **One recorder for all attempts.** The spec allows one per attempt, but sharing it is what lets the give-up status use the last recorded failure across attempts.
- **Late errors after the client gives up are lost.** If the URLSession error arrives after the client's final failed state, the status stays `.failed(.other)`, because the host is already stopped by then.
- **New public API.** `ConnectionErrorRecorder.record(error:httpStatus:)` and `HostConnector.webSocketTransport` are public, because `TransportMaker` is public.
