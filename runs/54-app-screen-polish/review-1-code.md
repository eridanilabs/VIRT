# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (docs) VIRT/SessionChatViewModel.swift:52: The `scrolled(from:to:)` doc comment still says it turns following on or off "by any route: a drag, …". Two lines later it says that "while you're dragging, it changes nothing". Drags now go through `scrollPhaseChanged`. Fix: drop "a drag" from that list, or say that drags are handled by `scrollPhaseChanged(interacting:atBottom:)`.
- [note] VIRT/SessionChatView.swift:32: `.idle` calls `scrollPhaseChanged(interacting: false, …)` after any phase, not only after `.interacting`. So `followsBottom` is also reset when a `.tracking` tap or an `.animating` scroll (such as a status-bar tap) settles. This follows the AC wording and matches what `scrolled(from:to:)` already decides in those cases, so I found no defect.
- [note] VIRT/HostsView.swift:15: After a failed reload, the old `hosts` stay in the model but are hidden, because the retry overlay replaces the rows. This is consistent with AC2.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, VIRT/HostFormView.swift, VIRT/HostFormViewModel.swift, VIRT/HostsView.swift, VIRT/HostsViewModel.swift, VIRT/HostSessionsView.swift, VIRT/HostSessionsViewModel.swift, VIRT/SessionChatView.swift, VIRT/SessionChatViewModel.swift, VIRTTests/HostsViewModelTests.swift (new tests, plus the FakeConnector, `connectingModel`, `send` and `eventually` helpers), VIRTTests/SessionChatViewModelTests.swift
- Flows walked:
  - **Host form:**
    - Typing a URL that won't parse shows the new error text.
    - A failed save sets `saveError`, and editing any field clears it.
    - A successful save runs `token = ""`, whose `didSet` is harmless.
    - Assignments in `init` don't fire `didSet`.
  - **Hosts load:**
    - First load fails, which shows the retry overlay. Retry then succeeds and clears it.
    - A reload that fails after the form's `onSaved` shows the retry overlay.
    - The empty state versus `loadFailed` precedence is correct.
    - Retry is safe to tap more than once.
  - **Opening a host:**
    - Idle, failed, connecting, connected and reconnecting hosts get the right starting status from `makeSessionsModel`.
    - `sessions` is set before `select` runs, so the Hosts screen's announcement is skipped while the sessions screen is open.
    - The sessions screen's `onChange` announcement doesn't fire for the starting value.
    - The spinner shows only in the not-connected branch.
    - The first streamed status being `.idle` is a race the spec's Assumptions accept.
  - **Chat scrolling:**
    - A drag (interacting, then decelerating, then idle) turns following off and leaves it off until the chat settles.
    - While dragging, `scrolled(from:to:)` returns false and changes nothing.
    - Settling at the bottom turns following on; settling away from it leaves it off.
    - Content growth while following still scrolls the chat.
    - A tap on a tool call (tracking, then idle) re-sets following from the pre-growth geometry.
  - **Contracts:** `docs/board-reads.md` doesn't exist at the base commit, so no consumers check applies.
- Commands run:
  - `./scripts/test.sh` → exit 0. VIRTKit: 79 tests passed. App: all cases passed, including every new test.
  - `xcodebuild build -configuration Release` (iOS Simulator, derived data in /tmp) → exit 0, so a Release build compiles with the previews left out.
  - `git status --short` → clean.

## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | VIRT/HostFormViewModel.swift:61, VIRT/HostFormViewModel.swift:15, VIRT/HostFormViewModel.swift:16, VIRT/HostFormViewModel.swift:18, VIRT/HostFormViewModel.swift:19, VIRT/HostFormView.swift:24, VIRT/HostFormView.swift:26, VIRT/HostFormView.swift:31 | VIRTTests/HostsViewModelTests.swift › "unparseableURLDisablesSave", VIRTTests/HostsViewModelTests.swift › "editingAFieldClearsTheSaveError(field:)" (the spec's test plan leaves colours, header and doc comment to review) |
| AC2 | VIRT/HostsViewModel.swift:27, VIRT/HostsViewModel.swift:51, VIRT/HostsViewModel.swift:53, VIRT/HostsView.swift:15, VIRT/HostsView.swift:54, VIRT/HostsView.swift:116, VIRT/HostsView.swift:134, VIRT/HostFormView.swift:72, VIRT/HostSessionsView.swift:73, VIRT/SessionChatView.swift:113 | VIRTTests/HostsViewModelTests.swift › "failedLoadOffersARetryAndASuccessfulLoadClearsIt" (`#if DEBUG` and `lineLimit` checked by review and the Release build) |
| AC3 | VIRT/HostsViewModel.swift:100, VIRT/HostSessionsViewModel.swift:35, VIRT/HostSessionsView.swift:52, VIRT/HostSessionsView.swift:67, VIRT/HostsView.swift:51 | VIRTTests/HostsViewModelTests.swift › "sessionsModelForAnIdleOrFailedHostStartsConnecting(status:)", VIRTTests/HostsViewModelTests.swift › "sessionsModelForABusyHostStartsAtItsStatus(status:)", VIRTTests/HostsViewModelTests.swift › "progressShowsOnlyWhileConnectingOrReconnecting(status:shows:)" (announcement checked by review) |
| AC4 | VIRT/SessionChatView.swift:79, VIRT/SessionChatView.swift:28, VIRT/SessionChatViewModel.swift:58, VIRT/SessionChatViewModel.swift:69 | VIRTTests/SessionChatViewModelTests.swift › "aDragTurnsFollowingOffAndSettlingSetsItFromTheBottom" (baseline checked by review) |
