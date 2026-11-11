# Triage r1 (orchestrator)

All four selected reviews PASS. No blockers. Every nit is filed `--as backlog` into the active milestone's Polish issue, #13 (in Backlog, labelled `from-review`). `[note]` lines get no triage.

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] `VIRT/HostsView.swift:67`: `HostLibrary.preview` isn't under `#if DEBUG` | reviewer-code | polish #13 | #13 | milestone active; nothing else open covers it |
| [nit] `VIRT/HostFormViewModel.swift:95`: `save()` trims the token before storing it | reviewer-code | polish #13 | #13 | milestone active; nothing else open covers it |
| [nit] `VIRT/HostFormViewModel.swift:63`: unparseable-URL error doesn't say what to fix | reviewer-ux | polish #13 | #13 | milestone active; same kind of copy fix as #13's `HostURLPolicy` message nits |
| [nit] `VIRT/HostsViewModel.swift:30`: a failed first `load()` leaves a blank list with no retry | reviewer-ux | polish #13 | #13 | milestone active; nothing else open covers it |
| [nit] `VIRT/HostFormView.swift:55`: `saveError` stays after the user edits a field | reviewer-ux | polish #13 | #13 | milestone active; nothing else open covers it |
| [nit] `VIRT/HostFormView.swift:21`: orange CGNAT warning text is low contrast | reviewer-ui-design | polish #13 | #13 | milestone active; nothing else open covers it |
| [nit] `VIRT/HostFormView.swift:33`: Token header repeats the field's label | reviewer-ui-design | polish #13 | #13 | milestone active; nothing else open covers it |
