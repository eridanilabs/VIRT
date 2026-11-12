# Review r1: security (claude-opus-5.5)

VERDICT: PASS
## Findings
- [note] Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift:20: The default maker now uses an ephemeral `URLSession` for each attempt, where it used `URLSession.shared` before. The token URL and anything tied to it no longer go to the shared URL cache or cookie store. The recorder doesn't implement the auth-challenge or redirect delegate methods, so certificate checks and redirect handling stay as they were.
- [note] Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift:24-41: Only the mapped `Failure` is stored or passed to `onRecord`. The `URLError`, its userInfo (which holds the token URL) and `task.response` are read once and then dropped. Nothing in `Sources` logs anything (I searched for `print`, `os_log`, `Logger` and `NSLog`). The new tests put the token URL in `NSURLErrorFailingURLErrorKey` and check every status with `expectNoSecret`, which covers AC6.
- [note] Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift:87-105: `RecordingTransport` scans every host frame for the text `-32005` and only parses a frame again if it finds it. The check is a plain substring search, so no regex can be made slow by host input. A host that sends a -32005 error reply to any request, even after it connects, stops the host straight away through `recorded()`. Only the host itself can do this, and it could close the connection anyway, so it isn't a trust-boundary issue. Whether stopping on a -32005 that isn't for `initialize` is the intended behaviour is for reviewer-code.
- [note] Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift:49: Any server, or an on-path attacker on a `wss://` connection that isn't verified, can send back 401 or 403 and stop retries for good. That only denies service, and AC5 asks for it. The token isn't exposed.
## Coverage
- Files read: AGENTS.md, .eridanilabs/autofactory/runs/20-connection-failures-and-reconnecting/spec.md, build-1.md, Packages/VIRTKit/Sources/VIRTKit/ConnectionErrorRecorder.swift (full), Packages/VIRTKit/Sources/VIRTKit/HostConnector.swift (full), Packages/VIRTKit/Tests/VIRTKitTests/ConnectionErrorRecorderTests.swift (diff), Packages/VIRTKit/Tests/VIRTKitTests/HostConnectorTests.swift (diff), README.md (diff), the pinned client's URLSessionWebSocketTransport.swift (to see the old `.shared` session default and its error mapping)
- Flows walked:
  - **Connect:** registration, recorder creation, `openTransport` checks (policy, then tailnet, then token), then the token URL handed to the maker. The token is read only after the checks pass, as before.
  - **Failed attempt:** the URLError's userInfo holds the token URL; the delegate maps it to a `Failure` and keeps only that; the status shows `reconnecting` with that reason.
  - **Stop cases:** 401/403 and -32005, either before or after the client's state event; `stop` clears the registration and the recorder.
  - **Give-up:** `.failed(recorded ?? .other)`.
  - **Stale registration:** a late callback from an old session is dropped by the `registrations[hostID] == id` guard.
  - **Disconnect:** the recorder is cleared.
  - **Host frames into `RecordingTransport`:** these are untrusted input; text and binary frames, the substring check, then a strict parse.
  - **TLS and redirects:** no challenge or redirect delegate, so TLS trust and redirects get the system defaults.
  - **ATS and Info.plist:** unchanged.
- Commands run:
  - `git diff --stat origin/main...HEAD`, `git log origin/main..HEAD` → 5 files, 1 commit
  - `git diff origin/main...HEAD` (sources, tests, README) → read
  - grep for logging calls in Sources → none
  - `./scripts/test.sh` → exit 0 (VIRTKit: 42 tests in 7 suites passed; app tests on the iPhone 18 Pro simulator all passed)
