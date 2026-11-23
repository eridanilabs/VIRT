# Triage r1 (#59)

Base: f18f9e9c626813c7fd46111d1565f42bd0770b34 · HEAD 93b2756

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit]→[blocker] (ac) VIRT/HostsViewModel.swift:129: a banner tap over chat A sets `sessions.chat` to B in place; `SessionChatView`'s `@State var model` keeps A | reviewer-ux | new (sub) | pending | upgraded: (ac) AC5 "opens that session's chat" fails: `tapAlert()` (HostsViewModel.swift:131) assigns a new chat while `navigationDestination(item:)` is showing one, and `SessionChatView` (SessionChatView.swift:9) holds its model in `@State`, which keeps its first value when SwiftUI reuses the view |
| [nit] (polish) VIRT/HostsViewModel.swift:127: banner tap closes the host form and drops what was typed | reviewer-ux | new | after builder | sent to the builder as a cheap nit; filed `sub` if fixed, `backlog` if declined |
| [nit] (polish) VIRT/SessionAlertPresenter.swift:121: fixed 4 s auto-dismiss ignores VoiceOver and Switch Control | reviewer-ux | new | after builder | sent to the builder as a cheap nit; filed `sub` if fixed, `backlog` if declined |
| [nit] (simplicity) VIRT/SessionAlertPresenter.swift:28: `isConnected` is only read by tests | reviewer-code | new | after builder | sent to the builder as a cheap nit; filed `sub` if fixed, `backlog` if declined |

`[note]` lines from every reviewer get no decision; they stay in the review records.

Outcome: reviewer-ux reads `PASS, nit upgraded, counted as CHANGES`; reviewer-code, reviewer-security and reviewer-ui-design PASS. Round 1 goes back to Build (budget 3, rework allowed).
