`/factory add <feature text> [--milestone M]`: file a feature to **Backlog** without building it. The loop doesn't start.

1. If the feature text is empty (nothing after `add`, or only `--milestone M`), stop and ask for it. Don't create an issue.
2. **Without `--milestone`, no milestone is set**: new issues start unscheduled (`docs/MILESTONES.md` rule 3). With `--milestone M` (`active`, `next` or an open milestone's title), resolve it first, **before** `gh issue create`:

   ```bash
   node $B milestone --resolve "<M>"    # prints the milestone's title; ✗ and exit 1 if there's none
   ```

   On an error, stop and show it: no issue is created. Otherwise keep the title it printed. Use `active` only when the feature keeps the active milestone's `Done when` from being true.
3. `gh issue create --repo <repo> --title "<short title>" --body "<feature text>" [--milestone "<title>"]` gives issue `n`. Pass `--milestone` only when step 2 resolved one, with the title it printed.
4. Write the feature text to the summary file and park the card:

   ```bash
   S=$(mktemp "$W/summary.XXXXXX")    # the feature text; never commit it
   node $B move <n> Backlog --from none --agent "orchestrator" --reason "filed via /factory add" --next "/factory <n>" --summary-file $S
   ```

5. Print the new issue number and the next step, `/factory <n>`, to build it, with its milestone (or "unscheduled"). Then stop.

Add does no run work. It creates no branch, writes no records, opens no PR, and spawns no agent (no spec, no builder, no reviewer). Start-up step 0.4 does not apply: a clean tree and `main` checked out are not required. The card gets no progress checklist until `/factory <n>` moves it to Spec.
