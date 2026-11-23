# Spec: Keep every saved host connected while VIRT is open (part 1 of #60)

## Goal
While VIRT is in the foreground, every saved host stays connected, and each host's row on the Hosts screen shows that host's own status. Tapping a host opens its sessions without disconnecting any other host. Alerts still follow the host you last tapped; part 2 (#71) extends alerts to every host.

## Acceptance criteria
- AC1: When `HostsViewModel.load()` succeeds, it calls `HostConnecting.connect` once for each saved host that isn't already connecting, connected or reconnecting. A later load, such as the one after an add or edit, connects only hosts that are new or not yet active. A successful `delete` calls `disconnect` for that host. A failed delete or a failed load calls neither.
- AC2: `status(for:)` and `statusText(for:)` return each host's own latest status. A status for one host, including `.failed` or `.reconnecting`, doesn't change another host's row and causes no `connect` or `disconnect` for any other host.
- AC3: `select` never calls `disconnect`. When the host is connecting, connected or reconnecting, `select` makes no connector call. When the host is idle or failed, it calls `connect` once, for that host only. `select` still sets `selectedHostID`, `alerts.follow`s that host, and `selectedStatusText` follows that host's status.
- AC4: `.background` calls `disconnect` once for each host the model connected. `.active` after a background calls `connect` for every saved host, failed hosts included. `.inactive`, and `.active` with no background before it, make no connector call. A load or tap while in the background connects nothing until the next `.active`.
- AC5: The view model never reads a token. After load, select, delete, background and active, the token store's read count is still 0, and every connection goes through `HostConnecting.connect`.
- AC6: README.md's "Connecting to a host" section describes the new behaviour: every host connects while VIRT is open, a tap doesn't disconnect other hosts, background disconnects every host, and foreground reconnects every host, failed ones included.

## Out of scope
- A per-host setting to turn alerts off or to skip connecting at launch. Any change to `HostConnector`, `HostConnecting` or other VIRTKit code.
- Alerts for hosts other than the one last tapped (#71). `SessionAlertPresenter` doesn't change.
- Reconnecting a host after it's edited. VoiceOver announcements for hosts other than the selected one.

## Assumptions
- Editing a host leaves its open connection as it is. The new URL and token take effect on the next attempt, because `HostConnector` reads both before every attempt.
- A failed host stays failed until you tap it or VIRT returns to the foreground. A later `load()` doesn't retry it.
- The Hosts screen still announces status changes only for the selected host, as `selectedStatusText` does today.
- The row's accessibility hint changes to describe opening the host's sessions, because a tap no longer always connects.
- This is an iOS app and its `docs/board-reads.md` has no `## Consumers` section, so no change here counts as a triggering change.

## Likely files
- `VIRT/HostsViewModel.swift`: per-host statuses and status tasks; connecting on load, disconnecting on delete, `select` without disconnects, and background and active for every host.
- `VIRT/HostsView.swift`: per-host status lines (the API is mostly unchanged) and the new row hint.
- `VIRTTests/HostsViewModelTests.swift`: rewrite the one-host-at-a-time tests and add tests for every host connecting.
- `README.md`: the "Connecting to a host" section.

## Test plan
- AC1 → `VIRTTests/HostsViewModelTests.swift`: loading A and B gives `[.connect(A), .connect(B)]`. Adding C, then loading again, adds only `.connect(C)`. A successful delete adds `.disconnect`, and a failed delete or failed load adds nothing.
- AC2 → same file: sending `.failed` to A leaves B's row at "Connected · protocol 0.1.0", and the call list has no disconnect.
- AC3 → same file: tapping B while A is connected makes no `disconnect`. Tapping a busy host makes no call. Tapping a failed host makes exactly one `.connect` for that host, and `alerts.hostID` is the tapped host.
- AC4 → same file: background disconnects A and B. Active reconnects both, including a failed one. A load or tap in the background connects nothing until active.
- AC5 → same file: `FakeTokenStore.reads == 0` after the whole flow.
- Existing `SessionAlertPresenterTests` still pass without changes.

## Size estimate
Estimate: 320 code lines
- Connect every saved host on load and add, and disconnect deleted hosts
- Each host has its own status, and one host's failure doesn't affect the others
- A tap reuses the open connection and retries only an idle or failed host
- Background disconnects every host, and foreground reconnects them all
