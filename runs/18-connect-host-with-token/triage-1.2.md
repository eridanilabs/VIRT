# Triage r1 for #18 (corrected)

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] HostConnector.swift:175: a nil `client.host(id)` publishes `.connected(protocolVersion: "")` | reviewer-code | polish #13 | #13 | No open issue covers it. The round goes to Approve, so it is filed as a backlog nit in the active milestone's Polish issue. |
| [nit] HostConnectorTests.swift:184: `.failed(.other)` is reached only with `ReconnectPolicy.disabled`; under `.exponential`, a throwing maker or a Keychain read error retries for ever | reviewer-code | polish #13 | #13 | First triaged `into #20`, the part that owns stopping retries on typed failures. `finding --into` refused, because #20 has no `from-review` label. So it is filed in the active milestone's Polish issue instead, and #20's builder should see it there. |

No blockers this round. The `[note]` lines from code, ops and security stay in their review records. They get no triage decision.
