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

# A regular iPhone on the newest general iOS runtime. Device-specific
# runtimes (like iOS-27-2-iPhone19-4 for iPhone Duo) and multi-display
# devices are only used if nothing else is available.
UDID="$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys
devices = json.load(sys.stdin)["devices"]
def rank(item):
    runtime, device = item
    m = re.search(r"\.iOS-(\d+)-(\d+)(.*)$", runtime)
    general = m.group(3) == ""
    regular = "Duo" not in device["name"]
    return (general and regular, general, int(m.group(1)), int(m.group(2)))
phones = [(r, d) for r in devices if re.search(r"\.iOS-\d+-\d+", r)
          for d in devices[r] if d["name"].startswith("iPhone")]
if phones:
    runtime, phone = max(phones, key=rank)
    print(phone["udid"])
    print("Simulator:", phone["name"], "on", runtime, file=sys.stderr)
')"
if [[ -z "$UDID" ]]; then
    echo "error: no available iPhone simulator" >&2
    xcrun simctl list devices available >&2
    exit 1
fi

# bootstatus -b boots the device if it isn't already, and waits for it.
xcrun simctl bootstatus "$UDID" -b
# The Simulator window is only needed for the rotation shortcut. It isn't
# registered with Launch Services on the runner, so find it inside Xcode.
XCODE_APP="$(dirname "$(dirname "$(xcode-select -p)")")"
SIMULATOR_APP="$(find "$XCODE_APP" -maxdepth 8 -name Simulator.app -type d -print -quit 2>/dev/null || true)"
if [[ -z "$SIMULATOR_APP" ]]; then
    SIMULATOR_APP="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.iphonesimulator'" 2>/dev/null | head -1 || true)"
fi
if [[ -n "$SIMULATOR_APP" ]] && open "$SIMULATOR_APP" --args -CurrentDeviceUDID "$UDID"; then
    echo "Opened $SIMULATOR_APP"
else
    echo "warning: couldn't find or open Simulator.app under $XCODE_APP" >&2
    SIMULATOR_APP=""
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

# Fails if the app has died or the screenshot couldn't be taken.
shot() {
    sleep "$1"
    if ! xcrun simctl io "$UDID" screenshot --type=png "$OUT/$2.png" >/dev/null; then
        echo "error: couldn't take screenshot $2" >&2
        return 1
    fi
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
if ((STATUS == 0)) && [[ -n "$SIMULATOR_APP" ]]; then
    if osascript -e "tell application \"$SIMULATOR_APP\" to activate" \
        -e 'delay 1' \
        -e 'tell application "System Events" to key code 124 using command down'; then
        shot 5 03-landscape || STATUS=1
    else
        echo "warning: couldn't rotate the simulator, skipping landscape" >&2
    fi
fi

collect_crashes

exit "$STATUS"
