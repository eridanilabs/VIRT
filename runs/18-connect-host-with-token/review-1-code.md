# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (correctness) Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:175: if `client.host(id)` returns nil, the status becomes `.connected(protocolVersion: "")`. That reports "connected" with a made-up version. Fix: when the host is gone, skip the publish, since a removed registration has already cleared its status. Alternatively map it to `.failed(.other)`.
- [nit] (tests) Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift:184: `clientErrorFailsWithTheFixedMessage` reaches `.failed(.other)` only with `ReconnectPolicy.disabled`. Under the shipped `.exponential` policy (`maxAttempts: nil`) the client never reaches `.failed`. A throwing transport maker or a Keychain read error is not a `Failure`, so it escapes the `catch` in `openTransport`, and the host stays `.connecting` and retries forever. This is in line with the Out of scope list, because #20 owns stopping retries on typed failures. Fix: pin that behaviour in the test or the PR description so it doesn't surprise #20.
- [note] HostConnectorTests.swift:161, :177: the "no further attempt" checks sleep for 700 ms, which covers about two 250 ms backoff steps. They are negative checks, so they can only miss a bug, not flake. I ran `HostConnectorTests` five times and it passed every time.
- [note] HostConnector.swift:67: `deinit` starts a `Task` that calls `client.shutdown()`. This is fine, because the config closure holds `self` weakly.

## Coverage
- Files read: AGENTS.md, spec.md, Packages/VIRTKit/Package.swift diff, HostConnector.swift (full), HostConnectorTests.swift (full), HostLibraryTests.swift diff, and the client's ReconnectPolicy.swift and MultiHostClient.swift (`add`, `remove`)
- Flows walked:
  - connect → connecting → connected with the version, and `disconnect`.
  - Reconnect after the server closes, with the token re-read.
  - A refused URL (`http://`, public `ws://`) → `.failed(.urlRefused)` with no token read and no transport maker call.
  - Missing host and missing token → failed with no transport and no retry.
  - A transport maker error → `.failed(.other)`.
  - A `disconnect` racing `connect`: the registration check after the `await` and the removal if the registration changed during `add`.
  - The stale-event filter on `registrations`.
  - A warning URL (`ws://100.x`) still connects.
  - The token is percent-encoded (`+`, `&`, `=`, `%`).
  - The token and token URL stay out of every `Status`, description and mirror (checked by `expectNoSecret`).
- Commands run:
  - `swift test` in Packages/VIRTKit → 26 tests in 5 suites passed.
  - `swift test --filter HostConnectorTests`, five times → passed every time.
  - I did not run `./scripts/test.sh`, so the simulator half is unchecked. The change is package-only, with no app-target changes.
- Earlier blockers: none (round 1)
