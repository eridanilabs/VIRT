# Review r1: code (claude-sonnet-5.5)

VERDICT: CHANGES
## Findings
- [blocker] (ac) VIRT/AppNavigationView.swift:56: No test verifies the bottom-bar icon changes to the chat bubble; the existing suite does not exercise this view. Fix: add a behavior-level UI check for the icon.
- [blocker] (ac) VIRT/AppNavigationView.swift:57: No test verifies the visible label reads “New Session.” Fix: add a behavior-level UI check for the label.
- [blocker] (ac) VIRT/AppNavigationView.swift:53: No test verifies that tapping this bottom-bar button opens the form; the existing view-model test assigns `model.newSession` directly rather than tapping the button. Fix: add a bottom-bar interaction check that confirms the form opens.
## Coverage
- Files read: `AGENTS.md`, `.eridanilabs/autofactory/runs/91-new-session-navigation-label/spec.md`, `.agents/skills/factory/LOOP.md`, `VIRT/AppNavigationView.swift`, `VIRT/HostsViewModel.swift`, `VIRTTests/HostsViewModelTests.swift`; `CONTRIBUTING.md` is absent.
- Flows walked: bottom-bar action → `model.newSession` → `.sheet` → `NewSessionView`; existing form creation flow in `HostsViewModelTests.swift`.
- Commands run: `./scripts/test.sh` → passed; `git diff --check 3c3fdbb0da6954342f4aaca8b1cadbc90e6b9466...HEAD` → passed; `git show 3c3fdbb0da6954342f4aaca8b1cadbc90e6b9466:docs/board-reads.md` → file absent at base.
## Acceptance criteria
| AC | Code | Test |
|----|------|------|
| AC1 | `VIRT/AppNavigationView.swift:56` | none |
| AC2 | `VIRT/AppNavigationView.swift:57` | none |
| AC3 | `VIRT/AppNavigationView.swift:53` | none |
