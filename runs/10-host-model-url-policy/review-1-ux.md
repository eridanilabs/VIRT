# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:53: `missingHost` says "The URL has no host." and gives no next step. Every other refusal says what to do. Fix: "The URL has no host. Add one, for example wss://my-host.example.com."
- [nit] Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:51: `unsupportedScheme` says plain ws:// works "only to this device", while the sibling message and the docs say `localhost`. It also never says which scheme the user typed was wrong, so `http://` gives a hint about ws:// rather than "http:// isn't supported". Fix: "VIRT connects over wss:// (or ws:// to localhost, a .ts.net name or a Tailscale address), not this scheme." Also use the same name for the loopback case in both messages.
- [nit] README.md:60-64: The paragraph opens with "The guppi host listens on loopback only", and one bullet then says "for a host that listens on its tailnet address". That reads as a contradiction. Fix: say the host must be configured to listen on its tailnet address, or point to the milestone that documents the setup.
- [note] The AC3 warning copy says what happens ("the token goes in plain text") and what to do ("use the host's .ts.net name"). The AC8 doc content is present in AGENTS.md and README, including the wording on WireGuard, carrier-grade NAT and card #10. The Hosts screen (#11) will display these messages, and that is out of scope here.
- [note] README lists `[::1]` and AGENTS.md lists `::1`, which is consistent with the spec.

## Coverage
- Files read: AGENTS.md (Security diff), README.md (Connecting to a host), HostURLPolicy.swift, HostLibrary.swift, spec.md, reviewers-10-1.txt
- Flows walked: refusal messages for each reason, the carrier-grade NAT warning copy, and the docs against AC8. Not read: Info.plist, Host.swift, HostStore.swift, TokenStore.swift, the pbxproj and the tests, which are outside the UX lane. There is no UI in this change.
- Commands run: `swift test` in Packages/VIRTKit → 18 tests in 4 suites passed
- Earlier blockers: none (round 1)
