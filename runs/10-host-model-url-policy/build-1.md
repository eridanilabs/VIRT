# Build round 1 (builder-app · claude-opus-5.5)

Built on `factory/10-host-model-url-policy` in three commits:
- b3578e3 feat(virtkit): add saved hosts, a host URL policy and a Keychain token store
- 44a7dc3 feat(app): allow plain ws:// to ts.net hosts through ATS
- a702aa7 docs: describe the ws:// rule for loopback, ts.net and 100.64.0.0/10

## Changes
- `Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift`: `evaluate(_:)` returns accepted or refused, with six refusal reasons that each have a `message`. `ws://` to `100.64.0.0/10` is accepted with a carrier-grade NAT warning. Strict IPv4 parsing.
- `Host.swift`, `HostStore.swift`: host is `id`, `name`, `url`. The list is JSON under `com.eridanilabs.virt.hosts` in the injected `UserDefaults`.
- `TokenStore.swift`: async Sendable `TokenStore`, `KeychainTokenStore`, `InMemoryTokenStore`. Internal query builders. No token in descriptions or `dump`.
- `HostLibrary.swift`: actor; token then host on save, token then host on delete. `save` returns the policy warning.
- `VIRT/Info.plist`: only the `ts.net` ATS exception.
- `VIRT.xcodeproj/project.pbxproj`: `INFOPLIST_FILE = VIRT/Info.plist` (Debug and Release), `GENERATE_INFOPLIST_FILE = YES` kept, plus an exception set so Info.plist isn't copied as a resource.
- `VIRTTests/ATSTests.swift` and the VIRTKit tests.
- `AGENTS.md` (Security), `README.md` (Connecting to a host).

## AC coverage
- AC1–AC3: `HostURLPolicyTests` (48-case table, plus `idnHostIsRefusedForWS`, `everyRefusalHasAMessage`, `carrierGradeNATWarningExplainsTheRisk`).
- AC4: `TokenStoreTests` (query dictionaries only; in-memory set/read/replace/delete; descriptions never hold the token).
- AC5–AC6: `HostLibraryTests` (temporary `UserDefaults` suite; JSON keys exactly id/name/url; failing token write saves no host; refused URL saves nothing; delete removes token and host; failing token delete keeps host).
- AC7: `VIRTTests/ATSTests` (only `ts.net`, no `NSAllowsArbitraryLoads`, `CFBundleDisplayName == "VIRT"`); built Info.plist checked with `plutil -p`.
- AC8: docs, review only.

## Tests
`./scripts/test.sh` exits 0 on iPhone 18 Pro (iOS 27.2): `swift test` 18 tests in 4 suites passed; `xcodebuild test` 4 app tests passed. README edited after the run (docs only).

## Gaps and decisions
- Trailing-dot, IDN and percent-encoded hosts are refused only for `ws://`; `wss://` accepts any host per AC1.
- On macOS, Foundation's `Host` clashes; Mac tests use `import struct VIRTKit.Host`. iOS isn't affected.
- `UserDefaults` isn't Sendable in the SDK; `HostStore` holds it `nonisolated(unsafe)` with a comment.
- If the host-list write fails after the token write, the token is left in the Keychain; the spec asks for no rollback.
- Loopback is exactly `127.0.0.1`, `localhost`, `::1`.
