# Review r1: ui-design (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [nit] (polish) VIRT/SessionChatView.swift:73: The tool call row's icon is now `chevron.right` / `chevron.down` instead of `wrench.and.screwdriver`. That causes two problems. First, a collapsed tool call no longer looks different from other rows. Second, `chevron.right` already has a meaning in this app: `DisclosureChevron` (VIRT/HostsView.swift:115-123) puts it at the end of a row, in `.tertiary`, to show that the row opens another screen. Here the same glyph sits at the start of the row and means "collapsed". Fix: keep the wrench as the Label's icon. Show expand and collapse with a small chevron after the text that rotates 90° when expanded, in `.footnote.weight(.semibold)` / `.tertiary` like `DisclosureChevron`. Or use a `DisclosureGroup` and let it draw the system disclosure indicator.
- [nit] (polish) VIRT/SessionChatView.swift:68-80: Expanded detail lines sit in the outer `VStack(alignment: .leading)`, so they line up under the icon and not under the summary text. That looks off next to the Label above them. They are also separated by a hard-coded `spacing: 4`, and no other view in `VIRT/` sets an explicit spacing. Fix: move the `ForEach` of details into the Label's title, as `VStack(alignment: .leading) { Text(summary); if expanded { … } }`, so the lines line up with the summary. Use the default stack spacing.
- [note] VIRT/SessionChatView.swift:62: Replies use `Text(AttributedString)` with the default body font, so inline `code` runs use SwiftUI's built-in monospaced styling and scale with Dynamic Type. No new colors or fonts are hard-coded. Detail lines have no `lineLimit`, so long tool messages wrap and don't spill off the screen at 320 pt. The summary keeps `.lineLimit(1)` as before.
- [note] VIRT/SessionChatView.swift:82-83: The tool call text keeps the existing `.caption` / `.secondary` styling, which matches the sibling captions in HostsView and HostSessionsView. Contrast is unchanged from main.
## Coverage
- Files read: AGENTS.md, the spec (.eridanilabs/autofactory/runs/36-chat-markdown-tool-calls-scroll/spec.md), the pinned agent file, the LOOP.md Severity section, VIRT/SessionChatView.swift (full), VIRT/SessionChatViewModel.swift (diff), Packages/VIRTKit/Sources/VIRTKit/ChatMarkdown.swift, Packages/VIRTKit/Sources/VIRTKit/SessionChat.swift (diff), VIRT/HostsView.swift (rows, HostStatusLine, DisclosureChevron), and a grep of the font, color, spacing and chevron patterns in VIRT/*.swift.
- Design system: there are no custom tokens and Assets.xcassets has only AccentColor and AppIcon. The views use SwiftUI semantic fonts and styles (`.caption`, `.secondary`, `.tertiary`), with `DisclosureChevron` as the shared disclosure glyph. I compared the new elements against those.
- Flows walked (by reading the code; I didn't run the app or take screenshots):
  - Reply rendering: inline bold, italic and code, with links removed.
  - Tool call row: collapsed, then expanded, then collapsed again; no details; a long summary or detail line at a narrow width.
  - The chat's overlay states (failed, empty, loading) are unchanged.
  - Scroll following (behaviour is for reviewer-ux; it adds no visual elements).
- Commands run:
  - `git diff --stat f6a41eb...HEAD` → 7 files.
  - `git diff f6a41eb...HEAD -- VIRT Packages/VIRTKit/Sources`.
  - `./scripts/test.sh | tail -30` → every test case shown passed, including `toolCallStartsCollapsedAndTogglesAndStaysExpandedAcrossUpdates`. I piped the output through `tail`, so the exit code I got back is `tail`'s, not the script's, and I didn't see the final summary line.
- Earlier blockers: none (round 1).
