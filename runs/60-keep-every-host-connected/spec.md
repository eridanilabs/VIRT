# Spec: Keep every saved host connected while VIRT is open

## Goal
While VIRT is in the foreground, every saved host stays connected and its session list stays live. #59's in-app alerts then cover a session on any saved host, not only on the host you last tapped.

## Acceptance criteria
- AC1: After `HostsViewModel.load()` succeeds outside the background, the connector gets one `connect` for each saved host. Another `load()` doesn't connect a host that is already connected. A host added through the form connects after the reload. Deleting a host disconnects it.
- AC2: `status(for:)` and `statusText(for:)` show each host's own latest status. When one host goes `.failed` or `.reconnecting`, the other hosts keep their status, and none of them is disconnected.
- AC3: Tapping a host never disconnects another host. Tapping a host that is connecting, connected or reconnecting makes no `connect` or `disconnect` call. Its sessions model starts at the host's current status, and its chat model uses the same connector. Tapping an idle or failed host calls `connect` for that host only.
- AC4: `.background` disconnects every connected host. `.active` connects every saved host again, failed hosts included. A `load()` or a tap while VIRT is in the background connects nothing until `.active`.
- AC5: The view models never read a token. Every connection goes through `HostConnecting.connect`, so `HostConnector` applies `HostURLPolicy`, the tailnet check and the Keychain token on every attempt, as it does today.
- AC6: `SessionAlertPresenter` follows every saved host. A session change on any host raises an alert that carries that host's id. Each host has its own baseline, so when one host reconnects, only that host's baseline resets. After a host is deleted, its alerts are dropped and it raises no new ones.
- AC7: Tapping an alert opens the alert's own host: its sessions screen, then the chat. This works when another host's sessions screen is open, or when no sessions screen is open.

## Out of scope
- A per-host switch to turn alerts off or to skip connecting at launch (the open question). A later card can add it.
- Background alerts (APNs), changes to `HostConnector`, and editing a host forcing it to reconnect.

## Assumptions
- No per-host switch for now: every saved host connects and raises alerts.
- The Hosts screen still announces status changes only for the host you last tapped, so changes on other hosts don't flood VoiceOver.
- Editing a connected host doesn't reconnect it. Tapping a failed host retries it, and the retry reads the edited URL and token.
- There is no `docs/board-reads.md` with a `## Consumers` section, and no schema version changes. Nothing triggers.
- `README.md`'s "Connecting to a host" section is updated in the same PR.

## Likely files
- `VIRT/HostsViewModel.swift`: per-host statuses and status tasks, connect-all, background and foreground handling, delete, and `tapAlert` by the alert's host.
- `VIRT/SessionAlertPresenter.swift`: follow many hosts, with a baseline, rows and tasks for each host.
- `VIRT/HostsView.swift`: small updates for the new status and announcement behaviour.
- `VIRTTests/HostsViewModelTests.swift` and `VIRTTests/SessionAlertPresenterTests.swift`: replace the single-host tests and add multi-host tests on `FakeConnector`.

## Test plan
- AC1 → `VIRTTests/HostsViewModelTests.swift`: the fake's calls show one `connect` per host after a load. A second load adds no calls. After an add, the new host connects. After a delete, it is disconnected.
- AC2 → `VIRTTests/HostsViewModelTests.swift`: send `.failed` for host A. B's text stays "Connected · protocol 0.1.0", and the fake records no `disconnect`.
- AC3 → `VIRTTests/HostsViewModelTests.swift`: tapping a connected host adds no calls. Tapping a failed host adds only `connect(thatHost)`.
- AC4 → `VIRTTests/HostsViewModelTests.swift`: background disconnects all hosts. Active connects all of them. A load or tap during the background makes no `connect` until active.
- AC5 → `VIRTTests/HostsViewModelTests.swift`: `FakeTokenStore.reads == 0` after a load, a tap, and a background-then-active cycle.
- AC6 → `VIRTTests/SessionAlertPresenterTests.swift`: a row change on host B raises an alert with B's id. Reconnecting A resets only A's baseline. A deleted host raises no alerts.
- AC7 → `VIRTTests/SessionAlertPresenterTests.swift`: with A's sessions screen open, tapping B's alert opens B's sessions screen and then the chat.

## Size estimate
Estimate: 520 code lines
- Connect every saved host on load and add, and disconnect deleted hosts
- Each host has its own status, and one host's failure doesn't affect the others
- A tap reuses the open connection and retries only an idle or failed host
- Background disconnects every host, and foreground reconnects them all
- Alerts come from every host, and tapping one opens the alert's own host

## Proposed split
- Part 1: Keep every saved host connected: behaviours 1–4, AC1–AC5. The presenter keeps following the host you last tapped. About 310 code lines.
- Part 2: Alerts from every connected host: behaviour 5, AC6–AC7. About 210 code lines.
