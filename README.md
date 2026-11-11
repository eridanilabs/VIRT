# VIRT

VIRT is a native iOS app for working with agent sessions away from your desk. It's an [Agent Host Protocol](https://github.com/microsoft/agent-host-protocol) (AHP) client: it connects to an AHP host, such as the one [guppi](https://github.com/eridanilabs/guppi) runs on an always-on machine, and shows that host's sessions.

**Status:** a scaffold. The app builds and its tests pass, but it doesn't connect to a host yet. The [active milestone](https://github.com/eridanilabs/VIRT/milestones) tracks the work.

## Layout

| Path | Holds |
|------|-------|
| [VIRT/](VIRT/) | The SwiftUI app. |
| [VIRTTests/](VIRTTests/) | The app's unit tests. |
| [Packages/VIRTKit/](Packages/VIRTKit/) | VIRT's non-UI logic, a local Swift package built on the official AHP Swift client. |
| [VIRT.xcodeproj/](VIRT.xcodeproj/) | The Xcode project, with the shared `VIRT` scheme. |
| [scripts/test.sh](scripts/test.sh) | Runs every test. CI and `/factory` run it too. |
| [AGENTS.md](AGENTS.md) | Conventions for people and agents changing VIRT: Swift first, tests and security. |
| [docs/milestones.md](docs/milestones.md) | How work is planned and scheduled. |
| [.eridanilabs/guppi.json](.eridanilabs/guppi.json) | guppi's team defaults for this repo: work the active milestone, with `/factory <n>`. |
| [apm.yml](apm.yml), [apm.lock.yaml](apm.lock.yaml) | The APM manifest and lockfile that pin [autofactory](https://github.com/eridanilabs/autofactory). |

## Building

You need a Mac with Xcode 27 and an iOS 27 simulator runtime. Linux machines can't build VIRT.

```bash
open VIRT.xcodeproj      # then run the VIRT scheme on a simulator
./scripts/test.sh        # every test: VIRTKit on the Mac, then the app on a simulator
```

`scripts/test.sh` picks an iPhone on the newest installed iOS runtime. Set `VIRT_SIM_DESTINATION` to choose one, for example `VIRT_SIM_DESTINATION='platform=iOS Simulator,name=iPhone 17' ./scripts/test.sh`.

VIRT talks to hosts through the official Swift client from [microsoft/agent-host-protocol](https://github.com/microsoft/agent-host-protocol) (`AgentHostProtocolClient`), pinned exactly in [Packages/VIRTKit/Package.swift](Packages/VIRTKit/Package.swift). Swift Package Manager fetches it on the first build.

To run on a device, choose your team under *Signing & Capabilities* in Xcode. The project commits no team.

CI runs `scripts/test.sh` on GitHub's `xcode-27` preview runner for every PR and every push to `main`.

## How work happens

VIRT is built with `/factory` from [eridanilabs/autofactory](https://github.com/eridanilabs/autofactory), installed as an APM package pinned in [apm.yml](apm.yml). Each feature is an issue on VIRT's Project board. `/factory <issue>` takes it through spec, build, review, approval and merge.

[guppi](https://github.com/eridanilabs/guppi) runs those `/factory` sessions unattended, one card at a time, from the active milestone. Because VIRT builds only on macOS, run its guppi on a Mac with Xcode, not on a Linux host:

1. Clone VIRT on the Mac, and keep that checkout on a clean `main`. guppi works in it.
2. Install the factory: `apm install` (autofactory is private, so `apm` needs a `gh` login that can read it).
3. Start an AHP host on the same Mac: `guppi host start --detach`. guppi sends the checkout's local path to the host, so they must share a machine.
4. Register the repo from inside the checkout: `guppi repo add`, then check it with `guppi repo list`.
5. Run `guppi serve` (once per machine; it runs every registered repo).

To work a card by hand instead, run `/factory <issue>` in Copilot from the checkout.

### Updating autofactory

1. Check that `node .agents/skills/factory-board/board.mjs status` shows no card in Spec, Build, Review or Approve.
2. Change the pin in `apm.yml`, run `apm install`, then `apm audit --ci`.
3. Review the diff, `apm.lock.yaml` included, and open a PR.

## Connecting to a host

VIRT opens on the **Hosts** screen. Tap **Add host**, then enter a name, the host's URL and its connection token. Tap a host to edit it, and swipe to delete it. The token field is masked, and VIRT never shows a saved token: leave the field blank when you edit a host to keep its token, or type a new one to replace it.

The guppi host listens on loopback only (`ws://127.0.0.1:48765`). VIRT accepts a host URL that is:

- `wss://` to any host. Use this for a remote host, for example through `tailscale serve` with HTTPS.
- `ws://` to loopback (`localhost`, `127.0.0.1` or `[::1]`), for a simulator on the host's own Mac.
- `ws://` to a tailnet name (`<machine>.<tailnet>.ts.net`), for a host that listens on its tailnet address. WireGuard encrypts tailnet traffic, so the token isn't in plain text on the network. The app's App Transport Security exception for `ts.net` and its subdomains, added by card #10, allows this.
- `ws://` to a Tailscale address in `100.64.0.0/10`, with a warning. That range is also carrier-grade NAT space: with Tailscale off, the token goes in plain text to whatever network uses the address. Use the host's `.ts.net` name instead.

VIRT refuses any other URL, and any URL with a user name, a query or a fragment. The connection token is in `~/.eridanilabs/state/guppi/host/token` on the host. VIRT keeps it only in the Keychain, never in the saved host list. The milestone that adds connecting documents the exact setup.
