# Triage r1 for #53

Base: c6f267ba04a320b57d9e1a35b22db7f5d72e4836. All four selected reviews PASS. No blockers. `[note]` lines get no decision.

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] HostConnectorTests.swift:409: the 200 ms `Task.sleep` in `connectedWithoutAClientHostPublishesNothing` does nothing | reviewer-code | polish #13 | #13 | nothing else open covers it; the milestone is active |
| [nit] HostConnectorTests.swift:442: `webSocketTransportEndsItsSessionWhenClosedUnused` doesn't check that the session ends | reviewer-code | polish #13 | #13 | nothing else open covers it |
| [nit] TailnetCheck.swift:82: the doc comment says the check confirms a host "really is on the tailnet" | reviewer-security | polish #13 | #13 | already on origin/main; nothing else open covers the doc comment |
| [nit] README.md:137: the refused-token recovery step leaves out tapping **Save** | reviewer-ux | polish #13 | #13 | nothing else open covers it |
| [nit] README.md:78: the parenthetical splits "a Tailscale range" from the ranges it names | reviewer-ux | polish #13 | #13 | nothing else open covers it |

No blockers were parked, so there's no **Backlog from review** section for blockers.
