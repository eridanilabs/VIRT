# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [note] Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift:36: `save` overwrites the token before it writes the host list. If the list write then fails, an existing host keeps its new token while the list still has the old host fields. The spec asks for no rollback and the builder reported this, so no action is needed.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:101: The tailnet-name check accepts only lowercase ASCII letters, digits and hyphens, so a label with an underscore is refused. That is stricter than AC1 and safe. It is also not tested. Leave it unless #11 needs underscores.
- [note] Packages/VIRTKit/Tests: Nothing tests the order of the two writes in `save`, but `failingTokenWriteSavesNoHost` covers the failing-token case. Nothing tests `HostStore.load` with corrupt JSON either. Neither is in an acceptance criterion.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, the reviewer-selection output, Host.swift, HostStore.swift, HostLibrary.swift, HostURLPolicy.swift, TokenStore.swift, HostURLPolicyTests.swift, TokenStoreTests.swift, HostLibraryTests.swift, ATSTests.swift, VIRT/Info.plist, the project.pbxproj diff, the README and AGENTS.md diffs, Package.swift
- Flows walked:
  - URL evaluation: scheme, host, user info, query and fragment checks, then the `ws://` host rules. Covered the bracketed and unbracketed `::1` host, mixed case, trailing dot, percent-encoded and IDN hosts, the IPv4 boundaries, the empty `?` and `#`, and the empty user info.
  - Keychain set: update, then add if the item is missing. Also read, delete, and the query dictionaries.
  - `HostLibrary.save`: policy refusal, token write failure, then add or replace the host.
  - `HostLibrary.delete`: token delete failure keeps the host.
  - Host persistence round trip through a fresh `HostStore` on the same defaults.
  - ATS plist merge: `INFOPLIST_FILE` set, `GENERATE_INFOPLIST_FILE = YES` kept, and the membership exception set so the plist isn't copied as a resource.
- Commands run: `./scripts/test.sh` → exit 0. `swift test` ran 18 tests in 4 suites and all passed. The `xcodebuild` app-test step also exited 0, but I did not read its output.
- Earlier blockers: none (round 1)
