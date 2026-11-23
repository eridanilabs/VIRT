# Triage r1

Open findings checked with `board.mjs backlog --json`: only Polish #13, which covers host setup, connection and README findings. Nothing covers this round's findings.

| # | Finding | Reviewer | Decision | Issue | Reason |
|---|---------|----------|----------|-------|--------|
| 1 | [blocker] (ac) VIRT/SessionChatView.swift:17-24: only a drag turns following off; status-bar, VoiceOver and keyboard scrolls leave `followsBottom` true (AC5) | reviewer-ux | new (sub) | #49 | AC5 is in the spec, so it's this run's |
| 2 | [nit] (polish) VIRT/SessionChatView.swift:21: the `old != .animating` guard skips the bottom check after a status-bar scroll | reviewer-code | into #49 | filed after the builder replies | same problem and same fix as #1 |
| 3 | [nit] (polish) VIRT/SessionChatView.swift:73: the chevron replaced the wrench and clashes with `DisclosureChevron` | reviewer-ui-design | group (A, first) | filed after the builder replies | tool call row layout |
| 4 | [nit] (polish) VIRT/SessionChatView.swift:68-80: detail lines align under the icon and use `spacing: 4` | reviewer-ui-design | group (A) | filed after the builder replies | tool call row layout, same place as #3 |
| 5 | [nit] (polish) VIRT/SessionChatView.swift:63-88: a tool call with no details still shows a chevron and toggles to nothing | reviewer-ux | group (A) | filed after the builder replies | tool call row layout, same place as #3 |
| 6 | [nit] (polish) Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift:88: a cancelled tool call shows the raw reason token | reviewer-ux | new | filed after the builder replies | nothing open covers it |
| 7 | [nit] (polish) VIRT/SessionChatView.swift:65-67: expanding the last tool call at the bottom doesn't scroll its details into view | reviewer-ux | new | filed after the builder replies | nothing open covers it |

Nits 2-7 go to the builder to fix if cheap. Fixed ones are filed `--as sub`; declined ones go `--as backlog` into the Polish issue (#13) for the active milestone.
