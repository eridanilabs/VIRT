# Needs human

## Reason
The approver escalated because its generic `npm test` command was unavailable in this native Swift repository (no `package.json`), even though the configured `./scripts/test.sh` passed.

## Evidence
- The configured `./scripts/test.sh` passed after the final builder commit: 226 tests passed, 0 failed.
- All acceptance criteria passed round 2 review; the reviewers confirmed the icon, label, and existing new-session action.
- The approver's recorded decision is [approval](https://github.com/eridanilabs/VIRT/blob/5e64650701529b3cb60044b383e8c52fe5c78214/runs/91-new-session-navigation-label/approval.md).

## Next step
Review the mismatch and then run `/factory approve 91` to merge, `/factory revise 91 "<instructions>"` to send it back to the builder, `/factory revise 91 --to spec|review|approve "<instructions>"` to return to another stage, or `/factory reject 91 "<reason>"` to close it unmerged.
