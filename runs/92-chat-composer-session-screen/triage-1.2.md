# Review round 1 triage (updated after build round 2)

| Finding | Reviewer | Decision | Issue | Reason |
|---|---|---|---|---|
| [blocker] (ac) VIRTTests/SessionChatViewModelTests.swift:65: AC1 lacks a test for composer placement above navigation and keyboard-visible behavior. | reviewer-code | new | #97 | Spec AC1 requires the composer above navigation, and this run lacked the corresponding test; filed as a sub-issue. |
| [nit] (polish) VIRT/SessionChatView.swift:65: VoiceOver may miss send errors because they are not announced dynamically. | reviewer-ux | new | #98 | Builder fixed the nit; filed as a sub-issue. |