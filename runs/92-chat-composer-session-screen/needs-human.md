## Needs human

Reason: Approver escalated on size alone. The change is 458 code lines against a 400-line limit; the spec estimated 260 code lines.

Evidence: [approval.md](https://github.com/eridanilabs/VIRT/blob/af6a7712500dfc65d7b6523ff9d567d8755dc122/runs/92-chat-composer-session-screen/approval.md); [size.json](https://github.com/eridanilabs/VIRT/blob/bfcc27b9c3f5ef8db41402fe0d8e2812c8f4ef43/runs/92-chat-composer-session-screen/size.json). `size-trend` reports `sizeOnly: true`, latest 458, limit 400, estimate 260.

PR comment: https://github.com/eridanilabs/VIRT/pull/96#issuecomment-7183019206

Next: `/factory approve 92` to merge at this size; `/factory revise 92 "<instructions>"` to send it back (it cannot fix a size escalation); or `/factory reject 92 "<reason>"` to close it unmerged.