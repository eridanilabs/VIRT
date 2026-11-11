# Triage r1

All five selected reviews passed with no `[blocker]`. Every `[nit]` is filed `--as backlog`; milestone "0: Connect to a guppi host" is active, so each goes into its Polish issue.

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| HostURLPolicy.swift:53 `missingHost` message gives no next step | reviewer-ux | polish | polish | |
| HostURLPolicy.swift:51 `unsupportedScheme` wording and loopback name | reviewer-ux | polish | polish | |
| README.md:60-64 loopback vs tailnet listening reads as a contradiction | reviewer-ux | polish | polish | |
| AGENTS.md:54 WireGuard sentence needs "while Tailscale is on"; #4 should check the peer is a Tailscale address | reviewer-security | polish | polish | |
| HostLibrary.swift:26 drop `@discardableResult` so the CGNAT warning isn't silently dropped | reviewer-security | polish | polish | |

**Backlog from review:** no parked blockers.
