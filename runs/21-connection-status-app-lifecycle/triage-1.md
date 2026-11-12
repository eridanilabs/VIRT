# Triage r1

| # | Finding | Reviewer | Decision | Issue | Reason |
|---|---------|----------|----------|-------|--------|
| 1 | [blocker] (ac), was [nit] (polish), VIRT/HostsViewModel.swift:90-100: `select(_:)` clears `selectedHostID` before awaiting `disconnect`, so a tap during that await leaves two hosts connected | reviewer-security | new (sub) | #30 | upgraded: (ac) AC7 "Only one host is connected at a time" fails when a tap lands during the previous host's disconnect; a hidden authenticated connection stays open and survives backgrounding. Confirmed by reading `select(_:)`. |
| 2 | [nit] (polish) VIRT/HostsView.swift:21, HostsViewModel.swift:82: host-sent `protocolVersion` shown unbounded; add a pattern check and `.lineLimit(1)` | reviewer-security | new; sent to builder | after builder reply | |
| 3 | [nit] (a11y-contrast) VIRT/HostsView.swift:23: red `.caption` failure text is about 3.6:1 in light mode | reviewer-ui-design | group (with 4); sent to builder | after builder reply | Same row styling in HostsView. If declined: polish #13, which already holds a similar contrast finding. |
| 4 | [nit] (consistency) VIRT/HostsView.swift:36: fixed `.tint(.blue)` on the Edit swipe action | reviewer-ui-design | group (with 3); sent to builder | after builder reply | |
| 5 | [nit] (polish) VIRT/HostsView.swift:20-26: status changes aren't announced to VoiceOver | reviewer-ux | new; sent to builder | after builder reply | |
| 6 | [nit] (polish) README.md:62: omits "reconnecting" from the no-op tap list | reviewer-ux | group (with 7); sent to builder | after builder reply | |
| 7 | [nit] (polish) README.md:80: stale "The milestone that adds connecting documents the exact setup." | reviewer-ux | group (with 6); sent to builder | after builder reply | |
| 8 | [nit] (convention) VIRT/HostsViewModel.swift:~96: a failed host isn't disconnected in the background | reviewer-code | skip | | The reviewer's fix is "leave it": a failed host has no registration, and the test and README pin the behaviour. |
| 9 | [nit] (simplicity) VIRT/HostsViewModel.swift:3: the view model imports SwiftUI only for `ScenePhase` | reviewer-code | wontfix | | wontfix: the spec asks VIRTApp to pass `scenePhase` to the view model, and the app target is SwiftUI already; a parallel enum adds code for no behaviour. |

## Backlog from review
No parked blockers.
