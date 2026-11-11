# Build r1 (claude-opus-5.5)

## Summary
I added `HostConnector` to VIRTKit. It connects to a saved host through the client's `MultiHostClient`. Before every attempt, reconnects included, it reads the host, checks the saved URL against `HostURLPolicy`, and only then reads the token and adds it as the single `tkn` query item. A refused URL, a missing host or a missing token stops the host for good. No status, failure or description ever contains the token or the URL that carries it. `./scripts/test.sh` passes: VIRTKit 26/26 and the app on the iOS simulator 18/18, with 0 failures.

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift` (new):
  - **API:** `public actor HostConnector(library:transportMaker:)`, with `connect`, `disconnect`, `status(for:)` and `statusUpdates(for:)`. `Status` is `.idle`, `.connecting`, `.connected(protocolVersion:)` or `.failed(Failure)`. `Failure` is `.urlRefused`, `.hostNotFound`, `.noToken` or `.other`, and each has a `message`.
  - **Before each attempt:** the transport factory reads the host, then runs the policy, then reads the token. It builds the URL with `tokenURL`, which keeps only unreserved characters as they are, so `+`, `&`, `=` and `%` arrive unchanged.
  - **Reuse:** it builds on `HostLibrary.hosts()`, `HostLibrary.token(for:)`, `HostURLPolicy.evaluate` and `Refusal.message`, and uses `HostConfig`'s default `ahp-root://` subscription.
- `Packages/VIRTKit/Package.swift`: the test target now depends on `AgentHostProtocolClient`, so the tests can use `InMemoryTransport`.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostLibraryTests.swift`: I made the existing `FakeTokenStore` and `TemporaryDefaults` usable from other test files, and `FakeTokenStore` now counts token reads.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift` (new): a fake host on `InMemoryTransport` answers `initialize` and `listSessions` and records the URLs and requests it gets. No network is used.

## AC coverage
- **AC1, AC2** → `connectsWithTheTokenInTkn(url:)`: the URL ends in `?tkn=s3ntinel-a%2Bb%26c%3Dd%25e`, it decodes back to the same token, and `disconnect` returns the status to `.idle`.
- **AC2 (token read again)** → `reconnectReadsTheTokenAgain`: the test drops the transport and changes the token. The next URL has the new token, the store was read twice, and the statuses are `.connecting` then `.connected`.
- **AC3** → `connectsWithTheTokenInTkn(url:)`: the host gets `initialize` on `ahp-root://` with `initialSubscriptions: ["ahp-root://"]`. The statuses go `.idle`, `.connecting`, then `.connected("0.2.0")`. The second case uses a `ws://100.100.1.2` URL, which has a warning and still connects.
- **AC4** → `refusedURLReadsNoTokenAndStops(url:refusal:)`, for an `http://` URL and a `ws://example.com` URL: no token is read, no transport is made, the message matches the policy's, and there is no second attempt. To prove that, the test fixes the saved URL and waits 700 ms.
- **AC5** → `missingHostOrTokenFailsWithoutATransport` (exactly one token read, no transport, no retry) and `clientErrorFailsWithTheFixedMessage` (`.other` with "Couldn't connect to the host.").
- **AC6** → `expectNoSecret`, called from the connect, refusal and client-error tests. It checks `String(describing:)`, `String(reflecting:)`, `dump`, `Mirror` and the failure messages for every status reached. The client-error test throws a `URLError` that contains the token URL, and it doesn't leak.

I also checked that the tests catch a regression: with the no-retry guard and the removal both taken out, the AC4 and AC5 tests fail.

## Tests
```
✔ Suite HostConnectorTests passed after 0.731 seconds.
✔ Test run with 26 tests in 5 suites passed after 0.726 seconds.
Test case 'HostsViewModelTests/deleteRemovesTheHostAndItsToken()' passed on 'Clone 1 of iPhone 18 Pro - VIRT'
Test case 'HostsViewModelTests/savedHostsListByName()' passed on 'Clone 1 of iPhone 18 Pro - VIRT'
./scripts/test.sh exit 0 — VIRTKit 26 passed / 0 failed; app (simulator) 18 passed / 0 failed
```

## Commits
- `bdaadcb` feat(virtkit): connect to a saved host with its token after a URL policy check (`Refs: #18` and the Copilot `Co-authored-by` trailer)

## Assumptions and client API gaps
- **How a failed host stops:** `MultiHostClient` retries when the transport factory throws, and its `remove` waits for the very loop that is calling the factory. So `HostConnector` can't remove the host from inside the factory without deadlocking. Instead it marks the host failed and removes it in a separate `Task`. A guard in the factory also refuses to read anything for a stopped host, so no retry can slip through before the removal finishes.
- **New client id on each `connect`:** every `connect` registers the host with `MultiHostClient` under a fresh id, so leftover events from an earlier connection can't change the new status. The catch is that the client id sent to the host changes after each `disconnect` and `connect`. #21 may want a stable one, which `HostConfig.withClientId` can provide.
- **`.failed(.other)` and retries:** under `ReconnectPolicy.exponential` the client retries for ever, so ordinary client errors show as `.connecting` and only reach `.failed(.other)` if the client gives up. To test that case, `init` has an `internal` `reconnectPolicy` parameter, and the test uses `.disabled`. The public API matches the spec. Stopping retries on specific errors is left to #20.
- **Smaller choices:**
  - The transport maker can throw. The default, `URLSessionWebSocketTransport(url:)`, doesn't.
  - `protocolVersion` falls back to `""` if the client has none, which shouldn't happen after `initialize`.
  - The `HostConfig` label is the host's UUID.
  - `Failure` also conforms to `LocalizedError`, so `localizedDescription` returns its `message`.
- **Size:** 327 code lines, not counting blank and comment lines. Raw insertions, including doc comments, are 404.
- **Not changed:** I left the README alone because the app still doesn't connect: this part makes no app-target changes. Nothing in the spec was left undone.
