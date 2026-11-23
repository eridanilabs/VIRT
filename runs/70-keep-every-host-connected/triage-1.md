# Triage r1

| Finding | Reviewer | Decision | Issue | Reason |
|---------|----------|----------|-------|--------|
| [nit] VIRT/HostsViewModel.swift:197: `connectAll` can still call `connector.connect` for a host deleted mid-loop; guard `hosts.contains` at the top of `connect(_:)` | reviewer-code | polish #68 | #68 | Nothing open covers it; milestone "4: Session alerts" is active, so it joins its Polish issue |

No blockers. `[note]` lines aren't triaged.
