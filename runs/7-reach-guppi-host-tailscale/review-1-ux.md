# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) README.md:105: Step 4 says "Save, then tap the host. Its row shows **Connected · protocol …**". On `origin/main` (#40), tapping a host also opens that host's own screen (`HostsView.swift:16-17`, `navigationDestination`). That screen shows "Connecting…", then the sessions list or "No sessions" (`HostSessionsView.swift:11-41`). It never shows "Connected · protocol …". The user only sees that status on the row after going back to **Hosts**, so the success sign the guide promises isn't on screen when they look. Fix: "Save, then tap the host. Its screen shows **Connecting…**, then its sessions, or **No sessions**. Back on **Hosts**, its row shows **Connected · protocol …**."
- [nit] (polish) README.md:102-105: The "In VIRT" steps skip the name. **Save** stays off until the form has a name, a URL VIRT accepts and a token (`HostFormViewModel.swift:69-72`). Someone who follows only these numbered steps can't save. Fix: after "Tap **Add host**", add "Enter a name, for example `Studio`."
- [nit] (polish) README.md:132-136: The "If it doesn't connect" list doesn't cover a wrong token, which is a likely failure after copying it across devices. It also doesn't link VIRT's **Failed: …** reasons to the right check. Fix: add one item, such as "If VIRT says the host refused the token, copy it again from the host and replace it: swipe the host, tap **Edit** and enter the new token."
- [note] README.md:73: The anchor `#reach-a-guppi-host-over-tailscale` matches the GitHub slug of the new heading.
- [note] README.md:89,108,136: The README's `guppi host status`, `guppi host start --detach` and `~/.eridanilabs/state/guppi/host/token` match what guppi uses (`guppi/test/host.test.mjs`, `test/settings.test.mjs`).
- [note] README.md:113-118: The token file may end with a newline that `pbcopy` copies too. That's harmless because VIRT trims the token before saving it (`HostFormViewModel.swift:50`).
- [note] Check against the spec: AC1 to AC4 are all in the README, including the line saying the token never goes in the URL. The spec's ATS question, the plain `ws://` route and Funnel are out of scope and aren't raised.

## Coverage
- Files read: AGENTS.md, spec.md, README.md (whole "Connecting to a host" section, new and existing parts), Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift (the diff), Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift, VIRT/HostFormView.swift, VIRT/HostFormViewModel.swift, VIRT/HostsView.swift, VIRT/HostSessionsView.swift, VIRT/HostSessionsViewModel.swift, the `## Severity` section of .agents/skills/factory/LOOP.md, and guppi's test/host.test.mjs and test/settings.test.mjs (to confirm commands and the token path).
- Flows walked:
  - Following the README from start to finish: on the host machine (status, serve, finding the name), then in VIRT (Add host, entering the URL, the token, Save, tapping the host and the screen it opens).
  - Getting the token onto the phone: from a Mac that is the host, from a Mac with a separate host over ssh, and the type-it fallback. Clearing the clipboard afterwards.
  - Stopping the serve and checking it with `serve status`, plus the `reset` warning.
  - The "If it doesn't connect" checklist.
  - What the URL policy does with the example URL and the `?tkn=` version.
  - The link from the URL rules list to the new section.
- Commands run:
  - `git diff origin/main...HEAD`: README.md and HostURLPolicyTests.swift only. The merge base is origin/main at 61220e2.
  - `./scripts/test.sh` (piped to `tail`): ran to the end with every test case shown passing and no failure. The pipe hid the script's own exit code.
