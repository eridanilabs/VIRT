# Spec: Connect to a saved host and show its connection state

## Goal
When you tap a saved host, VIRT connects to it over AHP and shows whether that worked: connecting, connected (with the protocol version), reconnecting, or failed with a reason you can act on. The token is sent only after VIRT checks that it's safe to send.

## Acceptance criteria
- AC1: A new `HostConnector` actor in VIRTKit uses a `MultiHostClient`. For each host it adds a `HostConfig` with the default `[RootResourceURI]` (`ahp-root://`) subscriptions and `ReconnectPolicy.exponential`. Its `transportFactory` reads the token from `HostLibrary` on every attempt and opens an injected transport maker (default `URLSessionWebSocketTransport(url:)`) on the saved URL plus `tkn=<token>`. The token is percent-encoded, so `+ & = %` survive. When the host replies to `initialize`, the status is `.connected(protocolVersion:)`.
- AC2: Before every attempt, including reconnects, `HostURLPolicy.evaluate` runs on the saved URL. If the URL is refused, no token is read, no transport is made, the status becomes `.failed(.urlRefused(refusal))` showing `refusal.message`, and VIRT doesn't retry.
- AC3: For `ws://` to a host that isn't loopback, VIRT connects only if two things hold: the IP literal, or every address from an injected `HostResolver`, is in `100.64.0.0/10` or `fd7a:115c:a1e0::/48`; and an injected `LocalInterfaces` provider (`getifaddrs`) reports a Tailscale address on this device. Otherwise the status is `.failed(.notOnTailnet)`, with the message "This address isn't on your tailnet. Is Tailscale on?", and no transport is made. When the check passes, the transport URL's host is the checked address (IPv6 in brackets), with the same port and path. `wss://` and loopback URLs never call the resolver.
- AC4: Failures map to short messages. HTTP 401 or 403 on the upgrade means `.tokenRefused`. URLError cannot-find or cannot-connect host, timed out, not connected, or connection lost means `.unreachable`. Secure-connection and certificate URLErrors mean `.tls`. A JSON-RPC error with `AhpErrorCodes.unsupportedProtocolVersion` (-32005) means `.versionMismatch`. URLError -1022 (blocked by App Transport Security, ATS) means `.blockedByATS`. Anything else is `.other`. A URLSession task delegate records the typed error, because `MultiHostClient` 1.0.0 turns errors into strings.
- AC5: A dropped connection shows `.reconnecting(attempt:)` and then `.connected` again. Each reconnect runs AC2 and AC3 again and reads the token again. `.tokenRefused` and `.versionMismatch` stop retrying.
- AC6: No status, message, `description` or log line from VIRTKit contains the token or the URL that carries it. VIRT never shows `HostHandle.lastError` or `HostState.failed(reason:)`.
- AC7: Tapping a host on the Hosts screen connects it and disconnects any other host. Its row shows "Connecting…", "Connected · protocol <v>", "Reconnecting (attempt n)…" or "Failed: <message>". Edit moves to a swipe action.
- AC8: When the scene goes to the background, VIRT disconnects. When it becomes active again, VIRT reconnects the host that was connected.
- AC9: Manual test: connecting works against `ws://127.0.0.1:48765` and `ws://gallifrey.tail537c2.ts.net:48765`. The PR records whether ATS allows `ws://` to a raw IP.

## Out of scope
- Sessions, subscriptions beyond root, and connecting to several hosts at once.
- Any change to the Info.plist ATS settings, including `NSAllowsArbitraryLoads`.
- A manual retry button. Tapping the host again retries.

## Assumptions
- Only one host is connected at a time. VIRT doesn't retry a failure on its own after a check before connecting fails (AC2, AC3).
- Token refusal shows up as HTTP 401 or 403 on the upgrade, as I expect from `code agent host`. The manual test confirms this.
- ATS: `NSExceptionDomains` can't hold IP ranges. I expect iOS to exempt IP-literal hosts from ATS. If it blocks them, use the client's `NWConnectionWebSocketTransport` for checked `ws://` addresses. Network.framework doesn't apply ATS, so this needs no plist change.
- Remaining gaps:
  - `URLSessionWebSocketTransport` keeps the URL with the token until the connection closes.
  - The route to a checked `100.x` address can still change between the check and the connect.
  - Connecting by IP sends `Host: <ip>`. The test against gallifrey confirms the host accepts it.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift`: `MultiHostClient` wrapper, token URL, URL policy check (new)
- `Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift`: resolver, interfaces, address ranges (new)
- `Packages/VIRTKit/Sources/VIRTKit/ConnectionStatus.swift`: status, failure cases, error mapping, delegate (new)
- `VIRT/HostsViewModel.swift`, `VIRT/HostsView.swift`, `VIRT/VIRTApp.swift`: row status, tap to connect, `scenePhase`
- `README.md`: how to connect

## Test plan
- AC1, AC5, AC6 → `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift`: an `InMemoryTransport` pair plays the host. Tests assert `tkn` in the URL, `initialize` on `ahp-root://`, the version in the status, a token re-read after a drop, and no sentinel token in any description.
- AC2 → same file: a refused saved URL never calls the transport maker or the token store.
- AC3 → `TailnetCheckTests.swift`: with a fake resolver and fake interfaces, a non-tailnet address or no Tailscale interface stops before any transport is made; with a passing check, the URL host is the checked IP; `wss://` and loopback skip the resolver.
- AC4 → `ConnectionStatusTests.swift`: each URLError, HTTP status and -32005 maps to the right case and message.
- AC7, AC8 → `VIRTTests/HostsViewModelTests.swift`: a fake connector drives the row text, the tap and the background/foreground changes.

## Size estimate
Estimate: 790 code lines
- Connect through `MultiHostClient` with the token in `tkn`, read on each attempt
- Check the URL policy again before each attempt
- Check the tailnet before connecting with `ws://`
- Map failures to actionable reasons, including the reconnecting state
- Show the status on the Hosts screen; tap connects
- Disconnect in the background, reconnect in the foreground

## Proposed split
- Part 1: Connect with the token and check the URL policy again: behaviours 1–2; AC1, AC2, AC6, and the token re-read in AC5; about 230 code lines
- Part 2: Tailnet check before connecting: behaviour 3; AC3; about 190 code lines
- Part 3: Failure reasons and reconnect state: behaviour 4; AC4 and the rest of AC5; about 210 code lines
- Part 4: Hosts screen status and app lifecycle: behaviours 5–6; AC7, AC8, AC9; about 160 code lines
