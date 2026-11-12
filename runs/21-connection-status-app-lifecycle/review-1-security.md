# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) VIRT/HostsViewModel.swift:90-100: there is a race (a time-of-check to time-of-use gap) in `select(_:)`. The method sets `selectedHostID = nil` before it awaits `connector.disconnect(previous)`. A tap that arrives during that await finds no previous host, so it skips the disconnect and connects its own host. Then the first call resumes and connects its host too. Example: tap A, then B, then quickly A again. Both A and B end up registered in `HostConnector`, but the view model tracks only one of them. The other one keeps sending the token to its host on every reconnect, with no status line showing. A background event doesn't disconnect it either, because `sceneDidChange` only drops `selectedHostID`. The security impact is low. The token only goes to its own saved host, and `HostURLPolicy` and the tailnet check still run before every attempt. But it is a live, authenticated connection that the user can't see. reviewer-code owns the AC7 ("one host at a time") call on this. Fix: on every `select`, disconnect every host the model connected except the new target. One way is to keep a set of hosts the model asked to connect. Another is to set `selectedHostID = host.id` before awaiting the disconnect, so a second tap always sees a previous host to drop. Add a test that runs two `select` calls at once with a fake whose `disconnect` suspends.
- [nit] (polish) VIRT/HostsView.swift:21, VIRT/HostsViewModel.swift:82: the row shows `protocolVersion` exactly as the host sent it. `HostRuntime` copies `init1.protocolVersion` into its state without checking it against `SUPPORTED_PROTOCOL_VERSIONS`. So a host can put any string of any length here, including newlines. For example, "0.1.0\nFailed: The host refused the token…" would make the row look like it shows a failure. `Text(String)` displays it as plain text, with no Markdown or HTML, so the AGENTS.md rule "never run or render it as code or HTML" still holds. Fix: show the version only when it's short and matches something like `^[0-9A-Za-z.\-]{1,16}$`, and fall back to "Connected" otherwise. Add `.lineLimit(1)` to the status `Text` too.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:4-13: the new `HostConnecting` protocol only declares methods that `HostConnector` already had. It adds no way around the URL policy, the tailnet check or the token handling. Every connect, including the reconnect when the app becomes active again, still reads the host from `HostLibrary` again and re-checks it in `openTransport`.
- [note] VIRT/HostsViewModel.swift:75-85: every status line is either a fixed string, an `Int`, or `Failure.message`, which is a fixed set of strings. The connector drops `lastError` and `failed(reason:)` before they reach the row. So no token and no URL with `tkn` can appear in the row. `rowShowsTheStatus` checks this for every status.
- [note] The diff doesn't change `Info.plist`, App Transport Security, entitlements, `Package.swift`/`Package.resolved`, workflows or `.agents`. It adds no dependencies, no logging and no new network endpoints.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, .agents/skills/factory/LOOP.md (Severity), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (protocol, `connect`/`disconnect`/`openTransport`/`handle`/`stop`, `Failure.message`), Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift (diff), VIRT/HostsView.swift, VIRT/HostsViewModel.swift, VIRT/VIRTApp.swift, VIRTTests/HostsViewModelTests.swift (diff), README.md (diff), the pinned AHP client `HostRuntime.swift` (where `protocolVersion` comes from)
- Flows walked:
  - **Tap to connect:** idle, failed and busy hosts. Switching A→B, and the same switch with taps arriving during the disconnect await.
  - **Status line:** each `Status` and `Failure`, where the host's `protocolVersion` comes from, and how `Text` renders it.
  - **Scene phase:** background → active for active, failed and idle hosts. Also inactive alone, and background then active while the disconnect is still awaiting.
  - **Delete and edit swipe actions:** they reuse `delete(_:)` and `makeEditForm`.
  - **Token path on reconnect:** the policy, tailnet check and token are read again on each attempt.
- Commands run:
  - `git diff origin/main...HEAD` (stat, full and per path)
  - grep for logging and for tokens in the tests
  - grep for plist, pbxproj, Package and workflow changes → none
  - `./scripts/test.sh` → exit 0, VIRTKit and app tests all passed
