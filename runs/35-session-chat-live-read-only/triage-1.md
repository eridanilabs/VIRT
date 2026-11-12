# Triage r1

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [blocker] (security) HostConnector.swift:224: a host can crash the app; `followChat` feeds untrusted actions to the pinned `chatReducer`, which hits `preconditionFailure` on `.unknown` tool calls at turn end or completion, and on a non-ISO 8601 `startedAt` | reviewer-security | new (sub) | #43 | This run's: the diff adds the first use of `AHPStateMirror` and the reducers (`git grep` on origin/main finds none), and AC1 asks that `.unknown` not crash |
| [nit] SessionChatView.swift:37: drop the period from "Couldn't open this chat." | reviewer-ui-design | wontfix | | wontfix: AC5 names the exact copy "Couldn't open this chat.", so changing it would break an acceptance criterion |
| [nit] HostSessionsView.swift:17: session row shows no disclosure chevron | reviewer-ux | new | after the builder replies | sent to the builder; filed `--as sub` if fixed, into Polish #13 if declined |
| [nit] SessionChatView.swift:23: tool-call icon may be read by VoiceOver as the symbol name | reviewer-ux | new | after the builder replies | sent to the builder; filed `--as sub` if fixed, into Polish #13 if declined |
| [nit] SessionChat.swift:59: empty tool `displayName` gives " · Done" | reviewer-ux | new | after the builder replies | sent to the builder; filed `--as sub` if fixed, into Polish #13 if declined |

`[note]` lines from reviewer-code, reviewer-ux and reviewer-ui-design get no triage decision and stay in their review records.
