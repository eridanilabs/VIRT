# Triage r1 for #18

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] HostConnector.swift:175: a nil `client.host(id)` publishes `.connected(protocolVersion: "")` | reviewer-code | polish #13 | #13 | No open issue covers it. The round goes to Approve, so it is filed as a backlog nit in the active milestone's Polish issue. |
| [nit] HostConnectorTests.swift:184: `.failed(.other)` is reached only with `ReconnectPolicy.disabled`; under `.exponential`, a throwing maker or a Keychain read error retries for ever | reviewer-code | into #20 | #20 | #20 (Backlog, open after this PR merges) owns stopping retries on typed failures. The reviewer's fix is to keep this in view for #20. |

No blockers this round. The `[note]` lines from code, ops and security stay in their review records. They get no triage decision.
