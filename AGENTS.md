# AGENTS.md

Conventions for anyone, person or agent, changing VIRT. The `/factory` agents read this file.

VIRT is a native iOS app that is an [Agent Host Protocol](https://github.com/microsoft/agent-host-protocol) (AHP) client: it connects to an AHP host, such as the one [guppi](https://github.com/eridanilabs/guppi) runs, and lets you watch and work with that host's agent sessions.

## Layout

| Path | Holds |
|------|-------|
| `VIRT/` | The app target: SwiftUI views, view models and assets. |
| `VIRTTests/` | The app's unit tests, hosted in the app on an iOS simulator. |
| `Packages/AHPClient/` | A local Swift package with the protocol client: messages, transport, connection and session state. It has no UI and doesn't import SwiftUI or UIKit. |
| `VIRT.xcodeproj/` | The Xcode project and its shared `VIRT` scheme. |
| `scripts/test.sh` | The test command: the board's `test_command`, and what CI runs. |
| `.agents/`, `.github/agents/`, `apm.lock.yaml` | The `/factory` skills and agents, installed by `apm install`. Don't hand-edit them. |

## Language

- **Swift first.** Write Swift 6 with strict concurrency, and SwiftUI for UI. Use UIKit only for what SwiftUI can't do, wrapped in a `UIViewRepresentable` or `UIViewControllerRepresentable`.
- **Objective-C only when no Swift API exists.** Put it in its own target or module, with a comment at the top naming the API that forced it. Never convert Swift to Objective-C for style or speed.
- **No third-party dependencies** without a card whose spec says why Apple's frameworks can't do the job. Prefer `Foundation` (`URLSessionWebSocketTask`, `JSONEncoder`/`JSONDecoder`), `Security` (Keychain) and `Network`.
- The app target defaults to `@MainActor` isolation. Keep protocol and network work in `AHPClient`, off the main actor, and expose it through `async` APIs or `AsyncSequence`s.

## Project file

`VIRT/` and `VIRTTests/` are synchronized folders: Xcode compiles every file in them, so adding, moving or deleting a Swift file needs no change to `project.pbxproj`. Edit `project.pbxproj` only to add a target, a package or a build setting, and keep its object ids unique.

Put new protocol code in `Packages/AHPClient/Sources/AHPClient/` and its tests in `Packages/AHPClient/Tests/AHPClientTests/`. A new package goes under `Packages/` and is added to the project as a local package.

## Tests

```bash
./scripts/test.sh
```

It runs `swift test` on `AHPClient` on the Mac, then `xcodebuild test` on the `VIRT` scheme on an iPhone simulator with the newest installed iOS runtime. Set `VIRT_SIM_DESTINATION` (an `xcodebuild -destination` value, for example `platform=iOS Simulator,name=iPhone 17`) to choose another one.

- Use [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`, `#expect`), not XCTest, for new tests.
- Tests need no network and no AHP host. Test the client against a fake transport or an in-memory host, as guppi does with [its in-memory host](https://github.com/eridanilabs/guppi/tree/main/test/fixtures).
- Every behaviour change in `AHPClient` comes with a test. Test view logic through view models; there are no UI tests yet.

Building needs macOS with Xcode 27 (the iOS 27 SDK). Linux machines, gallifrey included, can't build or test VIRT, so its `/factory` runs and its `guppi serve` run on a Mac.

## The protocol

- The spec is [microsoft/agent-host-protocol](https://github.com/microsoft/agent-host-protocol): JSON-RPC 2.0 over a WebSocket. [guppi/ahp.mjs](https://github.com/eridanilabs/guppi/blob/main/guppi/ahp.mjs) is a small working client to compare against: the connection token goes in the `tkn` query parameter, then `initialize` on the `ahp-root://` channel.
- Follow the spec's message names and shapes exactly. If the spec and a host disagree, say so in the spec (`spec.md`) or PR, and match the host VIRT targets: VS Code's `code agent host` for now, as guppi does.

## Security

- The host's connection token is a secret. Keep it only in the Keychain. Never log it, put it in `UserDefaults`, a file, a URL the app shows, a crash report or an analytics event.
- Connect with `wss://`. Allow plain `ws://` only to a loopback address (a host on the same Mac as the simulator). A tailnet address isn't loopback: reach a remote host through TLS, for example `tailscale serve` with HTTPS.
- Don't weaken App Transport Security globally (`NSAllowsArbitraryLoads`). A narrow exception needs its own card.
- Treat everything from the host as untrusted input: decode it strictly, and never run or render it as code or HTML.

## Docs

Write plain, short sentences in present tense. When a change alters how VIRT is built, run or connected, update [README.md](README.md) in the same PR.
