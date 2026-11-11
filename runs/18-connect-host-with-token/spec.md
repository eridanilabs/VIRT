# Spec: Connect to a saved host with its token after a URL policy check

## Goal
VIRTKit can connect to a saved host. The URL policy runs again before every attempt, and the token is added only after the URL passes. The caller sees "connecting", then "connected" with the host's protocol version, or a failure with a safe message. This is part 1 of #4. Parts 2–4 (#19, #20, #21) build on it.

## Acceptance criteria
- AC1: A new `public actor HostConnector(library:transportMaker:)` wraps the client's `MultiHostClient`. The transport maker defaults to `URLSessionWebSocketTransport(url:)`. `connect(hostID)` adds a `HostConfig` with the default `ahp-root://` root subscription and `ReconnectPolicy.exponential`. `disconnect(hostID)` removes it. `status(for:)` and `statusUpdates(for:) -> AsyncStream<Status>` report the status. `Status` is `.idle`, `.connecting`, `.connected(protocolVersion:)` or `.failed(Failure)`. Parts 3 and 4 add cases, and part 2 adds a step before the connect.
- AC2: On every attempt, including reconnects, the `transportFactory` reads the host and its token from `HostLibrary`. It then calls the transport maker with the saved URL plus one `tkn=<token>` query item. The token is percent-encoded, so `+`, `&`, `=` and `%` arrive unchanged.
- AC3: When the host answers `initialize` on `ahp-root://`, the status becomes `.connected(protocolVersion:)` with the host's version. While `MultiHostClient` connects or reconnects, the status is `.connecting`.
- AC4: Before every attempt, `HostURLPolicy.evaluate` runs on the saved URL. If the policy refuses the URL, VIRTKit reads no token, calls no transport maker and makes no further attempts. The status becomes `.failed(.urlRefused(refusal))`, and its message is `refusal.message`. An accepted URL with a warning still connects.
- AC5: A missing host fails with `.failed(.hostNotFound)`. A missing token fails with `.failed(.noToken)`. Neither one calls the transport maker or retries. Any other client error becomes `.failed(.other)` with the fixed message "Couldn't connect to the host." VIRTKit never passes on `lastError` or `failed(reason:)` strings.
- AC6: No `Status`, `Failure`, message, `description`, `debugDescription`, mirror or log line from VIRTKit contains the token or the URL that carries it.

## Out of scope
- The tailnet check before `ws://` (#19).
- Typed failure reasons (401/403, TLS, ATS, version mismatch), `.reconnecting(attempt:)`, and stopping retries on those failures (#20).
- Hosts screen status, tap to connect and app lifecycle (#21). This part has no app-target changes.
- Sessions and subscriptions beyond `ahp-root://`.

## Assumptions
- Each `Status` value applies to one host. One connector can hold several hosts, but #21 decides how many connect at once.
- `MultiHostClient` 1.0.0 retries when the transport factory throws. To stop retries after a refusal, a missing host or a missing token, `HostConnector` removes the host from `MultiHostClient`.
- The saved URL has no query, because the policy refuses one. So `tkn` is always the only query item.
- The tests save a refused URL by calling `HostStore.save` directly, because `HostLibrary.save` checks the policy.
- The test target must add the `AgentHostProtocolClient` product to `Package.swift` so the tests can use `InMemoryTransport`.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift` (new): the actor, `Status`, `Failure`, the token URL builder and the check before each attempt.
- `Packages/VIRTKit/Package.swift`: the test target's dependency on `AgentHostProtocolClient`.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift` (new): the tests.

## Test plan
In `HostConnectorTests.swift`, an `InMemoryTransport` pair plays the host, with no network:
- AC1, AC2: the transport maker gets the saved URL with `tkn=a+b&c=d%e`, and the encoded value decodes back to the same token.
- AC3: the host gets `initialize` on `ahp-root://`, and the status reaches `.connected` with the host's version.
- AC2 (re-read): the test drops the transport and changes the stored token. The next attempt's URL has the new token, and the store has been read twice.
- AC4: for a saved `http://` URL and a saved `ws://` URL to a public host, a counting token store and transport maker see zero calls. The status is `.failed(.urlRefused(...))` with the policy's message, and no second attempt happens.
- AC5: a missing host or token gives the matching failure with no transport. A thrown client error gives `.other`'s fixed message.
- AC6: the test sets a sentinel token and checks `String(describing:)`, `String(reflecting:)` and `Mirror` for every status reached. None of them contains the sentinel or the token URL.

## Size estimate
Estimate: 300 code lines
- Connect through `MultiHostClient`, with the token in `tkn` read on each attempt, and report connected with the version
- Check the URL policy before each attempt, and stop on a refusal
- Keep the token and token URL out of every status, description and log
