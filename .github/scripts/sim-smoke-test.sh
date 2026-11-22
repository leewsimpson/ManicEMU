#!/bin/bash
# Launch smoke test: boot an iPhone simulator, install and launch the built
# app, take screenshots in portrait and landscape, and fail if the app dies.
#
# Usage: sim-smoke-test.sh <path to .app> <output dir>
set -euo pipefail

APP="$1"
OUT="$2"
mkdir -p "$OUT"

plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$APP/Info.plist"; }
BUNDLE_ID="$(plist CFBundleIdentifier)"
EXECUTABLE="$(plist CFBundleExecutable)"
echo "App: $BUNDLE_ID ($EXECUTABLE)"

# Newest iOS runtime, first available iPhone on it.
UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def version(runtime):
    return [int(n) for n in re.findall(r"\d+", runtime.split("iOS-")[-1])]
for runtime in sorted((r for r in devices if ".iOS-" in r), key=version, reverse=True):
    phones = [d for d in devices[runtime] if d["name"].startswith("iPhone")]
    if phones:
        phone = phones[0]
        print(phone["udid"])
        print("Simulator:", phone["name"], "on", runtime, file=sys.stderr)
        break
')"
if [[ -z "$UDID" ]]; then
    echo "error: no available iPhone simulator" >&2
    xcrun simctl list devices available >&2
    exit 1
fi

# bootstatus -b boots the device if it isn't already, and waits for it.
xcrun simctl bootstatus "$UDID" -b
# The Simulator window is only needed for the rotation shortcut. It isn't
# registered with Launch Services on the runner, so open it by path.
SIMULATOR_APP="$(xcode-select -p)/Applications/Simulator.app"
if ! open "$SIMULATOR_APP" --args -CurrentDeviceUDID "$UDID"; then
    echo "warning: couldn't open $SIMULATOR_APP" >&2
fi

xcrun simctl install "$UDID" "$APP"

xcrun simctl spawn "$UDID" log stream --level debug --style compact \
    --predicate "process == \"$EXECUTABLE\"" > "$OUT/app.log" 2>&1 &
LOG_PID=$!
trap 'kill "$LOG_PID" 2>/dev/null || true' EXIT

collect_crashes() {
    find "$HOME/Library/Logs/DiagnosticReports" -name "${EXECUTABLE}*" \
        -exec cp {} "$OUT/" \; 2>/dev/null || true
}

if ! LAUNCH="$(xcrun simctl launch "$UDID" "$BUNDLE_ID")"; then
    echo "error: app failed to launch" >&2
    xcrun simctl io "$UDID" screenshot "$OUT/00-launch-failed.png" >/dev/null || true
    collect_crashes
    exit 1
fi
echo "$LAUNCH"
APP_PID="${LAUNCH##*: }"

alive() { kill -0 "$APP_PID" 2>/dev/null; }

shot() {
    sleep "$1"
    xcrun simctl io "$UDID" screenshot "$OUT/$2.png" >/dev/null
    if alive; then
        echo "$2: app running"
    else
        echo "error: app is no longer running at $2" >&2
        return 1
    fi
}

STATUS=0
shot 5 01-portrait-5s && shot 15 02-portrait-20s || STATUS=1

# Cmd+Right in Simulator rotates the device to landscape.
if ((STATUS == 0)); then
    if osascript -e 'tell application "Simulator" to activate' \
        -e 'delay 1' \
        -e 'tell application "System Events" to key code 124 using command down'; then
        shot 5 03-landscape || STATUS=1
    else
        echo "warning: couldn't rotate the simulator, skipping landscape" >&2
    fi
fi

collect_crashes

exit "$STATUS"
