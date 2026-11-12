# Triage r1

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] (tests) HostConnectorTests.swift `retriedFailureShowsItsReason`, `refusedTokenOrVersionStops`: no test drives the late-delegate-callback path through `HostConnector.recorded()` | reviewer-code | polish #13 | #13 | nothing open covers it; round goes to Approve, active milestone's Polish issue |
| [nit] (robustness) HostConnector.swift:19-22, ConnectionErrorRecorder.swift:42: a transport closed before any task never invalidates its per-attempt `URLSession` | reviewer-code | polish #13 | #13 | nothing open covers it; round goes to Approve, active milestone's Polish issue |

`[note]` lines from reviewer-code (3), reviewer-security (4) and reviewer-ux (2) get no triage decision; they stay in the review records.

Backlog from review: the two nits above, into the Polish issue #13. No parked blockers.
