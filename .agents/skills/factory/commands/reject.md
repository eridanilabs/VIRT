`/factory reject <n> "<reason>"`: a person drops the escalated feature. It closes unmerged and the card goes to Done, labeled `rejected`. `<n>` may be the **issue or the PR** number.

1. If the reason is missing or empty, stop and ask for it. Nothing changes: no comment, no close, no move.
2. Resolve `<n>` the same way as [Approve](#approve) step 1. If the issue has no PR yet (the run was stopped in Spec or before the first build was pushed), carry on without one: skip every PR step below.
3. The card must be in `Needs human` (`node $B status`). Reject applies only in Needs human. If the card is anywhere else, print its column and that `reject` applies only in Needs human, then stop.
4. Work in the run's existing checkout (with no overlap re-check: rejecting starts no work): with no PR, [find the run's branch](#finding-a-runs-branch) first, then [find the run's checkout](#finding-a-runs-checkout): the session's own worktree, as `workspace <n> --continue` decided. Record the reason, `Rejected by @<gh user> on <date> via /factory reject.`, and the open sub-issues as `rejection`. Remove no worktree, delete no local branch, and never switch any checkout to `main`. Run every later step from that worktree.
5. Comment the reason on the issue. Write `🛑 **Rejected** by @<gh user>: <reason>` to a temp file `R` in `$W` with your file tool (never through the shell, so quotes, backticks or `$(…)` in the reason stay text), then `gh issue comment <n> --body-file $R`.
6. Close the PR unmerged and delete only its remote branch. With a PR: `gh pr close <p>` without `--delete-branch` (which would switch the worktree away from the branch and delete the local one), then `gh pr comment <p> --body-file $R`. With or without a PR, then `git push origin --delete <branch>`, with the PR's `headRefName` or the name you found in step 4. Skip the push when `git ls-remote --exit-code --heads origin <branch>` finds no such remote branch (it was never pushed, or GitHub already deleted it), so a missing remote branch doesn't stop the reject. The worktree and its local branch stay until the session is archived, which removes them: archive it once the card is in Done.
7. Close the open review sub-issues. List them with `gh issue view <n> --json subIssues`, and close each open one as not planned: `gh issue close <x> --reason "not planned" --comment "Parent #<n> was rejected."`.
8. Add the label: `gh issue edit <n> --add-label rejected`.
9. Close the issue as not planned: `gh issue close <n> --reason "not planned"`.
10. Record it. GitHub's "Item closed" workflow moves the card to Done, and `move` records that (the note says the issue was closed unmerged, rejected):

    ```bash
    node $B move <n> Done --from "Needs human" --agent "" --human-request "" --checkpoint "PR #<p> closed unmerged" \
      --reason "rejected by @<gh user>" --summary-file $S --pr <p> --run <run>
    ```

    The reason goes in the summary file, not on the command line. Leave out `--pr` (and say "no PR" in the checkpoint) when there was none.
11. Hand control back to the user with the [End-of-run summary](#end-of-run-summary) (Done, rejected), ending with the [`factory-result`](#the-factory-result-line) line, outcome `rejected`, reason `rejected by @<gh user>` (never the person's reason), with `--pr <p>` when there was a PR.
