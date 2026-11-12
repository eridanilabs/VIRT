# Build r1 (claude-opus-5.5)

## Summary
I added a "Reach a guppi host over Tailscale" section to README.md, under "Connecting to a host". It covers publishing the host with `tailscale serve --https=8443`, the matching `wss://` URL in VIRT, getting the token onto the iPhone without a chat, issue or screenshot, how to stop serving, and an "If it doesn't connect" checklist. Two Swift Testing tests check the URL the README gives. `./scripts/test.sh` passes: 58 package tests and 64 app tests, none failed. Nobody has tried the steps on a real guppi host and iPhone yet; the spec's test plan leaves that to a person.

## Changes
- `README.md`:
  - **On the host machine:** check the host with `guppi host status`, then run `tailscale serve --bg --https=8443 http://127.0.0.1:48765`. Any free port works except 48765, because VS Code's `--tcp 48765` uses it. It also says how to find `<machine>.<tailnet>`: `tailscale serve` prints the address, `tailscale status` lists the machine's name, and the admin console shows both.
  - **In VIRT:** the URL is `wss://<machine>.<tailnet>.ts.net:8443` with no path, query or token, because VIRT sends the token itself.
  - **Get the token onto the iPhone:**
    - Mac route: `pbcopy < ~/.eridanilabs/state/guppi/host/token` (or `ssh <host> 'cat …' | pbcopy` when the host is another machine), then Universal Clipboard, then clear the clipboard on both devices.
    - Fallback: `cat` the token in a terminal on the host and type it.
  - **Stop serving:** `tailscale serve --https=8443 off`, and `tailscale serve status` shows what is still served. It warns that `tailscale serve reset` also removes VS Code's `--tcp 48765` forward.
  - **If it doesn't connect:** Tailscale is on and logged in on both devices; MagicDNS and HTTPS certificates are on (the first connection can be slow); `guppi host status` shows the host is up; `tailscale serve status` lists the port in the URL.
  - I also linked the existing `wss://` bullet to the new section. The rules on which URLs VIRT accepts are unchanged.
- `Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift`: extended the existing `HostURLPolicyTests` suite with two tests for the documented URL.
- Nothing else changed: no app code, `VIRT/Info.plist` or `project.pbxproj` (AC5).

## AC coverage
- AC1 → `HostURLPolicyTests` › `acceptsTheREADMETailscaleServeURL` (`wss://machine.tailnet.ts.net:8443` is accepted with no warning) and › `refusesTheREADMETailscaleServeURLWithATokenQuery` (the same URL with `?tkn=x` is refused). The README wording is checked by hand, as the spec plans.
- AC2–AC4 → README sections. Per the spec, a person checks them by following the README on a real host and an iPhone.
- AC5 → `./scripts/test.sh` passes, and the diff touches only `README.md` and a test file.

## Tests
`./scripts/test.sh` exit code: 0.
```
✔ Test acceptsTheREADMETailscaleServeURL() passed after 0.009 seconds.
✔ Test refusesTheREADMETailscaleServeURLWithATokenQuery() passed after 0.009 seconds.
✔ Test run with 58 tests in 9 suites passed after 1.017 seconds.
Test case 'HostsViewModelTests/connectedListsEachRowUpdateInTheOrderReceived()' passed on 'Clone 1 of iPhone 18 Pro - VIRT (67771)' (0.389 seconds)
App tests on the iPhone 18 Pro simulator: 64 passed, 0 failed
```

## Commits
- `02d23fb` docs(readme): explain reaching a guppi host from an iPhone over Tailscale (`Refs: #7`, `Co-authored-by: Copilot`). It is not pushed.

README.md's "Status" line still says VIRT "doesn't show sessions yet", which #40 made out of date. I left it alone because it's outside this card's scope.
