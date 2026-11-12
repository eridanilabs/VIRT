# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (simplicity) Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift:84-93: The two new tests write out by hand what the file's table-driven `evaluates(_:)` test already does. That test is fed by the `accepted` and `refused` arrays and also checks `isAccepted`, `warning` and `refusal`. Fix: add `"wss://machine.tailnet.ts.net:8443"` to `accepted`, and `("wss://machine.tailnet.ts.net:8443?tkn=x", .query)` to `refused`, with a one-line comment saying they guard the README's example URL.
- [note] Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift:84-93: These are guard tests, so they pass on `origin/main` too. That's expected, because the change only adds docs and the spec says the code doesn't change (AC5). They will fail if the policy ever stops accepting the URL the README tells people to use.
- [note] README.md:105-115: Pasting with `pbcopy < token` may bring a trailing newline into the token field. That's safe: `HostFormViewModel.trimmedToken` strips whitespace and newlines before saving.
- [note] README.md:84-136: Each acceptance criterion maps to text:
  - **AC1:** the example port is 8443, ports other than 48765 are allowed, the URL has no path, query or token, and you can find the name with `tailscale status`, the admin console or the address `serve` prints.
  - **AC2:** the Mac route uses `pbcopy` and Universal Clipboard, then clears the clipboard, with typing the token as the fallback. The README says VIRT sends the token itself.
  - **AC3:** it covers `tailscale serve --https=8443 off`, `tailscale serve status` and the warning about `tailscale serve reset`.
  - **AC4:** the checklist covers all four items.
  - **AC5:** the diff touches only `README.md` and a test file.
## Coverage
- Files read: AGENTS.md, spec.md, README.md (whole file), Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift, Packages/VIRTKit/Tests/VIRTKitTests/HostURLPolicyTests.swift (whole file), VIRT/HostFormViewModel.swift, VIRT/HostFormView.swift (token section); grepped VIRT/ for the UI strings the README names ("Add host", "Connected · protocol", "Token").
- Flows walked:
  - **Adding a host with the documented URL:** `HostFormViewModel.urlError`/`canSave` → `HostURLPolicy.evaluate`. `wss://` returns accepted before the host check, so the tailnet check doesn't run. The same URL with `?tkn=` is refused with the `.query` message.
  - **Pasting the token:** the pasted token is trimmed before `library.save`.
  - **README links and UI labels:** the link to `#reach-a-guppi-host-over-tailscale` resolves to the new heading. The "Add host" button and the "Connected · protocol …" status match the app's strings.
- Commands run:
  - `git diff origin/main...HEAD` → 2 files: README.md (+55/−1) and HostURLPolicyTests.swift (+11). `git status` is clean.
  - `./scripts/test.sh` → exit 0. 58 VIRTKit tests passed, including both new ones, and the app tests on the iPhone simulator passed.
