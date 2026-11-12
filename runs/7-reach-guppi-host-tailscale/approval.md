# Approval r1 (claude-opus-5.5)

DECISION: APPROVE
Reason: The diff changes only README.md and an 11-line guard test in `HostURLPolicyTests.swift`. All 5 acceptance criteria are met, `./scripts/test.sh` passes, and the run is 11 changed code lines against a limit of 400 (the spec estimated 0).
Escalation: none

**Tests:** The repo has no `package.json`, so `npm test` doesn't apply. I ran its test command, `./scripts/test.sh`, instead. It exited 0: all 58 VIRTKit package tests passed, including the 2 new ones, and the app tests on the iPhone 18 Pro simulator passed with no failures.

**Acceptance criteria:**
- **AC1:** The README tells you to run `tailscale serve --bg --https=8443 http://127.0.0.1:48765` and says any free port other than 48765 works. It gives the URL `wss://<machine>.<tailnet>.ts.net:8443` with no path, query or token, and says to find the name with `tailscale serve`, `tailscale status` or the admin console.
- **AC2:** It gives the Mac route (`pbcopy` and Universal Clipboard, then clear the clipboard) and the fallback (`cat` the token and type it). It says VIRT sends the token itself, so it never goes in the URL.
- **AC3:** It covers `tailscale serve --https=8443 off` and `tailscale serve status`, and warns that `tailscale serve reset` also removes VS Code's `--tcp 48765` forward.
- **AC4:** The "If it doesn't connect" checklist has all 4 items.
- **AC5:** Nothing changed in the app code, `Info.plist` or `project.pbxproj`.

**The other merge conditions:**
- **Reviews:** All 3 selected reviewers (code, security, ux) passed with no blockers. Triage filed all 7 nits under Polish issue #13. There are no `upgraded:` or `downgraded:` rows and no parked security blockers.
- **Skipped reviewers:** Neither skip was wrong. reviewer-ops wasn't needed because no scripts, workflows, Xcode project files or packages changed. reviewer-ui-design wasn't needed because no visual files or SwiftUI views changed.
- **Labels:** The only label is `factory`, not `external`.
- **New access:** The diff adds no dependency, network call or file access.

The README steps haven't been tried on a real guppi host and iPhone yet. The spec leaves that check to a person before milestone 0 closes, so it doesn't block this merge.
