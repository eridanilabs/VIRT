# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [note] VIRT/HostsViewModel.swift:182: VIRT now connects every saved host on `load()` and on return to the foreground, so it sends each host its token without a tap. This is safe. `HostConnector.openTransport` checks the host again before every attempt, in this order: `library.hosts()`, then `HostURLPolicy`, then `TailnetCheck`, then the token read. That order still enforces the `ws://` and `100.64.0.0/10` rules from AGENTS.md. A connection to a CGNAT address still needs Tailscale to be on.
- [note] VIRT/HostsViewModel.swift:182: `connectAll` loops over a copy of `hosts`. A delete during that loop can still call `connector.connect` for the deleted host. That attempt stops with `.hostNotFound` before any token is read, and no status task is started because of the `hosts.contains` guard. No token reaches a deleted host. It only leaves a stale `statuses` and `requestedHostIDs` entry, and code quality is reviewer-code's lane.
- [note] VIRT/HostsViewModel.swift:160: I traced quick background → active → background switches. Each connect adds the host to `requestedHostIDs` before its first await. Each background loop stops when `isInBackground` turns false, and a later background takes over the hosts left. No connection that was asked for stays open across a background.

No findings that need a change.

## Coverage
- Files read: the pinned reviewer-security.agent.md, AGENTS.md, the spec, `git diff 476698e…HEAD` (README.md, VIRT/HostsView.swift, VIRT/HostsViewModel.swift, VIRTTests/HostsViewModelTests.swift), all of VIRT/HostsView.swift, the changed parts of VIRT/HostsViewModel.swift and their surroundings, Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift, VIRT/VIRTApp.swift (the callers)
- Flows walked:
  - load → connectAll, including a failed load and a load while in the background
  - add or edit form → reload
  - delete, both success and failure, including a delete during connectAll
  - select on a host that is idle, failed or busy, and while in the background
  - background and active, including quick switches between them
  - status text for host-supplied values: SwiftUI `Text` only, never run or shown as HTML, and no token or URL in a `Failure.message`
  - the view model reading tokens: it never reads one, and the tests check that `reads == 0`
- Checks with nothing to report:
  - No new dependencies, network endpoints, entitlements or ATS changes.
  - No secrets in the code, logs or README.
- Commands run:
  - `git log` and `git diff --stat` / `git diff` against the base SHA → 1 commit, 4 files
  - `./scripts/test.sh` → exit 0, every VIRTKit and VIRT test passed. I saved this run's output to a log file outside the checkout, `/tmp/virt70-sec-test.log`.
