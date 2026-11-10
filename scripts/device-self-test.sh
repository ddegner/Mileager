#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

BUNDLE_ID="${MILEAGE_BUNDLE_ID:-com.daviddegner.MileageTracker}"
DERIVED_DATA="${MILEAGE_DEVICE_DERIVED_DATA:-/tmp/MileageTrackerDeviceSelfTestDerivedData}"
DEVICE_ID="${MILEAGE_DEVICE_ID:-}"
SCHEME="${MILEAGE_SCHEME:-MileageTracker}"
COPY_DIR="${MILEAGE_DEVICE_COPY_DIR:-/tmp/MileageTrackerDeviceSelfTestContainer}"

usage() {
  cat <<'USAGE'
Usage: scripts/device-self-test.sh

Optional environment:
  MILEAGE_DEVICE_ID            devicectl device identifier. Auto-detected when possible.
  MILEAGE_DEVICE_DERIVED_DATA  DerivedData path. Defaults outside the repo.
  MILEAGE_DEVICE_COPY_DIR      Pulled app-container path. Defaults outside the repo.
  MILEAGE_BUNDLE_ID            Defaults to com.daviddegner.MileageTracker.
USAGE
}

if [[ "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

detect_device() {
  local json_file
  json_file="$(mktemp -t mileage-devices.XXXXXX.json)"
  xcrun devicectl list devices --json-output "$json_file" >/dev/null
  python3 - "$json_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    data = json.load(handle)

devices = []

def walk(value):
    if isinstance(value, dict):
        identifier = value.get("identifier")
        name = (
            value.get("name")
            or value.get("deviceProperties", {}).get("name")
            or value.get("hardwareProperties", {}).get("deviceName")
            or ""
        )
        platform = (
            value.get("platform")
            or value.get("hardwareProperties", {}).get("platform")
            or value.get("deviceProperties", {}).get("platform")
            or ""
        )
        connection = value.get("connectionProperties", {})
        pairing_state = str(connection.get("pairingState", "")).lower()
        tunnel_state = str(connection.get("tunnelState", "")).lower()
        ddi_services_available = value.get("deviceProperties", {}).get("ddiServicesAvailable")
        # devicectl also lists booted simulators (reality == "simulated"); this
        # script installs device-architecture builds, so only physical iPhones
        # qualify. An empty reality (older devicectl) is treated as physical.
        reality = str(value.get("hardwareProperties", {}).get("reality", "")).lower()
        if identifier and ("iphone" in name.lower() or "ios" in str(platform).lower()):
            devices.append((identifier, name, pairing_state, tunnel_state, ddi_services_available, reality))
        for child in value.values():
            walk(child)
    elif isinstance(value, list):
        for child in value:
            walk(child)

walk(data)
available = [
    device for device in devices
    if device[2] in ("paired", "trusted", "")
    and device[3] != "unavailable"
    and device[5] != "simulated"
]
# ddiServicesAvailable is a point-in-time snapshot: a paired phone idling on
# Wi-Fi reports False until devicectl brings the tunnel up on demand, and
# install/launch still succeed. Prefer a device that is already tunnel-ready,
# but never reject a paired physical phone over it.
available.sort(key=lambda device: device[4] is not True)
selected = available[0] if available else None
if selected is None:
    if devices:
        sys.stderr.write("No available physical iPhone found. Current iPhone devices:\n")
        for _, name, pairing, tunnel, ddi, reality in devices:
            sys.stderr.write(
                f"  - {name or '(unnamed)'} pairing={pairing or 'unknown'} "
                f"tunnel={tunnel or 'unknown'} ddiServicesAvailable={ddi} "
                f"reality={reality or 'unknown'}\n"
            )
    else:
        sys.stderr.write("No connected iPhone found.\n")
    sys.stderr.write("Connect/unlock a trusted iPhone, wait for devicectl to show it available, or set MILEAGE_DEVICE_ID.\n")
    sys.exit(2)
print(selected[0])
sys.stderr.write(f"Selected device: {selected[1]} {selected[0]}\n")
PY
}

if [[ -z "$DEVICE_ID" ]]; then
  DEVICE_ID="$(detect_device)"
fi

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building signed Debug app for device"
xcodebuild build \
  -project MileageTracker.xcodeproj \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$DERIVED_DATA"

APP_PATH="$(find "$DERIVED_DATA/Build/Products/Debug-iphoneos" -maxdepth 1 -name 'MileageTracker.app' -print -quit)"
if [[ -z "$APP_PATH" ]]; then
  echo "Could not find built MileageTracker.app in $DERIVED_DATA/Build/Products/Debug-iphoneos" >&2
  exit 1
fi

echo "==> Installing $APP_PATH"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "==> Launching deterministic drive self-test"
xcrun devicectl device process launch \
  --device "$DEVICE_ID" \
  "$BUNDLE_ID" \
  --terminate-existing \
  --uitesting \
  --reset-data \
  --reset-preferences \
  --skip-onboarding \
  --drive-self-test

rm -rf "$COPY_DIR"
mkdir -p "$COPY_DIR"

echo "==> Pulling isolated UI-testing store"
xcrun devicectl device copy from \
  --device "$DEVICE_ID" \
  --domain-type appDataContainer \
  --domain-identifier "$BUNDLE_ID" \
  --source "Library/Application Support/MileageTracker-UITesting" \
  --destination "$COPY_DIR" >/dev/null

TRIP_DB="$(find "$COPY_DIR" -name 'MileageTracker.sqlite' -print -quit)"
RAW_DB="$(find "$COPY_DIR" -name 'MileageTrackerRaw.sqlite' -print -quit)"

if [[ -z "$TRIP_DB" || -z "$RAW_DB" ]]; then
  echo "Expected MileageTracker.sqlite and MileageTrackerRaw.sqlite in pulled app data." >&2
  find "$COPY_DIR" -maxdepth 4 -type f >&2
  exit 1
fi

trip_count="$(
  sqlite3 "$TRIP_DB" "select count(*) from ZTRIPENTITY where ZCAPTURESOURCE = 'automatic' and ZDISTANCEMETERS > 0;"
)"
diagnostic_count="$(
  sqlite3 "$RAW_DB" "select count(*) from ZDIAGNOSTICSAMPLEENTITY where ZACCEPTEDFORDETECTION = 1;"
)"

if [[ "$trip_count" -lt 1 ]]; then
  echo "Drive self-test did not create the expected automatic trip." >&2
  exit 1
fi
if [[ "$diagnostic_count" -lt 1 ]]; then
  echo "Drive self-test did not persist expected accepted diagnostic samples." >&2
  exit 1
fi

echo "Device self-test passed: $trip_count automatic trip(s), $diagnostic_count accepted diagnostic sample(s)."
echo "Pulled container: $COPY_DIR"
