#!/usr/bin/env bash
# The board's test_command: runs the VIRTKit package's tests on this Mac, then the app's
# tests on an iOS simulator. Set VIRT_SIM_DESTINATION (an xcodebuild -destination) to pick
# the simulator; by default it takes an available iPhone on the newest iOS runtime.
set -euo pipefail

cd "$(dirname "$0")/.."

swift test --package-path Packages/VIRTKit

destination="${VIRT_SIM_DESTINATION:-}"
if [[ -z "$destination" ]]; then
  udid="$(xcrun simctl list --json devices available | python3 -c '
import json, re, sys
runtimes = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    m = re.search(r"SimRuntime\.iOS-(\d+)-(\d+)$", runtime)
    phones = [d["udid"] for d in devices if d["name"].startswith("iPhone")]
    if m and phones:
        runtimes.append(((int(m[1]), int(m[2])), phones[0]))
print(max(runtimes)[1] if runtimes else "")
')"
  if [[ -z "$udid" ]]; then
    echo "test.sh: no available iPhone simulator; install an iOS runtime in Xcode, or set VIRT_SIM_DESTINATION" >&2
    exit 1
  fi
  destination="platform=iOS Simulator,id=$udid"
fi

xcodebuild test \
  -project VIRT.xcodeproj \
  -scheme VIRT \
  -destination "$destination" \
  -skipPackagePluginValidation \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -quiet
