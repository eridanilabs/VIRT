# Spec: App screen polish for connecting to a guppi host

## Goal
Clean up the four screens you use to connect to a guppi host: the host form, the Hosts list, a host's sessions screen and the chat. Errors should be clearer, failures should be recoverable, and VoiceOver and scrolling should behave better. This covers #13's AC7 to AC10.

## Acceptance criteria
- AC1 (host form):
  - An unparseable URL makes `HostFormViewModel.urlError` read exactly "VIRT can't read this URL. Enter it like wss://host.example.com."
  - The `token` doc comment says the saved token has leading and trailing whitespace trimmed.
  - `saveError` becomes nil when `name`, `urlText` or `token` changes.
  - In the CGNAT warning, the text uses `.secondary` and only the icon is orange.
  - The Token section has no "Token" header.
- AC2 (Hosts screen):
  - A failed `load()` sets `HostsViewModel.loadFailed` and doesn't set `errorMessage`. The screen then shows "Couldn't load hosts" with a **Retry** button that calls `load()`, instead of the alert.
  - A successful `load()` clears `loadFailed`.
  - `HostStatusLine` has no `.lineLimit(1)`.
  - `HostLibrary.preview` and every `#Preview` that uses it are inside `#if DEBUG`.
- AC3 (sessions screen):
  - `makeSessionsModel(for:)` starts `HostSessionsViewModel.status` at `.connecting` for an idle or failed host. For a host that's connecting, connected or reconnecting, it starts at that host's current status.
  - A model flag, true only for `.connecting` or `.reconnecting`, makes the screen show a `ProgressView` next to the status line.
  - The screen posts a VoiceOver announcement for each change to `statusText`.
- AC4 (chat screen):
  - The tool-call row's `HStack` uses `.firstTextBaseline`.
  - When the scroll phase becomes `.interacting`, `followsBottom` turns off. While you're dragging, scroll changes don't turn it back on or scroll the chat.
  - When the phase returns to `.idle`, `followsBottom` is set from whether the chat is at the bottom.

## Out of scope
- A "Try again" button on the sessions screen.
- Any change to `VIRTKit`, `HostConnector` or the connect flow.

## Assumptions
- AC3's fix sets only the model's starting status. If the connector's first streamed status is `.idle` because connecting hasn't started yet, that value still wins. Holding it back is left for a later card.
- While a sessions screen is open, the Hosts screen stops its own `selectedStatusText` announcement, so VoiceOver doesn't announce each change twice.
- The chat model gets a scroll-phase method that takes "interacting or not" plus "at bottom". The model stays free of SwiftUI, and the view calls it from `.onScrollPhaseChange`.
- `docs/board-reads.md` has no `## Consumers` section and nothing here triggers, so there's no `Consumers:` line.

## Likely files
- `VIRT/HostFormView.swift`, `VIRT/HostFormViewModel.swift`: AC1, and the AC2 `#Preview` wrapping.
- `VIRT/HostsView.swift`, `VIRT/HostsViewModel.swift`: AC2, `makeSessionsModel` for AC3, the announcement assumption.
- `VIRT/HostSessionsView.swift`, `VIRT/HostSessionsViewModel.swift`: AC3, and the AC2 `#Preview` wrapping.
- `VIRT/SessionChatView.swift`, `VIRT/SessionChatViewModel.swift`: AC4, and the AC2 `#Preview` wrapping.

## Test plan
- AC1 → `VIRTTests/HostsViewModelTests.swift`: the `urlError` for `ws://[bad` is the exact text. A save that fails through `FakeTokenStore(failsWrites:)` sets `saveError`, and editing `name`, `urlText` or `token` clears it. The colours, header and doc comment are checked in review.
- AC2 → `VIRTTests/HostsViewModelTests.swift`: bad JSON under `HostStore.key` makes `load()` set `loadFailed` and leave `errorMessage` nil. After the data is fixed, `load()` clears `loadFailed` and lists the hosts. `#if DEBUG` and `lineLimit` are checked by review and the build.
- AC3 → `VIRTTests/HostsViewModelTests.swift`: for an idle host and a failed host, a new model's `status` is `.connecting`. For connected and reconnecting hosts it's the current status. The progress flag is true only for connecting and reconnecting.
- AC4 → `VIRTTests/SessionChatViewModelTests.swift`: starting a drag turns following off. A geometry change at the bottom during the drag leaves it off and returns false. Going back to idle at the bottom turns it on, and going back to idle away from the bottom leaves it off.

## Size estimate
Estimate: 175 code lines
- Host form: clearer URL error, documented token trimming, save error cleared on edit, readable warning colour, one Token label
- Hosts list: retry after a failed load, status lines that wrap, previews in Debug builds only
- Sessions screen: correct starting status, spinner while connecting, VoiceOver status announcements
- Chat: chevron on the summary baseline, a drag turns following off and settling sets it again
