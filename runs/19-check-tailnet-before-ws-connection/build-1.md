# Build r1 (builder-app · claude-opus-5.5)

## Summary
Before a saved host on plain `ws://` (not loopback) gets its token, `HostConnector` now checks that the host's address is on your tailnet and that this device has a Tailscale address. If both hold, it connects to the checked IP instead of the name. If either fails, or the name doesn't resolve, the status becomes `.failed(.notOnTailnet)` with the message "This address isn't on your tailnet. Is Tailscale on?", and the token is never read. The check runs again on every reconnect. `./scripts/test.sh` passes.

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift` (new):
  - `HostResolver` (async; `.system` calls `getaddrinfo` on a background queue so it doesn't block the actor) and `LocalInterfaces` (`.system` uses `getifaddrs` and counts only interfaces that are up). Both take a closure, so tests can pass fakes.
  - `TailnetCheck.connectURL(for:)` leaves `wss://` and loopback URLs alone. For other `ws://` URLs it runs the check and puts the checked address in as the host, with brackets for IPv6.
  - `TailnetCheck.isTailnetAddress` tests for `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
- `HostConnector.swift`:
  - The public `init` takes `resolver:` and `interfaces:`, both defaulting to `.system`, so `HostConnector(library:)` still works. The internal test `init` takes them too.
  - New case `Failure.notOnTailnet` with its message.
  - In `openTransport`, the check sits between `HostURLPolicy` and the token read. A failure goes through the existing `stop` path.
- `HostURLPolicy.swift`: no behaviour change. I moved its host cleanup (lowercase, strip IPv6 brackets) into `normalizedHost(_:)` so the check can use it. The check also reuses the existing `loopbackHosts`, `ipv4Octets` and `isCarrierGradeNAT`.
- `HostConnectorTests.swift`: `FakeHosts`, `next` and `isFailed` are now shared with the new test file. The connector helper uses fake tailnet providers, so the existing `ws://100.100.1.2` test doesn't depend on whether Tailscale is on on this Mac. Two tests added: `reconnectChecksTheTailnetAgain` and `defaultInitStillWorks`.
- `TailnetCheckTests.swift` (new): `FakeTailnet` (a fake resolver and fake interfaces with call counters) plus the tests listed below.
- `README.md`: a paragraph on the tailnet check under "Connecting to a host".

## AC coverage
- AC1 → `HostConnectorTests` › `defaultInitStillWorks`. Every connector test now injects `resolver:`/`interfaces:`, and `TailnetCheckTests` › `systemProvidersReportLoopback` runs the real `getaddrinfo`/`getifaddrs` providers without any network.
- AC2 → `TailnetCheckTests` › `offTheTailnetFailsWithoutTokenOrTransport` (5 cases: address outside the ranges, a mix, an empty result, a resolver error, no Tailscale interface), `offTheTailnetLiteralFails`, and `tailnetRanges` (11 cases, including all the edge addresses the spec lists, scoped IPv6 and IPv4-mapped).
- AC3 → `offTheTailnetFailsWithoutTokenOrTransport`: checks the message, that no token is read, that no transport is made, and that nothing retries after 700 ms even with Tailscale turned back on.
- AC4 → `connectsToTheCheckedAddress` (gives `ws://100.101.2.3:48765/ahp?tkn=tok` and `ws://[fd7a:115c:a1e0::1]:48765/ahp?tkn=tok`, using the first address the resolver returns), `connectsToALiteralWithoutResolving`, and the existing `connectsWithTheTokenInTkn`.
- AC5 → `wssAndLoopbackSkipTheCheck` (5 URLs: the resolver and interfaces are each called 0 times, and the URL is unchanged).
- AC6 → `HostConnectorTests` › `reconnectChecksTheTailnetAgain` (after a drop the interfaces are switched off, the attempt fails with `.notOnTailnet`, and the transport and token-read counts stay at 1).

## Tests
- `swift test` (VIRTKit): 35 tests in 6 suites pass, with no compiler warnings.
- `xcodebuild test` (VIRT scheme, iPhone 18 Pro simulator): all `HostsViewModelTests` pass; the script exits 0.

```
✔ Test reconnectChecksTheTailnetAgain() passed after 0.972 seconds.
✔ Suite HostConnectorTests passed after 0.972 seconds.
✔ Test run with 35 tests in 6 suites passed after 0.972 seconds.
Test case 'HostsViewModelTests/deleteRemovesTheHostAndItsToken()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (89288)' (0.035 seconds)
EXIT=0
```

## Commits
- `d0f0304 feat(virtkit): check the tailnet before a ws:// connection` (footer `Refs: #19`). Not pushed.

## Known gaps for the PR (from the spec)
- The route to a checked address can still change between the check and the connect.
- Connecting by IP sends `Host: <ip>`. This still needs a manual test against gallifrey to confirm the host accepts it.
- The `ts.net` ATS exception doesn't cover raw IPs. A manual test still needs to show whether ATS allows `ws://` to the checked IP. If it doesn't, the default transport maker should use the client's `NWConnectionWebSocketTransport` for checked addresses; I haven't made that change.
- The check passes if any device address is in a Tailscale range; it doesn't look at interface names, as the spec says. I also skip interfaces that are down, which the spec doesn't mention.
