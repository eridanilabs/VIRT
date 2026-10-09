---
description: Evidence-based review-fix loop and simultaneous completion gates
applyTo: "**"
---

# Review-Fix Loop

- After every implementation or fix pass, run tests, validate test quality,
  and obtain a Review-persona review of the latest diff.
- Do not equate "the implementer finished" or "tests pass" with completion.
- In orchestrator mode, all code fixes go through Implement and all code
  reviews through Review. Triage findings before handing them to an implementer.
- Keep review/fix evidence in the PR or task record, not only in conversation.
  Follow host-specific review-thread tools rather than replacing inline replies
  with unrelated top-level comments.

## Cycle

1. Implement the bounded change.
2. Run the full relevant project test suite, not only the modified package.
   Record commands, test counts, and coverage where the toolchain supports it.
3. Inspect per-function coverage. Classify every gap as testable or genuinely
   requiring unavailable integration/auth/external services. Close testable
   gaps and document the remaining ceiling with reasons. Do not invent a
   coverage percentage for prose, shell integration, or tools without metrics;
   document the applicable checks and unavailable evidence explicitly.
4. Trace test logic for false positives. Ask whether each assertion could pass
   if the feature were removed. Check faithful mocks, independent test state,
   and actual state divergence. Spot-check at least one test per feature slice.
5. Launch Review on the latest diff.
6. Read each cited source location and classify the finding: true positive,
   false positive, or a trade-off requiring judgment. Fix true positives;
   dismiss false positives with a one-line rationale; escalate uncertain
   product or architecture decisions. Never blindly forward raw findings.
7. Delegate fixes, then repeat tests, coverage assessment, false-positive
   checks, and review. A previous cycle's gate does not carry forward.

The **Loop Exit Gate** means all applicable gates hold simultaneously in the
latest cycle:

| Gate | Required evidence |
| --- | --- |
| Tests pass | Full relevant suite passes; no known failing required checks |
| Coverage ceiling reached | All testable gaps closed; remaining gaps explained |
| No false positives | Tests would fail without the intended behavior |
| Review clean | No Critical/High findings; Medium fixed or explicitly accepted with rationale |
| Independent cross-check | Required high-risk cross-checks also clean |

If a gate's status is unknown, it is not met. Only a clean review exits
successfully. Reaching a limit is a blocked outcome, not success.

## Independent cross-check

Changes to destructive shell commands, deployment/install automation, CI/CD,
infrastructure, security-sensitive behavior, database migrations, or persistent
state need an independent fresh-context review in addition to the normal loop.
Pure documentation and comprehensively tested low-risk library changes may
use it optionally.

Use a fresh reviewer with the same architecture and diff context but no summary
of prior findings. Ask it to find missed issues rather than confirm a clean
result. Prefer model diversity only when available and authorized; otherwise
record the limitation, rather than silently changing user model preferences.

Triage and fix real findings using the same loop. Any true-positive
Medium-or-higher finding requires another independent cross-check after the
fix. After finding a Medium, require two consecutive clean cross-checks to
establish convergence. Document accepted findings and review counts. Complete
this gate before declaring merge-ready; it may be done before opening a PR.

## Stalls and follow-through

Stop after five implementation/review cycles without convergence, or immediately
when the same finding recurs in two consecutive reviews after purported fixes.
Five non-converging cross-checks also require escalation. Explain gates met and
missing, each attempted fix, likely cause, and concrete options. Wait for human
direction; do not label the task complete or quietly waive a gate.

Once clean, publish only as authorized. Record test evidence, coverage ceiling,
review counts, accepted findings, and cross-check count in the PR/task summary.
Create tracked follow-ups for deferred real bugs and documentation gaps,
including actionable Low findings. Link them from the task/epic; a PR narrative
alone is not a task tracker. Update the consumer's changelog if it has one,
record durable decisions, write the handoff, and clean up owned worktrees.
