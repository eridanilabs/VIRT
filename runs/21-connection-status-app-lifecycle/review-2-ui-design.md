# Review r2: ui-design (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (responsive-layout) VIRT/HostsView.swift:94: Non-failed status lines use `.lineLimit(1)`. At 320pt wide or at large Dynamic Type or 200% zoom, "Connected · protocol <up to 16 chars>" and "Reconnecting (attempt N)…" truncate with an ellipsis. Sighted users then lose the attempt number or protocol. The version is now capped at 16 plain characters, so the text is bounded and wrapping is safe. Fix: remove the limit, or use `.lineLimit(2)`, as the failed branch already wraps. I didn't run the app, so I haven't seen this at 320pt.
- [note] VIRT/HostsView.swift:80: Round 1's red-contrast and `.tint(.blue)` nits are fixed. Failure text is now `.secondary` with a red `exclamationmark.triangle.fill` icon, so the red is no longer text, and a graphic only needs 3:1, which system red meets. The "Failed:" prefix is kept, so colour isn't the only cue. The Edit swipe action uses `.tint(.accentColor)`.
- [note] VIRT/HostsView.swift:21: The visual status line is hidden from VoiceOver (`.accessibilityHidden(true)`), and the same text is exposed through `.accessibilityValue`. A selected-status announcement is also posted through `onChange`. I treated the double exposure as the UX reviewer's lane.
- [note] VIRT/HostsView.swift:80: The failed `Label` uses `.font(.caption)` and the same `.secondary` style as the sibling captions, so it matches the other rows. The icon sits in the system label slot and wraps with the text. This is unverified visually.

## Coverage
- Files read: AGENTS.md, VIRT/HostsView.swift (delta and surrounding code), VIRT/HostsViewModel.swift (`text(for:)`, `isPlainVersion`), review-1-ui-design.md, triage-1.md, triage-1.2.md
- Flows walked: host row status display for idle, connecting, connected (plain and non-plain version), reconnecting and failed; swipe actions; VoiceOver value and announcement markup
- Commands run: `git diff 4588d24..HEAD --stat` and the diff of `VIRT/` → read. I did not run the app or `./scripts/test.sh`, which is another reviewer's lane.
- Earlier blockers: none raised in round 1. Both round 1 nits (red contrast, `.tint(.blue)`) are fixed.
