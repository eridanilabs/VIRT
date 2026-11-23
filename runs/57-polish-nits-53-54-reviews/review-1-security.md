# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
No findings.
- [note] VIRT/HostsView.swift:53: With a chat open, the Hosts screen now announces the status. The text it announces is the same `HostConnector.Status.text` the sessions screen already announced. It holds a fixed phrase, a version string that must pass a strict pattern check, or `failure.message`, and its doc comment says it never holds the token or a URL. So no new data reaches VoiceOver.
- [note] VIRT/HostsView.swift:59: The new announcement after a failed load uses only fixed text. It includes nothing from the host or from the saved data.
- [note] Packages/VIRTKit/Sources/VIRTKit/TailnetCheck.swift:87 and README.md:78: The doc comment and README now say the check can't prove the host is on your tailnet. That matches the `ws://` rule in AGENTS.md's Security section, and no code in the check changed.
- [note] README.md:137: The refused-token step points only to the token file path, `~/.eridanilabs/state/guppi/host/token`, which README already gave. No token value appears.

## Coverage
- Files read: AGENTS.md, spec.md, LOOP.md (Severity), the full diff for all 9 files, VIRT/HostSessionsViewModel.swift (whole file), VIRT/HostsView.swift (whole file), VIRT/HostsViewModel.swift (`Status.text` / `isPlainVersion`), scripts/test.sh
- Flows walked:
  - **Status announcement:** Hosts screen only; sessions screen on top; chat pushed over the sessions screen; chat popped. I checked where the announced text comes from and that it never holds the token or a URL.
  - **Host load:** the first load fails, then **Retry** fails again, then a load succeeds. The announcement uses only fixed text.
  - **Tapping a session row:** the chat model moved from the view's `@State` into `HostSessionsViewModel.chat`. Equality and hashing are still by object identity, so this changes no trust boundary.
  - **Docs:** I checked the TailnetCheck doc comment and README's check paragraph against the `ws://` rule in AGENTS.md.
  - **Supply chain:** no new dependencies, network calls, entitlements, Info.plist or ATS changes, and no project or workflow changes.
- Commands run:
  - `git diff 47c8e8b...HEAD` and `git log`: 3 commits, 9 files.
  - `./scripts/test.sh 2>&1 | tail -40`: finished, and the last 40 lines show only passing app tests and no failure. The output went through `tail`, so the exit code I saw (0) is `tail`'s, not the script's. The VIRTKit and test-summary lines fell outside those 40 lines.
