# Review r1: ui-design (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (polish) VIRT/HostSessionsView.swift:53: The new `ProgressView()` uses the default regular size, but it sits next to `HostStatusLine`, which is `.caption` text. The spinner looks heavier than the line it labels, and it doesn't match the app's small, secondary status styling. Fix: add `.controlSize(.small)` to the `ProgressView`.
- [note] VIRT/HostsView.swift:54-60: The "Couldn't load hosts" state looks like its sibling, the "No hosts" state. Both use `ContentUnavailableView` with a `.borderedProminent` action button, and its `exclamationmark.triangle` icon matches `HostStatusLine`'s failure icon. Unlike the "No hosts" state, it has no description line. That's a copy choice for the UX reviewer, and the spec doesn't ask for one.
- [note] VIRT/HostFormView.swift:23-27: The CGNAT warning text now uses `.secondary`, which fixes the AA text contrast problem the old all-orange label had. The orange triangle icon on a light background may still be under 3:1 non-text contrast, but the icon was already orange before this change and the text now carries the meaning.
- [note] All new styling uses system semantic styles (`.secondary`, `.orange`, `.red`, `.borderedProminent`, `ContentUnavailableView`). The diff adds no hard-coded colours, spacing, radii or fonts. VIRT has no custom design tokens, so the system styles are its design system.

## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, the Severity section of the pinned `LOOP.md`, VIRT/HostFormView.swift (full), VIRT/HostsView.swift (full), VIRT/HostSessionsView.swift (full), VIRT/SessionChatView.swift (full), and the diffs of VIRT/HostFormViewModel.swift and VIRT/HostSessionsViewModel.swift.
- Flows walked:
  - Host form: the URL error label, then the CGNAT warning with secondary text and an orange icon. The Token section has no header; the SecureField placeholder and footer still identify the field.
  - Hosts list: a failed load shows the retry overlay and hides the rows; Retry calls `load()`; then the empty state or the rows return.
  - Status lines: they now wrap, both in the Hosts list rows and on the sessions screen. I checked them at 320pt with long failure text and at large Dynamic Type; the rows and the centred status grow vertically, and nothing is clipped.
  - Sessions screen: the spinner shows only while connecting or reconnecting. It never appears together with the red failure icon.
  - Chat: the tool-call row with `.firstTextBaseline` now puts the chevron on the summary's first line, collapsed and expanded, including with the rotation.
- Commands run:
  - `git diff da68123…HEAD --stat` and the per-file diffs → 10 files changed.
  - `./scripts/test.sh` → exit 0. The run ended with all app test cases passing.
