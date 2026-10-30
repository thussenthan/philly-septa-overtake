#!/usr/bin/env bash
#
# Build Overtake and put it back on a connected iPhone.
#
# This exists because a free Apple ID signs development builds with a certificate
# that Apple expires after seven days. Nothing is wrong when the app stops working
# — it has to be reinstalled, and it will have to be again next week. Joining the
# Apple Developer Program raises that to a year and makes this script unnecessary.
#
#   tools/install-device.sh              # find the device, build, install, launch
#   DEVICE=<uuid> tools/install-device.sh
#   TEAM=<team id> tools/install-device.sh   # if Xcode says the project needs a team
#
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED=build
APP="$DERIVED/Build/Products/Debug-iphoneos/SEPTACommute.app"
BUNDLE_ID=com.thussenthan.Overtake

# --- which phone -------------------------------------------------------------
if [[ -z "${DEVICE:-}" ]]; then
    echo "Looking for a connected device…"
    JSON=$(mktemp)
    trap 'rm -f "$JSON"' EXIT
    xcrun devicectl list devices --json-output "$JSON" >/dev/null 2>&1 || true

    # Parsed defensively: the schema is Apple's and undocumented, so anything
    # unexpected falls through to asking rather than guessing wrong.
    DEVICE=$(python3 - "$JSON" <<'PY'
import json, sys
try:
    blob = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)

def walk(node):
    if isinstance(node, dict):
        if "identifier" in node and isinstance(node.get("identifier"), str):
            props = node.get("deviceProperties") or {}
            hardware = node.get("hardwareProperties") or {}
            platform = str(hardware.get("platform", "")).lower()
            if "iphone" in platform or "ios" in platform:
                yield node["identifier"], props.get("name", "iPhone")
        for value in node.values():
            yield from walk(value)
    elif isinstance(node, list):
        for value in node:
            yield from walk(value)

found = list(dict(walk(blob)).items())
if len(found) == 1:
    print(found[0][0])
PY
)
fi

if [[ -z "${DEVICE:-}" ]]; then
    echo
    echo "Couldn't identify exactly one iPhone. Devices visible now:"
    echo
    xcrun devicectl list devices || true
    echo
    echo "Plug the phone in and unlock it, then re-run — or name it yourself:"
    echo "    DEVICE=<Identifier-column-value> $0"
    exit 1
fi

echo "Device: $DEVICE"

# --- build -------------------------------------------------------------------
# 'generic/platform=iOS' rather than the device id: it builds the same product and
# does not fail when the phone drops off the USB bus mid-build.
echo "Building…"
BUILD_LOG=$(mktemp)
if ! xcodebuild \
    -project SEPTACommute.xcodeproj \
    -scheme SEPTACommute \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED" \
    -allowProvisioningUpdates \
    ${TEAM:+DEVELOPMENT_TEAM="$TEAM"} \
    build >"$BUILD_LOG" 2>&1; then
    # The last few lines hide the reason: signing failures are reported near the top.
    grep -E "error:|requires a development team|No profiles" "$BUILD_LOG" | head -10 || true
    echo
    echo "Build failed. If it is about a development team, name yours:"
    echo "    TEAM=<your 10-character team id> $0"
    echo "Full log: $BUILD_LOG"
    exit 1
fi
tail -3 "$BUILD_LOG"

[[ -d "$APP" ]] || { echo "No app at $APP — the build did not produce one."; exit 1; }

# --- install and launch ------------------------------------------------------
echo "Installing…"
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "Launching…"
xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE_ID"

echo
echo "Done. Signed for development, so expect about seven days before it needs this again."
