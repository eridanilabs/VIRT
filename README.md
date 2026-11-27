# VIRT

VIRT is a native iOS app for working with agent sessions away from your desk. It's an [Agent Host Protocol](https://github.com/microsoft/agent-host-protocol) (AHP) client: it connects to an AHP host, such as the one [guppi](https://github.com/eridanilabs/guppi) runs on an always-on machine, and shows that host's sessions.

**Status:** early. VIRT saves hosts, connects to them, lists their sessions and shows a session's chat live, read-only. You can create a session on a connected host, but you can't send messages yet. While VIRT is open, a banner tells you when one of the host's sessions finishes, fails or needs input. The [active milestone](https://github.com/eridanilabs/VIRT/milestones) tracks the work.

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
| [docs/design/](docs/design/) | Design notes and feasibility checks, such as [push display](docs/design/push-display-feasibility.md). |
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
2. Change the pin in `apm.yml`, run `apm install`, then `apm audit --ci`. If `apm install` says it skipped files and asks you to re-sync, run `apm install` again before the audit.
3. Review the diff, `apm.lock.yaml` included, and open a PR.

## Connecting to a host

VIRT opens on the **Hosts** screen. The bottom bar stays visible on the host, session-list and chat screens, with **New**, **Sessions**, **Hosts** and **Settings** in that order. The Sessions, Hosts and Settings screens each show their name at the top. **Sessions** shows working sessions and sessions waiting for input across connected hosts. **Hosts** opens the saved hosts, including failed connections so you can edit or retry them. Tap the floating **+** above the bar on the right to add a host. Enter a name, the host's URL and its connection token. Tap a host to open its details: its name, URL and live status, an **Edit** button at the top right, and **All sessions on this host**, which opens the host's full session list. You can also swipe a host to see **Edit** and **Delete**. The token field is masked, and VIRT never shows a saved token: leave the field blank when you edit a host to keep its token, or type a new one to replace it.

The bottom bar's **New** button creates a new session. Choose a connected host and one of its advertised providers, then enter an absolute working-directory path on that host. VIRT opens the new session's chat after creation. A new idle session doesn't appear under **Sessions** until it works or needs input; it remains in its host's full session list. **Settings** shows the app version and saves your System, Light or Dark appearance choice. Swipe right from the left edge of a chat to return to the session list you opened it from, or from a host's session list to return to its details. VoiceOver's two-finger scrub also goes back. You can also use **Sessions** or **Hosts** to leave a chat; these buttons replace the top back controls.

While VIRT is open, it connects every saved host, including one you add. Tap a host to open its details. A tap never disconnects another host. It reuses a host that is already connecting, connected or reconnecting, and it tries a failed host again. The details screen also shows **Connect** for a host that isn't connected, or **Try again** for a failed one. In-app alerts come from every connected saved host. Tapping one opens the session's chat directly, or on top of its host's session list if that list is already open. Under its URL, each host's row shows that host's own status:

- **Connecting…**: VIRT is opening the connection.
- **Connected · protocol 0.1.0**: the host accepted the token and speaks that protocol version.
- **Reconnecting (attempt 3)…**: the connection dropped, and VIRT is retrying with backoff.
- **Failed: …**: VIRT stopped, and says why. Fix the cause, then tap the host to try again.

A host with no status line isn't connected. One host's failure doesn't change any other host's row. A failed host stays failed until you tap it or come back to VIRT. When VIRT goes to the background, it disconnects every host. When you come back, it reconnects every saved host, failed ones included. Deleting a host disconnects it. Editing a host keeps its connection: the new URL and token take effect on the next attempt.

The guppi host listens on loopback only (`ws://127.0.0.1:48765`). VIRT accepts a host URL that is:

- `wss://` to any host. Use this for a remote host, for example through `tailscale serve` with HTTPS, as [Reach a guppi host over Tailscale](#reach-a-guppi-host-over-tailscale) shows.
- `ws://` to loopback (`localhost`, `127.0.0.1` or `[::1]`), for a simulator on the host's own Mac.
- `ws://` to a tailnet name (`<machine>.<tailnet>.ts.net`), for a host published on its tailnet. WireGuard encrypts tailnet traffic while Tailscale is on, so the token isn't in plain text on the network. The app's App Transport Security exception for `ts.net` and its subdomains, added by card #10, allows this.
- `ws://` to a Tailscale address in `100.64.0.0/10`, with a warning. That range is also carrier-grade NAT space: with Tailscale off, the same address can reach another network, in plain text. VIRT checks Tailscale first, as the next paragraph says, but the host's `.ts.net` name is still preferred.

Before each `ws://` connection to a tailnet name or a `100.x` address, and again on each reconnect, VIRT checks the addresses. This device must have an address in a Tailscale range, `100.64.0.0/10` or `fd7a:115c:a1e0::/48`, which it usually has only while Tailscale is on. The host's name must resolve only to Tailscale addresses, or the address must be one. VIRT then connects to the checked address instead of the name. The check sees only addresses, so it can't prove the host is on your tailnet: a network that uses `100.64.0.0/10` itself, such as a carrier's, can still pass. If the check fails, VIRT shows "This address isn't on your tailnet. Is Tailscale on?" and doesn't send the token.

When a connection fails or drops, VIRT gives a short reason: the host refused the token, it can't reach the host, the secure connection failed, the host uses a protocol version VIRT doesn't support, or iOS blocked a plain connection. After a drop it reconnects with backoff and counts its attempts. A refused token or a version mismatch stops it, because retrying can't help.

VIRT accepts WebSocket messages up to 16 MiB, so large session lists can load. A larger message stops the connection with a size-limit error instead of retrying.

VIRT refuses any other URL, and any URL with a user name, a query or a fragment. The connection token is in `~/.eridanilabs/state/guppi/host/token` on the host. VIRT keeps it only in the Keychain, never in the saved host list.

### Reach a guppi host over Tailscale

The guppi host listens on loopback only. To reach it from an iPhone, publish it on your tailnet with `tailscale serve` over HTTPS, then connect VIRT to it with `wss://`. The host machine and the iPhone must be on the same tailnet.

#### On the host machine

1. Check that the host is up: `guppi host status`. If it isn't, start it with `guppi host start --detach`.
2. Publish the host on your tailnet over HTTPS. This example uses port 8443:

   ```bash
   tailscale serve --bg --https=8443 http://127.0.0.1:48765
   ```

   Any free port works except 48765, which VS Code's own `tailscale serve --tcp 48765` uses. `--bg` keeps the serve running after you close the terminal. Your tailnet's access controls (ACLs) decide which devices can reach the served port, and the token is the only other guard.
3. Find the machine's tailnet name, `<machine>.<tailnet>`. `tailscale serve` prints it in the `https://` address it serves. `tailscale status` lists the machine's name, and the Tailscale admin console shows the machine's full name under **Machines** and the tailnet name under **DNS**.

#### In VIRT

1. Tap **Add host**. Enter a name, for example `Studio`.
2. Enter the URL `wss://<machine>.<tailnet>.ts.net:8443`, for example `wss://studio.tail1234.ts.net:8443`. Use the port you served. Add no path, no query and no token: VIRT sends the token itself, so it never goes in the URL.
3. Put the token in the token field, as the next section shows.
4. Save, then tap the host. VIRT opens the host's details, with its status line, such as **Connecting…**, then **Connected · protocol …**. Tap **All sessions on this host** to see its sessions.

#### Get the token onto the iPhone

The token is in `~/.eridanilabs/state/guppi/host/token` on the host. It's a secret: never paste it into a chat or an issue, and never take a screenshot of it.

- **From a Mac, with Universal Clipboard.** Sign in to the same Apple Account on the Mac and the iPhone, with Handoff on. On the Mac, copy the token:

  ```bash
  pbcopy < ~/.eridanilabs/state/guppi/host/token                 # the Mac is the host
  ssh <host> 'cat ~/.eridanilabs/state/guppi/host/token' | pbcopy  # the host is another machine
  ```

  On the iPhone, paste it into VIRT's token field. Then clear the clipboard: run `pbcopy < /dev/null` on the Mac, copy some other text on the iPhone, and clear any clipboard-history app on either device.
- **Otherwise, type it.** In a terminal on the host, run `cat ~/.eridanilabs/state/guppi/host/token`, type the token into VIRT's token field, then run `clear`.

#### Stop serving

To stop publishing the host, turn off the serve on its port:

```bash
tailscale serve --https=8443 off
```

`tailscale serve status` shows what the machine still serves. Don't use `tailscale serve reset`: it removes every serve, VS Code's `--tcp 48765` forward included.

#### If it doesn't connect

- [ ] Tailscale is on and logged in on both the host machine and the iPhone, on the same tailnet.
- [ ] MagicDNS and HTTPS certificates are turned on for the tailnet, in the admin console under **DNS**. The first connection can be slow while Tailscale issues the certificate. The certificate puts the served name, `<machine>.<tailnet>.ts.net`, in public Certificate Transparency logs, so anyone can learn the name, though only your tailnet can reach it.
- [ ] The host is up: `guppi host status`.
- [ ] `tailscale serve status` lists the serve on the port in VIRT's URL.
- [ ] VIRT doesn't say "The host refused the token." If it does, the token in VIRT doesn't match the host's: copy `~/.eridanilabs/state/guppi/host/token` again, as above, then tap the host, tap **Edit**, paste the token, tap **Save** and tap **Try again**.
