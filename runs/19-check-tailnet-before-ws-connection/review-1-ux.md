# Review r1: ux (reviewer-ux, agent default model)

VERDICT: PASS

## Findings
- [nit] (polish) README.md:67: This existing bullet still says that with Tailscale off, "the token goes in plain text to whatever network uses the address." The new paragraph two lines below says VIRT checks first and doesn't send the token if Tailscale is off. Read together, the two lines disagree, and a reader can't tell which one is true. Fix: add a short clause to the bullet, such as "VIRT checks that Tailscale is on first (see below), but prefer the host's `.ts.net` name." The in-app `.carrierGradeNAT` warning text stays as it is, because the spec keeps `HostURLPolicy` out of scope.
- [nit] (polish) README.md:69: The new paragraph says the device has a Tailscale address "only while Tailscale is on." That isn't always true. The check counts any interface address in `100.64.0.0/10`, which the spec allows, and a phone on a carrier-grade NAT cellular network can have such an address with Tailscale off. Also, "The name must resolve" says nothing about a `100.x` literal, which has no name to resolve. Fix: write "this device must have an address in a Tailscale range (usually only while Tailscale is on)". Write "The name must resolve only to Tailscale addresses, or the address must be one" so the sentence covers literals too.
- [note] Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift:112: The cellular carrier-grade NAT case above has a security side. With Tailscale off, a `ws://100.x` literal can pass check (b) through the cellular interface's address and then go out in plain text. That is reviewer-security's area, and the spec's Assumptions accept it ("doesn't look at interface names"). I'm noting it only because the README tells users otherwise.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:40: The failure message "This address isn't on your tailnet. Is Tailscale on?" matches the spec word for word. It is short, says what went wrong and suggests the most likely fix. TailnetCheckTests.swift:71 tests it. No app screen shows `HostConnector` statuses yet; the Hosts screen comes in part 4.

## Coverage
- Files read: the spec, AGENTS.md, `.agents/skills/factory/LOOP.md` (Severity), README.md ("Connecting to a host" section), HostConnector.swift (diff and context), HostURLPolicy.swift (refusal and warning copy, `normalizedHost`), TailnetCheck.swift (new), and VIRT/HostFormViewModel.swift and VIRT/HostsView.swift (where messages appear today). I grepped the tests for the message string.
- Flows walked:
  - Saving a host URL: the form shows the refusal or the `.carrierGradeNAT` warning; this diff doesn't change that.
  - Connecting to a `ws://` `.ts.net` name or a `100.x` literal: the check passes and the host is rewritten, or it fails with `.notOnTailnet`.
  - A `wss://` or loopback URL is passed through unchanged.
  - Reconnecting after Tailscale goes off.
  - Reading the README section from top to bottom, checking it for consistency and accuracy.
- Commands run:
  - `git diff origin/main...HEAD` → 6 files changed: 3 Swift sources, 2 test files and README.md.
  - `./scripts/test.sh` → exit 0. The `swift test` run and the `xcodebuild test` run on the iPhone 18 Pro simulator both passed.
- Earlier blockers: none (this is round 1).
