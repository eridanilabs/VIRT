# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) README.md:94: The steps open the guppi host to every tailnet device that the tailnet's access rules (ACLs) allow. Before this, the host listened on loopback only, and it gives control of agent sessions on that machine. Once served, only the token protects it. Line 86 only says both devices "must be on the same tailnet", so someone on a shared tailnet (family, team, or a node shared in from another tailnet) may not realise that the other members can now reach the host. Fix: add one sentence after step 2. It should say that every device the tailnet ACLs allow can reach the served port, that the token is the only guard, and that on a shared tailnet you can limit access to port 8443 with an ACL.
- [nit] (polish) README.md:134: The checklist asks the user to turn on HTTPS certificates without saying what that publishes. Tailscale gets the certificates from Let's Encrypt, so `<machine>.<tailnet>.ts.net` appears in public Certificate Transparency logs. That reveals the machine name and the tailnet name. Fix: add a short clause saying that turning on HTTPS certificates publishes the machine's tailnet name in public certificate logs.
- [nit] (polish) README.md:118: Clearing with `pbcopy < /dev/null` and copying other text on the iPhone empties the current clipboard. It doesn't remove the token from clipboard-history tools on the Mac (Raycast, Alfred, Paste, Maccy), which store every copied item. Fix: add "and delete it from any clipboard-history app", or tell users who have such an app to use the type-it route.
- [note] README.md:119: Whether `clear` also clears the scrollback depends on the terminal. Modern ncurses `clear` with Terminal.app does, but a tmux or screen session, or an ssh session logged by the client, keeps the token. No action needed for this card.
- [note] README.md:102: "VIRT sends the token itself, so it never goes in the URL" means the URL the user types. On the wire, `HostConnector` still adds it as the `tkn` query item (`HostConnector.swift:232-240`), inside TLS to `tailscale serve`, which proxies it to loopback. This matches AC2 and the protocol, and the claim is accurate for what the user enters.
- [note] Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift:84-93: The new tests pin the documented URL as accepted with no warning and the `?tkn=x` form as refused (`.query`). That guards against a later README or policy change that would invite a user to put the token in the URL.

## Coverage
- Files read: AGENTS.md, spec.md (run 7-reach-guppi-host-tailscale), .agents/skills/factory/LOOP.md (Severity), README.md ("Connecting to a host" section in full, lines 57–136), Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift (diff hunk), grep of Packages/VIRTKit/Sources for `tkn`/`connectURL` (HostConnector.swift, TailnetCheck.swift)
- Flows walked:
  - Publishing the host: `tailscale serve --bg --https=8443` to loopback 48765. Checked who can reach it, that it doesn't clash with VS Code's `--tcp 48765`, and that it isn't Funnel (out of scope).
  - The URL entered in VIRT: `wss://` with no query, path or token, checked against `HostURLPolicy` and the new tests.
  - Getting the token onto the iPhone: the Mac-is-host `pbcopy` route, the ssh-to-`pbcopy` route (token not shown in the terminal), the clipboard clearing step, and the type-it fallback (`cat`/`clear`).
  - Stopping the serve: per-port `off`, `serve status`, and the `reset` warning protecting VS Code's forward.
  - The troubleshooting checklist, including the HTTPS certificate exposure.
  - Repo policy: no change to app code, Info.plist, ATS, pbxproj, dependencies or workflows (AC5). No secrets in the diff.
- Commands run:
  - `git log origin/main..HEAD` → 1 commit (02d23fb)
  - `git diff --stat origin/main...HEAD` → README.md and HostURLPolicyTests.swift only
  - `git diff origin/main...HEAD` → reviewed
  - `./scripts/test.sh` → exit 0 (swift test and xcodebuild test on the iPhone 18 Pro simulator, all tests passed)
