# Review r1: ux (default)

VERDICT: PASS
## Findings
- [nit] (polish) README.md:137: The refused-token recovery step skips saving. It reads "edit the host, paste the token and tap the host", but the edit form only keeps a new token after you tap **Save** (`HostFormView`'s confirmation action). "Copy … again, as above" also leaves out readers who used the "Otherwise, type it" path. Fix: "…get the token again, as above, then swipe the host, tap **Edit**, enter the token, tap **Save** and tap the host."
- [nit] (polish) README.md:78: The parenthetical sits between "a Tailscale range" and the ranges it names, so the two ranges read like a separate clause: "an address in a Tailscale range (usually only while Tailscale is on), `100.64.0.0/10` or `fd7a:115c:a1e0::/48`." Fix: "This device must have an address in a Tailscale range, `100.64.0.0/10` or `fd7a:115c:a1e0::/48`, which it usually has only while Tailscale is on." This keeps the spec's wording and makes it read clearly.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:51: The form shows `urlError` live as you type. Someone who types a bare host such as `studio.tail1234.ts.net:8443`, or just `s`, has typed no scheme, but sees "…, not this scheme." This is the exact string AC1 requires, so no action this round. A later card could phrase it so it also fits input with no scheme ("…Start the URL with wss://").
- [note] Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift:53: The example `wss://my-host.example.com` differs slightly from the URL field's placeholder `wss://host.example.com` (`HostFormView.swift:14`). AC1 requires this text exactly, and it's harmless.
- [note] VIRT/HostFormViewModel.swift:85-93: The `_ =` discards change nothing a user sees. The form already shows `urlWarning` before you save, so the warning the save returns adds nothing there.
## Coverage
- Files read: the spec, AGENTS.md (no CONTRIBUTING.md exists), README.md (lines 55–140), VIRT/HostFormViewModel.swift, VIRT/HostFormView.swift, VIRT/HostsView.swift, VIRT/HostSessionsView.swift, VIRT/HostsViewModel.swift (status text), Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift, and the diffs for HostConnector.swift, HostLibrary.swift, AGENTS.md and README.md.
- Flows walked:
  - **Add a host from the README's "In VIRT" steps.** Checked the Name field, the "Add host" button and the URL field's live error and warning footer. The README's example URL is accepted. Step 4 matches the code: HostSessionsView shows the status line until the host connects, then its sessions, and the Hosts row shows "Connected · protocol …".
  - **URL refusals shown live in the form.** Checked the new missingHost and unsupportedScheme text, including input with no scheme and partly typed input.
  - **Recovering from a refused token.** The README quote matches the app's "Failed: The host refused the token. Edit the host to update it." The way to Edit (swipe the row) is documented at README:60.
  - **Edit and save.** Both `save` calls use `_ =`, with no change a user sees. A blank token keeps the saved one through `update`.
  - **Connected with no host (AC3).** "Connected" can no longer appear with a blank protocol version.
  - **Doc accuracy.** Checked the AGENTS.md security bullet and the README's tailnet check, ACL, Certificate Transparency and clipboard-history wording against AC6.
- Commands run:
  - `git diff c6f267b...HEAD --stat` and the per-file diffs → 11 files.
  - grep for the UI strings the README quotes → all present in the app.
  - `./scripts/test.sh` → exit 0, all tests passed.
  - `git status --short` → clean.
