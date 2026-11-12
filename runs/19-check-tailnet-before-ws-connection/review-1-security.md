# Review r1: security (reviewer-security, agent default model)

VERDICT: PASS
## Findings
- [nit] (polish) README.md:69: The new paragraph says the device "must have a Tailscale address, which it has only while Tailscale is on". That isn't true. Any network interface can hold an address in `100.64.0.0/10` with Tailscale off. A carrier's CGNAT address on cellular counts, and so does any address a Wi‑Fi network's DHCP hands out. Because of that wording, readers may trust plain `ws://` on networks where the check doesn't actually protect the token. Fix: say what the check really proves, for example "this device must have an address in a Tailscale range. A network that uses `100.64.0.0/10` itself can still pass this check, so prefer `wss://` or the `.ts.net` name."
- [note] Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift:108: The spec chose to count any interface (Assumptions: "doesn't look at interface names"), so the check can be bypassed. A hostile Wi‑Fi network with Tailscale off could give the device a `100.64.x` address by DHCP and answer `mac.tailnet.ts.net` with a `100.64.x` address it controls. Both halves of the check then pass, and the token goes out in plain text. This attack already worked before this branch, so the diff adds no new risk and is not a blocker. Limiting the device check to `utun*` interfaces would close most of it, because a network can't create a tunnel interface on the device. Consider a follow-up card.
- [note] Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift:117: Swapping the host for the checked address pins the connection to the address that was validated. This blocks DNS rebinding between the check and the connect. If a resolved address is a scoped address (`%en0`) or an IPv4-mapped one, `inet_pton` or the range check rejects it, so the check fails closed. Every resolved address must pass a strict numeric check before it goes into `percentEncodedHost`, so it can't be used to inject anything into the URL.
- [note] HostConnector.swift: The token is still read only after the policy and tailnet checks pass. `.notOnTailnet` holds no URL, address or token, and the diff adds no logging. `Info.plist` and ATS are unchanged, and there are no new dependencies (only `Darwin` and `Foundation`). Two gaps are in the spec's known-gap list: the time between the check and the connect, and whether ATS allows a raw IP.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, .agents/skills/factory/LOOP.md (Severity), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (full), HostURLPolicy.swift (full), TailnetCheck.swift (full), Tests/VIRTKitTests/TailnetCheckTests.swift (full), HostConnectorTests.swift (diff hunks), README.md (diff)
- Flows walked:
  - `connect` → `openTransport`: policy → tailnet check → token read → transport maker. I checked the order: no token read and no transport before the check passes.
  - The failure path: `stop` gives no retry, and the failure carries no secret.
  - Reconnect: the check runs again on each attempt.
  - `wss://` and loopback skip the check, including bracketed `[::1]`.
  - IPv4 literal (no resolver call) and resolved name: every address must be in a range, and the host is rewritten with brackets for IPv6.
  - Resolver output as untrusted input: I checked scoped IPv6, IPv4-mapped and empty or throwing results.
  - Hostile network with Tailscale off: a CGNAT or DHCP-assigned `100.64/10` address on a normal interface. See the note above.
- Commands run:
  - `git diff --stat origin/main...HEAD` → 6 files, no plist, workflow or package changes.
  - `git diff origin/main...HEAD` (sources, tests, README) → read.
  - `./scripts/test.sh` → EXIT=0.
