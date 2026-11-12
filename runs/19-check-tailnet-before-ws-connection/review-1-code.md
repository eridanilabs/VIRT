# Review r1: code (reviewer-code, agent default model)

VERDICT: PASS
## Findings
- [nit] (polish) Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:11: When the doc comment was rewrapped, line 11 was left short ("…no transport, no / retries. The token and the URL that carries"), and the sentence finishes on line 12. Fix: rewrap lines 10–12 so the paragraph flows like the rest of the comment.
- [note] Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift:18: `HostResolver.system` runs `getaddrinfo` with no timeout, and it doesn't stop when the task is cancelled. On a DNS server that never answers, the host stays `.connecting` until the system resolver gives up. This is acceptable for this card, because error and timeout handling belongs to part 3.
- [note] Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift:111: In the app, a `.ts.net` URL is now rewritten to a raw `100.x` or `[fd7a:…]` host, so the `ts.net` exception in the app's App Transport Security settings no longer covers the connection. The spec already lists this as a known gap with a manual test, and the PR should say so.
- [note] Packages/VIRTKit/Tests/VIRTKitTests/TailnetCheckTests.swift:69: The check of the `notOnTailnet` message runs again in each of the 5 parameterized cases. It's harmless.

## Coverage
- Files read: AGENTS.md, spec.md, `.agents/skills/factory/LOOP.md` (Severity), the full `git diff origin/main...HEAD`, HostConnector.swift (whole file), HostURLPolicy.swift (whole file), TailnetCheck.swift, TailnetCheckTests.swift, HostConnectorTests.swift (changed parts and existing URL and sleep checks), README.md (changed section)
- Flows walked:
  - **First connect through `openTransport`.** `HostURLPolicy` runs first, then `TailnetCheck`, then the token is read, then the transport is made. Covered: `wss://` (no providers called), loopback `localhost`, `127.0.0.1` and `[::1]` (no providers called), an IPv4 `100.x` literal (resolver skipped, interfaces checked), a `.ts.net` name (interfaces checked, then the name resolved), and the rewritten host keeping its port and path, with IPv6 in brackets.
  - **Failure path.** These all lead to `stop` with `.notOnTailnet`, no token read, no transport and no retry: no Tailscale interface, a resolver error, an empty result, a mix with an address outside the ranges, an address outside the ranges, and an off-tailnet literal.
  - **Reconnect after a drop.** The check runs again; with the interfaces switched off, the attempt fails and no new transport is made.
  - **Concurrency.** A `disconnect` during the async check is caught by `stop`'s `registrations` guard, which was already there.
  - **Range edges.** I traced `isTailnetAddress` for both ranges by hand: the IPv4 path goes through `isCarrierGradeNAT`, and the IPv6 path compares the 6-byte prefix after `inet_pton`.
  - **`HostConnector(library:)` callers.** The only callers are in tests; the app doesn't use `HostConnector` yet.
- Commands run:
  - `./scripts/test.sh` → passed: 35 tests in 6 suites in VIRTKit, and every VIRTTests case on the iOS simulator.
  - `swift build --build-tests` in Packages/VIRTKit → no warnings or errors under Swift 6 strict concurrency.
