# factory log

Append-only audit log and run records of the autofactory board, written by `board.mjs`.
One commit per event; data in `log/YYYY-MM.jsonl` (one JSON object per line).
Each run's records (spec, builds, reviews, approval) are in `runs/<issue>-<slug>/`, one commit per record.

```bash
git log --oneline origin/factory-log
node .agents/skills/factory-board/board.mjs log [issue]
```
