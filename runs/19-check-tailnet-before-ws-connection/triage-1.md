# Triage r1

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] HostConnector.swift:11 doc comment left short after rewrap | reviewer-code | polish #13 | #13 | doc polish; active milestone's Polish issue |
| [nit] README.md:67 bullet says the token goes in plain text with Tailscale off, contradicting the new tailnet-check paragraph | reviewer-ux | polish #13 | #13 | README wording; joins the README tailnet-wording items already in #13 |
| [nit] README.md:69 "only while Tailscale is on" overstates the check; sentence skips `100.x` literals | reviewer-ux | group → polish #13 | #13 | same paragraph and fix as the security nit below |
| [nit] README.md:69 "only while Tailscale is on" isn't true: any interface can hold a `100.64.0.0/10` address | reviewer-security | group → polish #13 | #13 | same paragraph and fix as the ux nit above |

`[note]` lines aren't triaged. They stay in the review records. reviewer-security's note on limiting the device check to `utun*` interfaces is a suggestion for a follow-up card, for a person to file.

No blockers, so there's no **Backlog from review** parked list.
