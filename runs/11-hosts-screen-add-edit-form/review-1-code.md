# Review r1: code (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (convention) VIRT/HostsView.swift:67: `HostLibrary.preview` is a production-target extension that is not under `#if DEBUG`. It ships in release builds and opens a persistent `UserDefaults` suite named `com.eridanilabs.virt.preview`. Fix: wrap the extension and the `#Preview` blocks that use it in `#if DEBUG`, or move it to a preview-only file.
- [nit] (convention) VIRT/HostFormViewModel.swift:95: `save()` trims the token before storing it, so a token with leading or trailing whitespace is stored changed. The spec doesn't ask for this, and it hides a mistyped token instead of surfacing it. Fix: keep trimming only for the blank check (`!trimmedToken.isEmpty`) and pass the raw `token` to `save(_:token:)`, or note the trimming in the doc comment.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift:41: `update(_:)` adds a `HostLibraryError.hostNotFound` case that the spec doesn't mention. It is small, tested (`updateOfAnUnsavedHostSavesNothing`) and keeps `update` from silently adding a host without a token, so I'm leaving it as is.
- [note] VIRT/HostFormViewModel.swift:104: the `CustomReflectable`/`description` overrides satisfy AC8, and `formNeverDescribesTheToken` covers `String(describing:)`, `String(reflecting:)`, `dump` and the save-failure message.
- [note] Edit mode with a new token calls `save(_:token:)`, which writes the token before the host. If the host were deleted in between, it would be re-added with the new token. Nothing in the app can trigger this today, so no action.

## Coverage
- Files read: AGENTS.md, spec.md, `git diff origin/main...HEAD` in full (HostLibrary.swift and its tests, HostFormViewModel, HostFormView, HostsView, HostsViewModel, VIRTApp, README, deleted ContentView), VIRTTests/HostsViewModelTests.swift
- Flows walked:
  - Launch to Hosts list: load, sort by name (case-insensitive), empty overlay, and the toolbar and empty-state Add host buttons.
  - Add: validation, refusal and CGNAT warning, save, list reload, token cleared.
  - Edit: fields prefilled, token empty, blank token goes through `update`, new token goes through `save`, and the token is never read from the Keychain.
  - Swipe delete: success, and token-delete failure keeps the host and shows an error.
  - Save failure: refusal message and generic message, with no token in either.
  - Double-tap Save is blocked by `isSaving`.
  - Each acceptance criterion AC1–AC8 maps to a test that fails without the change.
- Commands run: `./scripts/test.sh` → VIRTKit `swift test` passed (21 tests), and every app test case shown in the tail passed, including the 17 `HostsViewModelTests` cases. I piped the output through `tail`, so I didn't capture the script's exit code or a final "TEST SUCCEEDED" line.
- Earlier blockers: none (round 1)
