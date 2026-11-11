# Spec: Check the tailnet before a ws:// connection

## Goal
When a saved host uses plain `ws://` to a tailnet name or a `100.x` address, VIRT sends the token only if that address really is on your tailnet and Tailscale is on. If it isn't, you see "This address isn't on your tailnet. Is Tailscale on?" and the token isn't sent.

## Acceptance criteria
- AC1: `HostConnector` takes two new injected providers. `HostResolver` (async; the default uses `getaddrinfo`) returns a host's addresses. `LocalInterfaces` (the default uses `getifaddrs`) returns this device's addresses. The new parameters have defaults, so `HostConnector(library:)` keeps working.
- AC2: On every attempt, the tailnet check runs after `HostURLPolicy` passes and before the token is read. It runs for a `ws://` URL whose host isn't loopback. The check passes only if both of these are true: (a) the IPv4 literal, or every address the resolver returns (at least one), is in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`; (b) `LocalInterfaces` reports at least one address in those ranges.
- AC3: If the check fails, or the resolver throws, the status is `.failed(.notOnTailnet)` and its message is "This address isn't on your tailnet. Is Tailscale on?". No token is read, no transport is made and nothing retries. This uses the existing `stop` path.
- AC4: If the check passes, the transport URL keeps the scheme, port and path, but its host is the checked address: the literal itself, or the first address the resolver returned. An IPv6 address goes in brackets. `tkn` is added after that, as it is today.
- AC5: A `wss://` URL, or a loopback URL (`localhost`, `127.0.0.1`, `::1`), never calls the resolver or `LocalInterfaces`, and its URL isn't rewritten.
- AC6: The check runs again on every reconnect. If Tailscale goes off after a drop, the next attempt fails with `.notOnTailnet` and makes no transport.

## Out of scope
- Mapping errors to reasons (unreachable, TLS, ATS) and the reconnecting state. That is part 3.
- The Hosts screen and app lifecycle. That is part 4.
- Changes to `HostURLPolicy`. A `ws://` IPv6 literal is still refused there.
- Any Info.plist or ATS change, including `NSAllowsArbitraryLoads`.

## Assumptions
- A resolver error or an empty result counts as `.notOnTailnet`. A `.ts.net` name that doesn't resolve usually means MagicDNS is off because Tailscale is off.
- Any device address in either range counts as a Tailscale address. The check doesn't look at interface names.
- The `.carrierGradeNAT` warning from `HostURLPolicy` stays as it is.
- Existing tests that connect with `ws://100.x` must inject fake interfaces that report a Tailscale address.
- Known gaps to note in the PR:
  - The route to a checked address can still change between the check and the connect.
  - Connecting by IP sends `Host: <ip>`. A manual test against gallifrey confirms that the host accepts it.
  - The `ts.net` ATS exception doesn't cover raw IPs. A manual test records whether ATS allows `ws://` to the IP. If it doesn't, the default transport maker uses the client's `NWConnectionWebSocketTransport` for checked addresses.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift` (new): `HostResolver`, `LocalInterfaces`, the default `getaddrinfo` and `getifaddrs` providers, the range checks and the host rewrite.
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: the new `init` parameters, the `.notOnTailnet` failure, and the check in `openTransport`.
- `Packages/VIRTKit/Tests/VIRTKitTests/TailnetCheckTests.swift` (new), `HostConnectorTests.swift`

## Test plan
- AC2, AC3 → `TailnetCheckTests.swift`: these cases use a fake resolver and fake interfaces, with no network. A resolved address outside the ranges, a mix of tailnet and other addresses, an empty result, a resolver that throws, or no Tailscale interface each lead to `.failed(.notOnTailnet)`. In each case the transport maker is never called and the token is never read. Range edges are tested too: `100.63.255.255` and `100.128.0.0` fail; `100.64.0.0`, `100.127.255.255` and `fd7a:115c:a1e0::1` pass.
- AC4 → same file: for an IPv4 result, the transport URL is `ws://100.101.2.3:48765/ahp?tkn=…`. For an IPv6 result, the host is `[fd7a:115c:a1e0::1]` with the same port and path.
- AC5 → same file: for `wss://` and loopback URLs, the call counters on the resolver and interfaces stay at 0.
- AC1, AC6 → `HostConnectorTests.swift`: after a drop, the fake interfaces are switched off. The next attempt fails with `.notOnTailnet` and the transport-maker count doesn't grow.

## Size estimate
Estimate: 190 code lines
- Check the tailnet before connecting with `ws://`
