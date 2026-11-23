# Spec: Polish: 0: Connect to a guppi host

## Goal
Ship every parked review nit from the "Connect to a guppi host" milestone together. Refusals and errors tell the user what to do next, the hosts, sessions and chat screens behave better, and README.md and AGENTS.md describe the Tailscale check accurately.

## Acceptance criteria
- AC1: `HostURLPolicy` messages change. `.missingHost` becomes "The URL has no host. Add one, for example wss://my-host.example.com." `.unsupportedScheme` becomes "VIRT connects over wss:// (or ws:// to localhost, a .ts.net name or a Tailscale address), not this scheme." In `HostURLPolicyTests`, `wss://machine.tailnet.ts.net:8443` moves into `accepted` and `(…:8443?tkn=x, .query)` moves into `refused`, with a one-line comment saying they guard the README's example URL. The two hand-written README tests are removed.
- AC2: `HostLibrary.save(_:token:)` loses `@discardableResult`. Every caller either handles the returned `Warning?` or discards it with `_ =`.
- AC3: In `HostConnector`, a `.connected` event whose `client.host(id)` is nil publishes no status, so the connector never publishes `.connected(protocolVersion: "")`. A transport from `webSocketTransport` that is closed before any send or recv invalidates its `URLSession`.
- AC4: Two `HostConnector` doc comments change. The class comment is rewrapped so the paragraph flows. The `sessionUpdates` comment says: "`[]` until the host first lists its sessions, and again after disconnect or a failure that stops it. While the host is reconnecting, the last rows stay."
- AC5: Two new tests in `HostConnectorTests`. (a) Under the shipped `.exponential` policy, a token read that throws a non-`Failure` error keeps the host `.reconnecting(attempt:, reason: nil)` with a rising attempt count, and it never reaches `.failed`. (b) The recorder is called after the host is reconnecting, from a `Task` in the maker. A 401 then gives `.failed(.tokenRefused)`, and `.cannotFindHost` gives a reconnecting status whose reason is `.hostUnreachable`.
- AC6: Doc changes in README.md and AGENTS.md:
  - Both docs add "while Tailscale is on" to the WireGuard sentence.
  - README says the guppi host listens on loopback until it is published on the tailnet, and the `.ts.net` bullet says "a host published on its tailnet". This removes the loopback contradiction.
  - The `100.x` bullet adds "VIRT checks that Tailscale is on first (see below), but prefer the host's `.ts.net` name."
  - The check paragraph says "The name must resolve only to Tailscale addresses, or the address must be one", and "this device must have an address in a Tailscale range (usually only while Tailscale is on)". It adds that a network that uses `100.64.0.0/10` itself can still pass the check, so prefer `wss://` or the `.ts.net` name.
  - "In VIRT" gets a new step after "Tap **Add host**": "Enter a name, for example `Studio`." Step 4 becomes "Its screen shows **Connecting…**, then its sessions, or **No sessions**. Back on **Hosts**, its row shows **Connected · protocol …**"
  - After host step 2, a new sentence says that every device the tailnet ACLs allow can reach the served port, that the token is its only guard, and that an ACL can limit port 8443 on a shared tailnet.
  - The checklist says that HTTPS certificates publish the machine's tailnet name in public Certificate Transparency logs.
  - A new checklist item covers a refused token: copy it again, swipe the host, tap **Edit** and enter the new token.
  - The clipboard step adds "and delete it from any clipboard-history app".
- AC7: Host form changes:
  - The unparseable-URL error reads "VIRT can't read this URL. Enter it like wss://host.example.com."
  - The `token` doc comment says the saved token is trimmed of leading and trailing whitespace.
  - `saveError` becomes nil when `name`, `urlText` or `token` changes.
  - The CGNAT warning text uses `.secondary`, and only its icon is orange.
  - The Token section has no "Token" header.
- AC8: Hosts screen changes:
  - A failed `load()` sets `HostsViewModel.loadFailed`. The screen then shows "Couldn't load hosts" with a **Retry** button that calls `load()`, instead of the alert. A successful load clears the state.
  - `HostStatusLine` has no `.lineLimit(1)`, so status lines wrap.
  - `HostLibrary.preview` and every `#Preview` that uses it are inside `#if DEBUG`.
- AC9: A host's sessions screen (the screen a tapped host opens) changes:
  - `makeSessionsModel(for:)` starts the model with `.connecting` for an idle or failed host, and with the current status for an active one, so the screen never flashes "Not connected" or an old "Failed: …".
  - The screen shows a `ProgressView` while the host is connecting or reconnecting.
  - VoiceOver announces each change to `statusText` on this screen.
- AC10: Chat screen changes:
  - The tool-call row's `HStack` uses `.firstTextBaseline`, so the chevron stays on the summary line.
  - When the scroll phase becomes `.interacting`, following turns off.
  - When the scroll phase returns to `.idle`, following is set from whether the chat is at the bottom.

## Out of scope
- A "Try again" button on the sessions screen (finding 37859a63d576 allows a follow-up).
- Changing `HostLibrary.update`'s `@discardableResult`, and changing the `.carrierGradeNAT` warning text.

## Assumptions
- I checked every finding against the current code. The test `clientErrorFailsWithTheFixedMessage` is now `givingUpFailsWithTheLastRecordedFailure`, and AC5 (a) pins the behaviour that finding describes.
- Finding 8d7b00d8b921 asks for a follow-up to #4 (check that a `ws://` peer resolves to a Tailscale address). `TailnetCheck` (#19) already does this, so only the doc wording is left.
- The token keeps its trimming, because a pasted token often ends with a newline. The finding's other fix, a doc comment that says so, is used instead.
- `follow()` still replays the connector's status. AC9 seeds the model, but the replay can still briefly overwrite it, and that race is accepted.
- `docs/board-reads.md` doesn't exist, so this isn't a triggering change.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/{HostURLPolicy,HostLibrary,HostConnector,ConnectionErrorRecorder}.swift`: AC1–AC4
- `Packages/VIRTKit/Tests/VIRTKitTests/{HostURLPolicyTests,HostLibraryTests,HostConnectorTests}.swift`: AC1, AC2, AC5
- `VIRT/{HostFormView,HostFormViewModel,HostsView,HostsViewModel,HostSessionsView,HostSessionsViewModel,SessionChatView,SessionChatViewModel}.swift`: AC7–AC10
- `VIRTTests/{HostsViewModelTests,SessionChatViewModelTests}.swift`: AC2, AC7–AC10
- `README.md`, `AGENTS.md`: AC6

## Test plan
- AC1 → `HostURLPolicyTests.swift`: the table includes the two README URLs. Both messages match the new text, and the `.missingHost` message contains "wss://".
- AC2 → the build: callers compile without unused-result warnings, and `HostLibraryTests` still checks the returned warning.
- AC3 → `HostConnectorTests.swift`: connections still report version `0.2.0`. Closing an unused `webSocketTransport` invalidates its session, observed through the recorder's `didBecomeInvalidWithError`.
- AC5 → `HostConnectorTests.swift`: the two tests described in AC5. `FakeTokenStore` gets a `failsReads` option.
- AC7 → `HostsViewModelTests.swift`: the URL message text. After a failed save, editing `name`, `urlText` or `token` clears `saveError`.
- AC8 → `HostsViewModelTests.swift`: corrupt `HostStore` data sets `loadFailed`, and `isEmpty` is false. After the data is fixed, `load()` clears `loadFailed`.
- AC9 → `HostsViewModelTests.swift`: a failed or idle host's sessions model starts at "Connecting…". An active host's model starts with its current status.
- AC10 → `SessionChatViewModelTests.swift`: `.interacting` turns following off. `.idle` at the bottom turns it on, and `.idle` away from the bottom keeps it off.
- AC4, AC6, view-only parts of AC7–AC10 → review of the diff.

## Size estimate
Estimate: 342 code lines
- Policy refusal messages give next steps, and the README URL tests move into the table
- `HostLibrary.save`'s warning can't be dropped silently
- `HostConnector`: no empty protocol version, unused sessions invalidated, accurate doc comments
- `HostConnector` tests pin endless retries on untyped errors and late recorder calls
- README and AGENTS Tailscale, security and setup wording
- Host form: clearer URL error, documented trimming, error clears on edit, readable warning, one Token label
- Hosts list: retry after a failed load, wrapping status lines, previews in Debug only
- Sessions screen: seeded status, spinner and VoiceOver announcements
- Chat: chevron stays on the summary line, a drag turns following off

## Proposed split
- Part 1: VIRTKit and docs: behaviours 1–5, AC1–AC6, about 170 code lines (score 195)
- Part 2: App screens: behaviours 6–9, AC7–AC10, about 172 code lines (score 172)
