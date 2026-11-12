# Triage r1 for #7

All three selected reviews returned `VERDICT: PASS` with no `[blocker]`. The active milestone is **0: Connect to a guppi host**, so every backlog nit goes into its Polish issue #13 (in Backlog, labelled `from-review`, not this run's issue). Nothing else open covers these findings. `[note]` lines aren't triaged.

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] (simplicity) HostURLPolicyTests.swift:84-93: new tests duplicate the table-driven `evaluates(_:)` test | reviewer-code | polish #13 | #13 | |
| [nit] (polish) README.md:105: step 4 promises "Connected · protocol …", but tapping opens the host's own screen | reviewer-ux | polish #13 | #13 | |
| [nit] (polish) README.md:102-105: "In VIRT" steps skip entering a name, so Save stays off | reviewer-ux | polish #13 | #13 | |
| [nit] (polish) README.md:132-136: checklist doesn't cover a refused token | reviewer-ux | polish #13 | #13 | |
| [nit] (polish) README.md:94: say that every device the tailnet ACLs allow can reach the served port | reviewer-security | polish #13 | #13 | |
| [nit] (polish) README.md:134: HTTPS certificates publish the tailnet name in CT logs | reviewer-security | polish #13 | #13 | |
| [nit] (polish) README.md:118: clearing the clipboard doesn't clear clipboard-history apps | reviewer-security | polish #13 | #13 | |
