# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS

## Findings
- [nit] (copy) VIRT/HostFormViewModel.swift:63: The unparseable-URL error "VIRT can't read this URL." doesn't say what to fix. Fix: reuse the policy's wording, for example "VIRT can't read this URL. Enter it like wss://host.example.com."
- [nit] (states) VIRT/HostsViewModel.swift:30: If the first `load()` fails, `hasLoaded` stays false. The user sees a blank list (no empty state) and a one-shot alert, and has no retry short of relaunching. Fix: add `.refreshable { await model.load() }`, or show a "Couldn't load hosts" state with a Retry button.
- [nit] (states) VIRT/HostFormView.swift:55: `saveError` stays on screen after the user edits a field, until the next save. Fix: clear it on `name`, `urlText` or `token` change.
- [note] VIRT/HostsView.swift:12: Swipe-to-delete is the only delete path (as the spec says). VoiceOver users get it through the actions rotor. Delete asks for no confirmation, which matches the spec.
- [note] VIRT/HostFormView.swift:20: The URL error and warning appear in a section footer. They aren't announced when they change, which is acceptable for now. The icons plus colour carry the severity, and the text does too.
- [note] README.md:60: The new paragraph matches the UI's labels and behaviour (Add host, tap to edit, swipe to delete, blank token keeps it).

## Coverage
- Files read: VIRT/HostsView.swift, VIRT/HostFormView.swift, VIRT/HostFormViewModel.swift, VIRT/HostsViewModel.swift, VIRT/VIRTApp.swift (diff), README.md (diff), HostURLPolicy.swift messages, spec.md, AGENTS.md
- Flows walked:
  - First launch with no hosts: empty state, with an Add host button in the empty state and in the toolbar.
  - Add: blank fields disable Save. ws:// to an insecure host shows the refusal. A CGNAT address shows the warning and Save stays enabled. Success dismisses the sheet and the list reloads.
  - Edit: fields prefilled, token empty, footer explains that a blank token keeps the saved one. Both save paths are covered.
  - Delete: swipe removes the host. A failure leaves the host in the list and the alert shows.
  - Save failure: refusal or generic message shown inline.
  - Failed initial load: see the second nit.
- Commands run: ./scripts/test.sh → passed (VIRTKit and the app's HostsViewModelTests all pass)
- Earlier blockers: none (round 1)
