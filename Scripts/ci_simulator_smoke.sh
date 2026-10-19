#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(sw_vers -productVersion | cut -d. -f1)" != "27" ]] || [[ "$(xcodebuild -version | awk '/^Xcode / {print $2}' | cut -d. -f1)" != "27" ]]; then
  echo "This job requires macOS 27 and Xcode 27." >&2
  exit 1
fi

output_dir="${1:?Pass an output directory for CI evidence}"
mkdir -p "$output_dir"
mkdir -p "$output_dir/projects"
swift run phase1-acceptance --write-examples "$output_dir/projects"

device_id="$(xcrun simctl list devices available -j | python3 -c '
import json, sys
data = json.load(sys.stdin)
devices = [device for runtime, entries in sorted(data["devices"].items(), reverse=True)
           if "iOS" in runtime for device in entries
           if device.get("isAvailable", True) and "iPhone" in device["name"]]
if not devices:
    raise SystemExit("No available iPhone simulator; install an iOS runtime and device")
print(devices[0]["udid"])
')"

project_json="$output_dir/projects/Fixture.uitestproject/project.json"
python3 - "$project_json" "$device_id" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
project = json.loads(path.read_text())
project["simulator"]["deviceID"] = sys.argv[2]
path.write_text(json.dumps(project, indent=2, sort_keys=True) + "\n")
PY

swift run phase1-acceptance --project "$output_dir/projects/Fixture.uitestproject" \
  --artifacts "$output_dir/fixture-run" --selection one
