# Spec: Save an AHP host and its token

## Goal
You can save the AHP hosts VIRT should reach, each with a name, a URL and a connection token, from a Hosts screen that opens first. The token stays in the Keychain, and the app refuses URLs that would send it insecurely.

## Acceptance criteria
- AC1: The app opens on **Hosts**, which lists saved hosts by name. With no hosts saved, it shows an empty state with an **Add host** button.
- AC2: Add and edit use one form with a name, a URL and a token. Name and URL are required, and so is the token when adding. When editing, the form never loads the saved token. It shows that a token is saved and has a secure field to replace it. Leaving that field blank keeps the saved token.
- AC3: `HostURLPolicy` (in VIRTKit) accepts `wss://` to any host, and `ws://` only to `localhost`, `127.0.0.1`, `::1`, a host ending in `.ts.net` with at least one label before it, or a dotted-quad IPv4 address in `100.64.0.0/10` (`100.64.x.x`–`100.127.x.x`). Scheme and host are case-insensitive. It refuses everything else with a reason the form shows: wrong scheme, no host, `ws://` to a host that isn't allowed, or a URL with user info, a query or a fragment (the token goes in the token field). Saving stays disabled while the URL is refused.
- AC4: A `ws://` URL to a `100.64.0.0/10` address passes with a carrier-grade NAT warning. The warning says that with Tailscale off, the token goes in plain text, and suggests the host's `.ts.net` name. Saving still works.
- AC5: Tokens are stored only through `TokenStore`. `KeychainTokenStore` uses `kSecClassGenericPassword` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, with a fixed service and account = host id. A token never goes into `UserDefaults`, a file, a log or `description`.
- AC6: Through `HostStore`, the host list (id, name and URL, with no token) survives relaunch. `HostLibrary` saves a token before it saves the host, and deleting a host removes its token too.
- AC7: The built app's Info.plist has `NSAppTransportSecurity` → `NSExceptionDomains` → `ts.net` with `NSIncludesSubdomains` and `NSExceptionAllowsInsecureHTTPLoads` set to true, and no `NSAllowsArbitraryLoads`. AGENTS.md **Security** and README describe the new `ws://` rule, why it holds, and the carrier-grade NAT caveat.

## Out of scope
- Connecting to a host or checking a token (#4). Dev tunnels, QR or file import of tokens, and syncing hosts across devices.

## Assumptions
- `NSExceptionDomains` can't take IP literals or ranges, so there's no IP entry. If ATS blocks `ws://` to `100.64.x.x`, #4 handles it.
- The host list is JSON in `UserDefaults`, and the `UserDefaults` instance is injected. Host ids are `UUID`s.
- The partial `VIRT/Info.plist` is merged through `INFOPLIST_FILE`, with a synchronized-group membership exception so it isn't copied as a resource.

## Likely files
- `Packages/VIRTKit/Sources/VIRTKit/{Host,HostURLPolicy,HostStore,TokenStore,HostLibrary}.swift`: the model, the URL policy, the protocols, and the real and in-memory stores.
- `VIRT/{HostsView,HostFormView,HostsViewModel}.swift`, `VIRT/VIRTApp.swift`, and deleting `VIRT/ContentView.swift`: the screens.
- `VIRT/Info.plist`, `VIRT.xcodeproj/project.pbxproj`: the ATS exception.
- `AGENTS.md`, `README.md`: the Security wording.

## Test plan
- AC3/AC4 → `Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift`: table-driven. Accepts: `wss://`, loopback, `[::1]`, `a.tail.ts.net`, `100.64.0.1` and `100.127.255.255`, with a warning only on the `100.x` URLs. Refuses: `ws://ts.net`, `x.ts.net.evil.com`, `100.128.0.1`, `100.64.0.1.example.com`, `http://`, and URLs with a query or user info.
- AC5 → `TokenStoreTests.swift`: the Keychain query has the right class, accessibility and account. In-memory set, read, replace and delete work.
- AC6 → `HostLibraryTests.swift`: with fakes, adding saves the token and the host, deleting removes both, and the encoded host JSON has no token. A host store on a temporary `UserDefaults` suite reloads its list.
- AC1/AC2 → `VIRTTests/HostsViewModelTests.swift`: empty state when there are no hosts, save disabled for a refused URL, editing never exposes the token, and a blank token keeps the old one.
- AC7 → `VIRTTests/ATSTests.swift`: `Bundle.main.infoDictionary` has the `ts.net` exception and no `NSAllowsArbitraryLoads`.

## Size estimate
Estimate: 480 code lines
- URL policy that accepts and refuses with a reason
- Non-blocking carrier-grade NAT warning
- Token only in the Keychain, keyed by host id
- Host list persists across relaunch, with no token
- Deleting a host removes its token
- Narrow `ts.net` ATS exception, plus the AGENTS.md update
- Hosts screen first, with an empty state and Add host
- Add and edit form, with a masked token you can replace

## Proposed split
- Part 1: Hosts model, URL policy and secure storage: the URL policy, carrier-grade NAT warning, Keychain storage, persistence, delete removing the token, and ATS with AGENTS.md (AC3–AC7), about 260 code lines
- Part 2: Hosts screen and form: the Hosts screen with its empty state, and the add and edit form with the masked token (AC1–AC2), about 220 code lines
