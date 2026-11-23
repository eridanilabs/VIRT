# Triage r1 (#59), after the builder's reply

Base: f18f9e9c626813c7fd46111d1565f42bd0770b34 · reviewed HEAD 93b2756 · rework HEAD 284c25d

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit]→[blocker] (ac) VIRT/HostsViewModel.swift:129: a banner tap over chat A sets `sessions.chat` to B in place; `SessionChatView`'s `@State var model` keeps A | reviewer-ux | new (sub) | #65 | upgraded: (ac) AC5 "opens that session's chat" fails: `tapAlert()` assigns a new chat while `navigationDestination(item:)` is showing one, and `SessionChatView` holds its model in `@State`. Fixed in ab0f228 |
| [nit] (polish) VIRT/SessionAlertPresenter.swift:121: fixed 4 s auto-dismiss ignores VoiceOver and Switch Control | reviewer-ux | new (sub) | #66 | Fixed by the builder in 284c25d |
| [nit] (simplicity) VIRT/SessionAlertPresenter.swift:28: `isConnected` is only read by tests | reviewer-code | new (sub) | #67 | Fixed by the builder in 284c25d (kept, with a note that it exists for tests) |
| [nit] (polish) VIRT/HostsViewModel.swift:127: banner tap closes the host form and drops what was typed | reviewer-ux | polish #68 | #68 | Declined by the builder: the tap asks to leave the form; the loss is now stated in the `tapAlert()` comment. Filed to milestone 4's Polish issue |

`[note]` lines get no decision; they stay in the review records.
