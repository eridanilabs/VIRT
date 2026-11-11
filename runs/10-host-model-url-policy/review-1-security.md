# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) AGENTS.md:54: The docs say "WireGuard encrypts tailnet traffic, so the token isn't in plain text on the network" with no condition. README.md:64 says the same. That is only true while Tailscale is on and MagicDNS answers. With Tailscale off, `<machine>.<tailnet>.ts.net` is resolved by whatever DNS the current network uses. A hostile Wi-Fi resolver can point the name at its own address, and the `ws://` URL then sends the token in plain text. So "prefer the `.ts.net` name" over `100.64.0.0/10` is safer only against a passive carrier-grade NAT path, not an active one. Fix: add "while Tailscale is on" to the WireGuard sentence in both docs, and give #4 a follow-up. Before #4 sends the token over `ws://` to a `*.ts.net` or `100.64.0.0/10` host, it should check that the resolved peer address is a Tailscale address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`). This keeps the owner's decision and narrows its leftover risk.
- [nit] (polish) Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift:26: `@discardableResult` on `save` lets a caller drop the carrier-grade NAT warning without the compiler noticing. That warning is the only control the owner accepted for the `100.64.0.0/10` risk. Fix: remove `@discardableResult`, so #11 has to handle the returned `Warning?` explicitly, even if only with `_ =`.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostStore.swift:22: `HostStore.save` is public and doesn't apply the policy. `HostLibrary.hosts()` returns stored hosts without checking them again. The policy in `HostLibrary` is a save-time check that can be bypassed, which the spec allows ("cheap extra safeguard"). #4 should run `HostURLPolicy.evaluate` again just before it attaches the token to a connection, because that is where the rule actually has to hold.
- [note] VIRT/Info.plist:9: `NSExceptionAllowsInsecureHTTPLoads` on `ts.net` covers the whole app, not just WebSockets. Any later `http://*.ts.net` load is allowed too, such as an `AsyncImage` or a link built from untrusted host data. The diff adds no such load today. Later cards that load URLs from the host should keep this exception in mind.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift:30: If the host-list write fails after the token write, or when actor reentrancy interleaves `save` and `delete` on the same id, a token can be left in the Keychain with no host. iOS Keychain items survive uninstalling the app. The spec asks for no rollback, so this is only a note. A cleanup of orphaned items under `KeychainTokenStore.service` could be added later.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:86: I checked how the URL parsing handles tricky inputs, and every one is refused:
  - **Through user info:** `ws://evil.com\@mac.ts.net`, `ws://@localhost`, `ws://:@localhost`.
  - **Through the host character check:** `localhost%00.evil`, `mac.ts.net;evil`, `100.64.0.1%2f`, `[::ffff:100.64.0.1]`, trailing dot, IDN.
  - **Query and fragment URLs:** refused, so a token can't end up in the saved URL through `?tkn=`.
## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, the factory skill's LOOP.md (Severity section), the reviewer selection file. The full diff: Host.swift, HostStore.swift, HostLibrary.swift, HostURLPolicy.swift, TokenStore.swift, HostLibraryTests.swift, HostURLPolicyTests.swift, TokenStoreTests.swift, VIRT/Info.plist, project.pbxproj, VIRTTests/ATSTests.swift, README.md.
- Flows walked:
  - **URL policy:** `wss` vs `ws`, loopback including bracketed IPv6, `*.ts.net` label rules, strict `100.64.0.0/10` IPv4 parsing, user info, query and fragment refusals, and percent-encoding, IDN and trailing-dot cases.
  - **Save:** policy check, then token, then host list, including the refusal and failing token-write paths.
  - **Delete:** token, then host, including the failing-delete path.
  - **Token secrecy:** `description`, `debugDescription`, `customMirror` and `dump` of the stores and their errors, and no logging calls in the diff.
  - **Keychain queries:** generic password, fixed service, account = UUID, `AfterFirstUnlockThisDeviceOnly` on both add and update, no synchronizable flag.
  - **ATS:** only the `ts.net` exception domain, no `NSAllowsArbitraryLoads`, `INFOPLIST_FILE` merged with `GENERATE_INFOPLIST_FILE = YES` kept.
  - **Supply chain:** no new dependencies; `Synchronization` and `Security` are system modules.
- Commands run:
  - `git log` / `git diff origin/main...HEAD` → 3 commits, 13 files.
  - `./scripts/test.sh` → exit 0. `swift test`: 18 tests in 4 suites passed. `xcodebuild test`: 4 app tests passed on iPhone 18 Pro, including the ATS tests.
  - A throwaway Swift script in `/tmp` testing `URL`/`URLComponents` on tricky URLs → every one is refused or not parsed, as listed above.
