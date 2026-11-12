# Approval (approver-merge, agent default model)

DECISION: APPROVE
Reason: `./scripts/test.sh` passes (EXIT=0: 35 VIRTKit tests in 6 suites plus all VIRTTests on the simulator), and AC1–AC6 are all met in the diff and covered by tests. All three selected reviewers passed with no blockers, the run is within the size limit (346 changed code lines, limit 400; spec estimated 190), and the only label is `factory`.
Escalation: none

- **Acceptance criteria:**
  - **AC1:** The new `resolver:` and `interfaces:` parameters default to the `getaddrinfo` and `getifaddrs` providers, so `HostConnector(library:)` still works. `defaultInitStillWorks` tests this.
  - **AC2 and AC3:** In `openTransport`, the tailnet check runs after `HostURLPolicy` and before the token is read. Every resolved address must be in a Tailscale range, and the device must have one too. A failure goes through the existing `stop` path with `.notOnTailnet` and the exact message. No token is read, no transport is made and nothing retries.
  - **AC4:** The URL's host becomes the checked address: the literal, or the first resolved one. IPv6 goes in brackets, and the port and path are kept.
  - **AC5:** `wss://` and loopback URLs never call the resolver or the interfaces, and aren't rewritten.
  - **AC6:** The check runs again on reconnect. `reconnectChecksTheTailnetAgain` tests this.
- **Dependencies and access:** The diff adds no dependencies, only `Darwin` and `Foundation`. The only network-related calls are the DNS lookup and the interface listing the spec asks for. There's no new file or storage access, and no Info.plist or ATS change.
- **Skipped reviewers:** Skipping `reviewer-ops` and `reviewer-ui-design` was right. No scripts, project files, packages, views or assets changed: only three VIRTKit sources, two test files and README.md.
- **Triage:** No parked security blockers, no `downgraded:` rows and no `upgraded:` rows. The 4 nits went to Polish issue #13.
- **Known gaps:** Two open items are on the spec's known-gap list, and the PR should state them:
  - It's not yet known whether App Transport Security (ATS) allows `ws://` to a raw tailnet IP.
  - `reviewer-security` noted that the device check counts a `100.64.x` address on any interface, such as a carrier or Wi‑Fi address. Before this branch that case was already open. Limiting the check to Tailscale's `utun*` interfaces would close most of it, as a follow-up card for a person to file.
