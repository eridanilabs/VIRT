# Build r1: builder-app (claude-opus-5.5)

## Summary
I made four fixes for #53. The two URL refusal messages now tell you what to do next. `HostLibrary.save` can no longer have its warning ignored without a visible `_ =`. `HostConnector` never shows "Connected" with an empty protocol version, and it now closes the connection setup it made for a transport that closes before sending or receiving anything. I also corrected the Tailscale setup and security wording in README.md and AGENTS.md. `./scripts/test.sh` passes with no build warnings.

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift`: new `.missingHost` and `.unsupportedScheme` messages.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift`: the README's example URL is now one accepted row and one refused row in the policy table, each with a one-line comment. I removed the two old README tests and added a test for the exact message text.
- `Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift`: `save(_:token:)` no longer has `@discardableResult`. `update(_:)` keeps it, as the spec says.
- `VIRT/HostFormViewModel.swift`, `VIRTTests/HostsViewModelTests.swift`, `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift`: every `save` call that ignored the warning now uses `_ =`.
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`:
  - On `.connected`, `handle(_:)` now requires a protocol version from `client.host(id)`. With no host, it publishes nothing.
  - `webSocketTransport` now wraps its transport in `SessionEndingTransport`.
  - I rewrapped the class doc comment and updated the `sessionUpdates` comment on both `HostConnecting` and `HostConnector`.
  - So tests can reach them, `client` is now internal, `registrations` is readable outside the class, and `handle(_:)` is internal.
- `Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift`: new internal `SessionEndingTransport` with a `session:` parameter.
  - If it closes before any `send` or `recv`, it closes its `URLSession` itself.
  - A `send` or `recv` after `close` throws `TransportError.closed`.
  - If `close` races the first `send` or `recv`, it still closes the session once the inner transport fails. This is safe because a closed inner transport starts no new connection, and `finishTasksAndInvalidate` lets any started one finish first.
  - After real I/O, `ConnectionErrorRecorder` still closes the session when the connection ends.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift`: added a `failsReads` option to `FakeTokenStore`.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift`: the `connector()` helper takes an optional `tokens:` store. Added helpers `isReconnecting`, `RecorderLog` and `InvalidationProbe`, and six new tests.
- `README.md`, `AGENTS.md`: the AC6 wording.
- I built on what was there: `ConnectionErrorRecorder` and `RecordingTransport` (the new wrapper sits beside them), `FakeTokenStore`, `FakeHosts.maker` and the `next(_:until:)` and `isFailed` test helpers.

Four commits, each with `Refs: #53` and the Copilot co-author trailer:
- `347861f` fix(policy)
- `6eea0f4` fix(library)
- `b2cc329` fix(connector)
- `2034c44` docs(readme)

## AC coverage
- AC1 → `HostURLPolicyTests` › "evaluates" (new rows `wss://machine.tailnet.ts.net:8443` and `("wss://machine.tailnet.ts.net:8443?tkn=x", .query)`), plus "missingHostAndUnsupportedSchemeSayWhatToDo"
- AC2 → the build itself: the full `./scripts/test.sh` run had 0 warnings, and the existing `HostLibraryTests` and `HostsViewModelTests` still pass
- AC3 → `HostConnectorTests`:
  - "connectedWithoutAClientHostPublishesNothing". I checked that this test fails when I put the old line back.
  - "transportClosedBeforeAnyIOEndsItsSession"
  - "transportClosedAfterASendLeavesItsSessionToTheRecorder"
  - "webSocketTransportEndsItsSessionWhenClosedUnused". This one only checks that the wrapper is in place.
- AC4 → doc comments only; needs review
- AC5 → `HostConnectorTests` › "untypedTokenErrorRetriesForever", and "lateRecorderCallStopsOrSetsReason" with a 401 and with `.cannotFindHost`
- AC6 → README.md and AGENTS.md wording only; needs review

## Found, not fixed
none

## Findings (resumed only)
n/a, first build

## Tests
- `swift test` (VIRTKit): 79 tests in 12 suites passed (`✔ Test run with 79 tests in 12 suites passed after 1.132 seconds.`).
- `xcodebuild test` (app, iPhone 18 Pro simulator): 72 test cases passed, 0 failed, 0 warnings.
- `./scripts/test.sh` exited 0.
