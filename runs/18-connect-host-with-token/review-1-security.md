# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:120-127: The check that the connection is still registered runs only once, at the start of `openTransport`. The code then waits twice before calling `transportMaker`: once to read the host and once to read the token. If `disconnect` lands during either wait, one transport still opens to that host's URL, with the token in it. The URL has already passed `HostURLPolicy` and the `MultiHostClient.remove` that follows tears the transport down, so this doesn't break the policy or leak the token anywhere new. Checking the registration again just before `transportMaker` would close the gap.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:123-127: The host and its token come from two separate `HostLibrary` calls. Suppose `HostLibrary.save` replaces both the URL and the token between those two calls. Then the new token goes once to the old URL. The old URL passed the policy and is one the user saved, so the exposure is small. Fixing it would need an atomic host-plus-token read in `HostLibrary`.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:175: The host sends `protocolVersion` and it goes into `Status.connected` unchecked, as a free string. It's untrusted input. Part #21 should show it as plain text and never as markup, which matches AGENTS.md. No action is needed in this PR.

## Coverage
- Files read: AGENTS.md, spec.md, Packages/VIRTKit/Package.swift (diff), Sources/VIRTKit/HostConnector.swift (full), Sources/VIRTKit/HostURLPolicy.swift, Sources/VIRTKit/HostLibrary.swift, Tests/VIRTKitTests/HostConnectorTests.swift, Tests/VIRTKitTests/HostLibraryTests.swift (diff). From the pinned AHP client 1.0.0 (5f16d81): HostConfig.swift, MultiHostClient.swift (init/add/remove/shutdown), HostRuntime.swift (supervisor loop, connectOnce), URLSessionWebSocketTransport.swift, plus a grep of every `print`/log call in the client.
- Flows walked:
  - **Connect:** connect → transportFactory → host lookup → policy → token → `tokenURL` → transport. The URL that passes the policy is the same one that carries the token, so nothing can change between the check and the use.
  - **Reconnect:** the supervisor calls `transportFactory` on every attempt, so the policy runs again and the token is read again each time.
  - **Refused URL, missing host, missing token:** `stop` removes the host from `MultiHostClient`, so there are no retries. No token is read for a refused URL.
  - **Client failure:** `lastError` and `failed(reason:)` are dropped. That matters because `String(describing: URLError)` can contain the token URL. It stays only inside the private `MultiHostClient`, and the client never prints it.
  - **Token encoding:** only RFC 3986 unreserved characters pass through unencoded. A token can't inject a second query item, and since the policy refuses URLs with a query or fragment, `tkn` is always the only query item.
  - **AC6:** checked the `Status` and `Failure` cases, `message`, `LocalizedError`, the `HostConfig` label (the host's UUID only) and `MultiHostClient`'s default `InMemoryClientIdStore`, which writes nothing to disk.
  - **Supply chain:** the only package change adds the already-pinned `AgentHostProtocolClient` product to the test target. `Package.resolved` is unchanged. There are no app-target, ATS or workflow changes.
- Commands run:
  - `git log` / `git diff --stat` / `git diff origin/main...HEAD` → 4 files changed
  - `./scripts/test.sh` → passed: 26 tests in 5 suites in `swift test`, and the `xcodebuild` VIRT tests on the iPhone simulator
