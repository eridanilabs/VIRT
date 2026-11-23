# Found items, build round 1

| Finding | Decision | Issue | Reason |
|---------|----------|-------|--------|
| `VIRT/SessionAlertBanner.swift:1`: the host form sheet covers the banner (AC4 "over every screen") | this run's (`sub`) | #63 | new file in this run's diff; about AC4 |
| `VIRT/HostsViewModel.swift` `tapAlert()`: chat set in one step with the sessions screen | this run's (`sub`) | #64 | `tapAlert()` is new in this run's diff (HostsViewModel.swift +121..130); about AC5 |

Fix pass: both **Fixed** in 93b2756 (`build-1.2.md`). The fix pass found nothing new.
