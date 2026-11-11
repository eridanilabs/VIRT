# Spec: Host model, URL policy and Keychain token store

## Goal
VIRTKit can save hosts (id, name, URL) that survive a relaunch, decide which URLs may carry a connection token, and keep each token only in the Keychain. The app allows plain `ws://` to `*.ts.net` hosts, and the docs explain the rule. The Hosts screen in #11 builds on this.

## Acceptance criteria
- AC1: `HostURLPolicy.evaluate(_ url: URL)` accepts `wss://` to any host. It accepts `ws://` only to `localhost`, `127.0.0.1`, `::1` (bracketed in the URL), `<label>.ts.net` with at least one non-empty label, or a dotted-quad IPv4 address in `100.64.0.0/10`. Scheme and host are case-insensitive. Ports and paths are allowed.
- AC2: Every other URL is refused with a typed reason that has a user-facing `message`. The reasons are: wrong scheme (`http://` included), no host, `ws://` to a host that isn't allowed (`ts.net`, `x.ts.net.evil.com`, `100.128.0.1`, `100.64.0.1.example.com`), user info, a query, or a fragment.
- AC3: A `ws://` URL to a `100.64.0.0/10` address is accepted with a carrier-grade NAT warning. Its message says that with Tailscale off the token goes in plain text, and to use the host's `.ts.net` name instead. Other accepted URLs have no warning.
- AC4: A `TokenStore` protocol (Sendable) can read, set (add or replace) and delete a token by host id. `KeychainTokenStore` builds its queries with `kSecClassGenericPassword`, one fixed service string, account = `hostID.uuidString`, and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on writes. `InMemoryTokenStore` is for tests. A token never appears in a store's or an error's `description` or `debugDescription`, and it is never logged.
- AC5: `HostStore(defaults:)` saves `[Host]` (`id: UUID`, `name`, `url`) as JSON under one key in the injected `UserDefaults`. A new `HostStore` on the same defaults loads the same list. The JSON has no token field.
- AC6: `HostLibrary(hostStore:tokenStore:policy:)` saves the token first, then the host. If the token write fails, or the policy refuses the URL, the host isn't saved. Deleting a host deletes its token first, then removes the host. If the token delete fails, the host stays.
- AC7: The built app's Info.plist has `NSAppTransportSecurity` → `NSExceptionDomains` → `ts.net` with `NSIncludesSubdomains` and `NSExceptionAllowsInsecureHTTPLoads` set to true. `ts.net` is the only exception domain. There is no `NSAllowsArbitraryLoads`. The generated keys are kept, for example `CFBundleDisplayName == "VIRT"`.
- AC8: AGENTS.md **Security** and README **Connecting to a host** describe the new `ws://` rule (loopback, `*.ts.net`, `100.64.0.0/10` with a warning). They explain that WireGuard encrypts tailnet traffic, give the carrier-grade NAT caveat, and name this card as the ATS exception card.

## Out of scope
- The Hosts screen and form (#11). Connecting to a host (#4). Whether ATS blocks `ws://` to `100.64.x.x` (left to #4). `NSExceptionDomains` can't take IP literals, so there's no IP entry.

## Assumptions
- Host ids are `UUID`s. The `HostStore` key and the Keychain service are fixed constants, for example `com.eridanilabs.virt.host-token`.
- IPv4 matching is strict: exactly four decimal parts of 0–255, with no leading zeros. A trailing-dot host (`a.ts.net.`) and IDN or percent-encoded hosts are refused. An IPv6 host is accepted with or without brackets as `URL` reports it.
- The policy check in `HostLibrary` is a cheap extra safeguard on top of the form in #11.
- Keychain tests only check the query dictionaries. They make no real `SecItem` calls, because `swift test` on macOS may not have Keychain access.
- The Info.plist is a partial `VIRT/Info.plist`, merged through `INFOPLIST_FILE` with `GENERATE_INFOPLIST_FILE = YES` kept. A synchronized-group membership exception stops it from being copied as a resource.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift`: policy, refusal reasons, warning.
- `Packages/VIRTKit/Sources/VIRTKit/Host.swift`, `HostStore.swift`, `HostLibrary.swift`: model, persistence, token-then-host order.
- `Packages/VIRTKit/Sources/VIRTKit/TokenStore.swift`: protocol, `KeychainTokenStore` (query builders are internal so tests can reach them), `InMemoryTokenStore`.
- `VIRT/Info.plist`: new ATS keys.
- `VIRT.xcodeproj/project.pbxproj`: `INFOPLIST_FILE` in VIRT Debug and Release, plus a `PBXFileSystemSynchronizedBuildFileExceptionSet` for `Info.plist` with unique ids.
- `AGENTS.md`, `README.md`: the `ws://` rule.

## Test plan
- AC1–AC3 → `Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift`: a table-driven test of every accepted and refused example in the card, including mixed case and `100.127.255.255`. Each case asserts the outcome, the reason and whether there is a warning.
- AC4 → `TokenStoreTests.swift`: checks the Keychain query keys and values for the read, set and delete queries. Checks in-memory set, read, replace and delete. Checks that `String(describing:)` and `String(reflecting:)` of the store and its errors don't contain the token.
- AC5–AC6 → `HostLibraryTests.swift`: uses a temporary `UserDefaults(suiteName:)` (removed afterwards) and a fake token store. Asserts that the stored JSON has no token, a fresh store reloads the same list, a failing token write saves no host, a refused URL saves nothing, delete removes the token, and a failing token delete keeps the host.
- AC7 → `VIRTTests/ATSTests.swift`: reads `Bundle.main.infoDictionary` (the tests are hosted in the app) and asserts the ATS dictionary and `CFBundleDisplayName`.
- AC8 → review only (docs).

## Size estimate
Estimate: 310 code lines
- `HostURLPolicy` accepts and refuses URLs, with reasons
- Carrier-grade NAT warning
- `TokenStore` with Keychain and in-memory stores; token never in descriptions
- `HostStore` persists the host list as JSON in an injected `UserDefaults`
- `HostLibrary` saves the token before the host and deletes the token with the host
- ATS `ts.net` exception in Info.plist, plus docs
