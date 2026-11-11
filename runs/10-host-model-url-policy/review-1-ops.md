# Review r1: ops (claude-opus-5.5)

VERDICT: PASS
## Findings
- [note] VIRT.xcodeproj/project.pbxproj:29: The new exception set `0A000000000000000000001E` is defined once and linked from the `VIRT` root group. No object id is defined twice. `plutil -lint` passes. `xcodebuild -list` still shows the `VIRT` and `VIRTKit` schemes. Adding `INFOPLIST_FILE` while keeping `GENERATE_INFOPLIST_FILE = YES` is the project-file change that `AGENTS.md` allows, a build setting.
- [note] VIRT/Info.plist:1: The Debug and Release builds both merge the `ts.net` ATS exception into the built `Info.plist`, and the generated keys stay (`CFBundleDisplayName = VIRT`, `UIApplicationSceneManifest`, `UILaunchScreen`). Neither bundle has a second `Info.plist` copied as a resource, so the membership exception works. The Release build has no warnings.
- [note] README.md:60 and AGENTS.md:54: The docs match `HostURLPolicy.evaluate`. They list the same loopback set (`localhost`, `127.0.0.1`, `::1`), the `*.ts.net` names, `100.64.0.0/10` with a warning, and the refusals for user info, a query and a fragment. The policy also refuses trailing-dot and IDN hosts for `ws://`, which the README covers with "VIRT refuses any other URL".
- [note] Packages/VIRTKit/Sources/VIRTKit/HostLibrary.swift: `HostLibrary` is an actor, so writes through one instance happen in order. Two instances on the same `UserDefaults` would still race on the stored list's read-modify-write. Nothing in this diff creates two instances, and the screen in #11 should keep a single one.
## Coverage
- Files read: AGENTS.md, spec.md, build-1.md, reviewers-10-1.txt, scripts/test.sh, VIRT.xcodeproj/project.pbxproj (diff, id table, build settings), VIRT/Info.plist, VIRTTests/ATSTests.swift, README.md (diff), Packages/VIRTKit/Sources/VIRTKit/HostURLPolicy.swift
- Flows walked:
  - The test command (`swift test`, then `xcodebuild test` on the newest iPhone simulator).
  - The Debug build hosting the tests: built `Info.plist` contents and bundle layout.
  - A Release build for the simulator: settings, a clean build, built `Info.plist` and bundle layout.
  - Project integrity: object id uniqueness, plist lint, schemes.
  - Docs against the policy code.
- Commands run:
  - `./scripts/test.sh` → exit 0. `swift test` passed 18 tests in 4 suites. `xcodebuild test` passed 4 app tests (3 in `ATSTests`) on the clone of iPhone 18 Pro (iOS 27.2).
  - `plutil -lint` on the pbxproj and Info.plist → OK.
  - Duplicate object id check on the pbxproj → none.
  - `xcodebuild -list` → targets `VIRT` and `VIRTTests`, schemes `VIRT` and `VIRTKit`.
  - `xcodebuild -showBuildSettings -configuration Release` → `INFOPLIST_FILE = VIRT/Info.plist`, `GENERATE_INFOPLIST_FILE = YES`.
  - `xcodebuild build -configuration Release` (generic simulator destination, `-derivedDataPath /tmp/virt-ops-review-dd`) → exit 0, no warnings. The build output is still in `/tmp`, outside the repo; the checkout is unchanged.
  - `plutil -p` on the built Debug and Release `Info.plist` → only the `ts.net` exception, no `NSAllowsArbitraryLoads`, generated keys present.
- Earlier blockers: none (round 1).
