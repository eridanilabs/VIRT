# Spec: Document reaching a guppi host from an iPhone over Tailscale

## Goal
Someone with a guppi host and an iPhone on the same tailnet can follow the README to connect VIRT to that host over `wss://`. The steps keep the token out of chats, issues and screenshots, show how to stop serving, and say what to check when the connection fails.

## Acceptance criteria
- AC1: README.md's "Connecting to a host" section has a step-by-step subsection for the host machine. It runs `tailscale serve --bg --https=<port> http://127.0.0.1:48765` with one concrete example port, such as 8443. That port is not 48765, so it doesn't clash with VS Code's `tailscale serve --tcp 48765`. The subsection gives the matching VIRT URL, `wss://<machine>.<tailnet>.ts.net:<port>`, with no path, query or token. It also says how to find `<machine>.<tailnet>` (`tailscale status` or the admin console).
- AC2: The section says how to get the token from `~/.eridanilabs/state/guppi/host/token` into VIRT's token field without a chat, an issue or a screenshot. It names a Mac route (`pbcopy` plus Universal Clipboard, then clear the clipboard) and a fallback (read it in a terminal on the host and type it). It says VIRT adds the token itself, so it never goes in the URL.
- AC3: The section shows how to stop serving with `tailscale serve --https=<port> off`, and how to check what is served with `tailscale serve status`. It warns that `tailscale serve reset` would also remove VS Code's `--tcp 48765` forward.
- AC4: The section has a "If it doesn't connect" checklist: Tailscale is on and logged in on both devices; MagicDNS and HTTPS certificates are turned on for the tailnet (the first connection can be slow while the certificate is issued); the host is up (`guppi host status`); and the serve is listed in `tailscale serve status` on the port in the URL.
- AC5: Nothing changes in the app code, `VIRT/Info.plist` or `project.pbxproj`. `wss://` to any host is already accepted, and the existing `ts.net` ATS exception doesn't affect `wss://`. `./scripts/test.sh` still passes.

## Out of scope
- Steps for plain `ws://` to the `.ts.net` name. For that route the host would need a plain listener (for example `tailscale serve --http=<port>`). VIRT also connects to the address it checked (`100.x`), not to the name (see `TailnetCheck.connectURL`), and no one has checked that a name-keyed serve handler answers a request made to that address. That needs its own card.
- Tailscale Funnel, or exposing the host beyond the tailnet.
- The guppi side (`docs/always-on-host.md`) and any change to how guppi listens.
- An in-app setup guide or a QR-code token import.

## Assumptions
- The smallest reading covers the `wss://` route only. The feature text makes `ws://` optional.
- 8443 is the example port. Any free port other than 48765 works, and the README says so.
- The VS Code agent host behind guppi accepts a WebSocket that `tailscale serve` proxies from HTTPS to `http://127.0.0.1:48765`. The person checking against a real host confirms this before milestone 0 closes.
- The README keeps the existing rules on which URLs VIRT accepts and only adds the new steps.

## Likely files
- `README.md`: new subsections under "Connecting to a host" for publishing the host, getting the token onto the phone, stopping the serve and troubleshooting.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift`: optional guard test for the documented example URL.

## Test plan
- AC1 → `Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift`: `HostURLPolicy().evaluate` accepts `wss://machine.tailnet.ts.net:8443` with no warning, and refuses the same URL with `?tkn=x`.
- AC1–AC4 → manual: a person follows the README on a real guppi host and an iPhone. They get **Connected · protocol …**, then run the stop command and see VIRT fail to reach the host.
- AC5 → `./scripts/test.sh` passes. The diff touches only `README.md` and test files.

## Size estimate
Estimate: 0 code lines
- README steps to publish the host with `tailscale serve --https` on a port other than 48765, and the matching `wss://` URL
- README steps to get the token onto the phone without a chat, issue or screenshot
- README steps to stop serving and check what is served
- README checklist for when connecting fails
