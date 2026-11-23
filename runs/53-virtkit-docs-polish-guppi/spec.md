# Spec r1: writer-spec (claude-opus-5.5)

# Spec: VIRTKit and docs polish for connecting to a guppi host

## Goal
Someone adding a guppi host gets refusal messages that say what to do next, never sees "Connected" with a blank protocol version, and reads accurate Tailscale setup and security steps in README.md and AGENTS.md.

## Acceptance criteria
- AC1: In `HostURLPolicy.Refusal.message`, `.missingHost` returns "The URL has no host. Add one, for example wss://my-host.example.com." and `.unsupportedScheme` returns "VIRT connects over wss:// (or ws:// to localhost, a .ts.net name or a Tailscale address), not this scheme." In `HostURLPolicyTests`, `wss://machine.tailnet.ts.net:8443` is in `accepted` and `("wss://machine.tailnet.ts.net:8443?tkn=x", .query)` is in `refused`. Each has a one-line comment saying it guards the README's example URL. `acceptsTheREADMETailscaleServeURL` and `refusesTheREADMETailscaleServeURLWithATokenQuery` are removed.
- AC2: `HostLibrary.save(_:token:)` no longer has `@discardableResult`. Every caller handles the returned `Warning?` or discards it with `_ =`. That covers `VIRT/HostFormViewModel.swift` (both calls), `HostLibraryTests` and `HostsViewModelTests`. The build has no unused-result warnings.
- AC3: In `HostConnector.handle(_:)`, a `.connected` event whose `client.host(id)` is nil publishes no status, so `.connected(protocolVersion: "")` is never published. A transport from `HostConnector.webSocketTransport` that is closed before any `send` or `recv` invalidates its `URLSession`. After a `send` or `recv`, `ConnectionErrorRecorder` still ends the session when the task completes.
- AC4: The `HostConnector` class doc comment is rewrapped so the paragraph flows, with the same content. The `sessionUpdates` doc comment, on both `HostConnecting` and `HostConnector`, says: "`[]` until the host first lists its sessions, and again after disconnect or a failure that stops it. While the host is reconnecting, the last rows stay."
- AC5: `HostConnectorTests` has two new tests. (a) Under `.exponential`, a token read that throws a non-`Failure` error keeps the host at `.reconnecting(attempt:, reason: nil)` while the attempt count rises (at least 1, then 2), and it never reaches `.failed`. (b) A maker records from a `Task` after the host is `.reconnecting`. A 401 then gives `.failed(.tokenRefused)`, and `URLError(.cannotFindHost)` gives `.reconnecting(attempt:, reason: .hostUnreachable)`.
- AC6: README.md and AGENTS.md change:
  - The WireGuard sentence in both docs says "while Tailscale is on".
  - The `ws://` tailnet-name bullet says "a host published on its tailnet" and no longer says it listens on its tailnet address.
  - The `100.x` bullet says VIRT checks Tailscale first, but the `.ts.net` name is still preferred.
  - The check paragraph says what the check really proves: "an address in a Tailscale range (usually only while Tailscale is on)", "resolve only to Tailscale addresses, or the address must be one", and that a network that uses `100.64.0.0/10` itself can still pass.
  - "In VIRT" adds "Enter a name, for example `Studio`."
  - Step 4 describes the host's screen (its status line, then its sessions), then the row back on **Hosts**.
  - A new sentence says tailnet ACLs decide who can reach the served port, and the token is the only other guard.
  - "If it doesn't connect" notes that the served name appears in Certificate Transparency logs, and covers a refused token.
  - The clipboard step also says to clear any clipboard-history app.

## Out of scope
- `HostLibrary.update(_:)` keeps `@discardableResult`.
- Any other change to policy, reconnect or tailnet-check behaviour, or to app UI.

## Assumptions
- `HostFormViewModel` discards the warning with `_ =`, because the form already shows `urlWarning` before you save.
- `URLSessionWebSocketTransport` starts its task only on the first `send` or `recv`. A small internal wrapper with a `session` parameter does the invalidation, so a test can use an `InMemoryTransport` and a probe delegate in place of a real socket.
- Testing the nil `client.host(id)` case reliably may need a small internal test hook. If not, a connect then immediate disconnect, repeated, must never yield `.connected(protocolVersion: "")`.
- There is no `docs/board-reads.md`, so no consumers are listed. This isn't a triggering change.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift`: the two messages.
- `Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift`: drop `@discardableResult`.
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: the `.connected` guard, the session-closing wrapper, doc comments.
- `VIRT/HostFormViewModel.swift`: `_ =` on both `save` calls.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift`, `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift`, `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift`, `VIRTTests/HostsViewModelTests.swift`: the tests; add a `failsReads` option to `FakeTokenStore`.
- `README.md`, `AGENTS.md`: the wording.

## Test plan
- AC1 → `HostURLPolicyTests`: the table rows pass. `.missingHost.message` and `.unsupportedScheme.message` equal the new strings.
- AC2 → `./scripts/test.sh` builds with no unused-result warnings, and the existing `HostLibraryTests` still pass.
- AC3 → `HostConnectorTests`: closing the wrapper before any I/O fires the probe's `didBecomeInvalidWithError`, and closing after a `send` doesn't. No published status is `.connected(protocolVersion: "")`.
- AC5 → `HostConnectorTests`: `untypedTokenErrorRetriesForever` and `lateRecorderCallStopsOrSetsReason` (with arguments 401 and `.cannotFindHost`).
- AC4, AC6 → review only (doc comments and markdown).

## Size estimate
Estimate: 70 code lines
- Refusal messages give the next step; README URLs move into the policy table
- `HostLibrary.save` result can't be dropped silently
- `HostConnector` drops `.connected` with no host, and invalidates an unused session
- `HostConnector` doc comments are accurate; new tests for untyped errors and late recorder calls
- README.md and AGENTS.md Tailscale wording is accurate
