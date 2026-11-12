# Review r1: ux (claude-sonnet-5.5)

VERDICT: PASS
## Findings
- [note] README.md:71: The paragraph says "VIRT gives a short reason" and "counts its attempts", but the views don't show the status yet. The spec lists that as out of scope, and the neighbouring tailnet paragraph is worded the same way. Nothing to change now, but the wording should be rechecked when the views land.
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:59-63: The five new messages are short and each says what went wrong. Four of them also say what to do, and the protocol-version one doesn't. The wording matches the existing "Edit the host…" and "Is Tailscale on?" style, and each case has a fixed message with no URL or token in it. The README's list of reasons matches the cases.
## Coverage
- Files read: README.md, spec.md, HostConnector.swift (Failure and message section)
- Flows walked: failure copy against the spec's AC1, README description against the stop and retry behaviour (the token-refused and version-mismatch stops, reconnect with attempt count), and the discoverability of the new reasons
- Commands run: git diff origin/main...HEAD --stat and README diff → only README is user-facing; I didn't run the test suite because it is outside my lane
- Earlier blockers: none (round 1)
