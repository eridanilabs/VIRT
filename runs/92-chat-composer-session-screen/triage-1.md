# Review round 1 triage

| Finding | Reviewer | Decision | Issue | Reason |
|---|---|---|---|---|
| [blocker] (ac) VIRTTests/SessionChatViewModelTests.swift:65: AC1 lacks a test for composer placement above navigation and keyboard-visible behavior. | reviewer-code | new | #97 | Spec AC1 requires the composer above navigation, and this run lacks the corresponding test. |
| [nit] (polish) VIRT/SessionChatView.swift:65: VoiceOver may miss send errors because they are not announced dynamically. | reviewer-ux | polish | Active milestone Polish issue (if declined; pending) | Worth addressing; if declined, route to the active milestone’s Polish issue. |