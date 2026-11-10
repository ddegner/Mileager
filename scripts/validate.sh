#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA="${MILEAGE_DERIVED_DATA:-/tmp/MileageTrackerValidationDerivedData}"
RESULT_BUNDLE="${MILEAGE_RESULT_BUNDLE:-/tmp/MileageTrackerValidation.xcresult}"
UNIT_RESULT_BUNDLE="${MILEAGE_UNIT_RESULT_BUNDLE:-${RESULT_BUNDLE%.xcresult}-Unit.xcresult}"
SIMULATOR_ID="${MILEAGE_SIMULATOR_ID:-}"
SCHEME="${MILEAGE_SCHEME:-MileageTracker}"
# UI phases cover the complete simulator-supported iPhone regression suite
# and the iPad/Mac suites, including time to finish each result bundle.
# Verbose simulator diagnostics are disabled below: Xcode 26 can spend its
# entire remaining timeout in `simctl diagnose` even after every test passes,
# masking the real result as a timeout. The xcresult still retains ordinary
# failure logs, screenshots, and accessibility attachments.
XCODEBUILD_TEST_TIMEOUT="${MILEAGE_XCODEBUILD_TEST_TIMEOUT:-900}"
# The expanded iPhone suite can exceed an hour on a local simulator.
XCODEBUILD_UI_TEST_TIMEOUT="${MILEAGE_XCODEBUILD_UI_TEST_TIMEOUT:-${MILEAGE_XCODEBUILD_TEST_TIMEOUT:-5400}}"

# Two tiers. `fast` (the default) is the gate that runs on every pull request
# and on every local pass before work is called done: project generation and
# the static checks, the package tests, the app-hosted unit tests, the unsigned
# build, and the localization verify. About seven minutes on a CI runner.
# `full` (`--full`, or MILEAGE_VALIDATE_TIER=full) is the release gate: the
# fast tier plus the clean iOS-triple package build, all simulator-supported
# iPhone functional UI tests, and iPad split-shell, Mac selection, search, and
# onboarding tests. Screenshot capture and device-only Siri/intent suites have
# their own workflows. This broader release gate does not run per pull request.
#
# The tier only sets DEFAULTS. Every MILEAGE_RUN_* variable below still wins
# when set explicitly, so `MILEAGE_RUN_UI_TESTS=0 scripts/validate.sh --full`
# is the full tier without simulator automation, exactly as before.
TIER="${MILEAGE_VALIDATE_TIER:-fast}"
for arg in "$@"; do
  case "$arg" in
    --fast) TIER=fast ;;
    --full) TIER=full ;;
    -h|--help)
      echo "usage: scripts/validate.sh [--fast|--full]"
      echo "  --fast  (default) per-change gate: static checks, package tests, unit tests, unsigned build, localization"
      echo "  --full  release gate: --fast plus the clean iOS-triple build and the iPhone and iPad UI suites"
      exit 0 ;;
    *) echo "Unknown argument: $arg (expected --fast or --full)" >&2; exit 2 ;;
  esac
done
case "$TIER" in
  fast) TIER_RUNS_UI_TESTS=0; TIER_RUNS_TRIPLE_BUILD=0 ;;
  full) TIER_RUNS_UI_TESTS=1; TIER_RUNS_TRIPLE_BUILD=1 ;;
  *) echo "MILEAGE_VALIDATE_TIER must be fast or full (found: $TIER)" >&2; exit 2 ;;
esac

# The clean-triple package build is the local insurance against an incremental
# xcodebuild cache masking a cross-target visibility break. On CI every run is
# already clean, and xcodebuild compiles the same iOS sources for the app, so
# the fast tier leaves it to the full tier.
RUN_IOS_TRIPLE_BUILD="${MILEAGE_RUN_IOS_TRIPLE_BUILD:-$TIER_RUNS_TRIPLE_BUILD}"
# Two levels on purpose, not a leftover. MILEAGE_RUN_UI_TESTS is the master
# switch: it cascades to every UI phase, which is what makes
# `MILEAGE_RUN_UI_TESTS=0 scripts/validate.sh --full` a one-knob headless run.
# The per-device vars below override it individually.
#
# It briefly looked vestigial when the Mac target was retired and only the
# iPhone phase was left reading it. The iPad phase gave it a second consumer.
RUN_UI_TESTS="${MILEAGE_RUN_UI_TESTS:-$TIER_RUNS_UI_TESTS}"
RUN_IOS_UI_TESTS="${MILEAGE_RUN_IOS_UI_TESTS:-$RUN_UI_TESTS}"
# Inherits RUN_IOS_UI_TESTS on purpose: the iPad phase runs wherever the
# iPhone UI phase runs, so the fast tier keeps it off by construction rather
# than by an edit someone has to remember, and the full tier turns it on the
# same way. The `Release Gate` workflow is what runs it on CI.
RUN_IPAD_UI_TESTS="${MILEAGE_RUN_IPAD_UI_TESTS:-$RUN_IOS_UI_TESTS}"
IPAD_SIMULATOR_ID="${MILEAGE_IPAD_SIMULATOR_ID:-}"
IPAD_RESULT_BUNDLE="${MILEAGE_IPAD_RESULT_BUNDLE:-${RESULT_BUNDLE%.xcresult}-iPad.xcresult}"

# Usage: select_simulator [iPhone|iPad]. Newest runtime wins, then "Pro".
select_simulator() {
  python3 - "${1:-iPhone}" <<'PY'
import json
import re
import subprocess
import sys

prefix = sys.argv[1]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
candidates = []
for runtime, devices in data.get("devices", {}).items():
    if "iOS" not in runtime:
        continue
    runtime_version = tuple(int(part) for part in re.findall(r"\d+", runtime))
    for device in devices:
        name = device.get("name", "")
        udid = device.get("udid", "")
        if not udid or not name.startswith(prefix):
            continue
        # "Pro" as a model tier, never as a chip: "iPad mini (A17 Pro)" sorted
        # ABOVE "iPad Pro 13-inch (M4)" on a GitHub runner — both matched, and
        # 'm' beats 'P' in the name tiebreak — so the split-shell suites ran on
        # a 744pt iPad mini that cannot hold three columns.
        tier = re.sub(r"\([^)]*\)", "", name)
        candidates.append((runtime_version, "Pro" in tier, name, udid, runtime))

if not candidates:
    sys.stderr.write(
        f"No available {prefix} simulator found. Install an iOS simulator runtime in Xcode.\n"
    )
    sys.exit(2)

candidates.sort(reverse=True)
runtime_version, _, name, udid, runtime = candidates[0]
sys.stderr.write(f"Selected {prefix} simulator: {name} ({runtime}) {udid}\n")
print(udid)
PY
}

# Booting is split in two so it overlaps the phases that do not need a
# simulator. A cold boot on a CI runner is about two and a half minutes, most
# of it a data-migration pass after `simctl boot` returns, and the package
# tests and the triple build were sitting idle in front of it. begin_boot
# kicks the boot off in the background; await_simulator joins it and waits for
# bootstatus right before the first xcodebuild that needs the device.
#
# Plain variables, not an associative array: macOS ships bash 3.2, which has
# no `declare -A`, and the shebang resolves to it wherever Homebrew's bash is
# not first on PATH.
begin_boot() {
  local udid="$1"
  BOOT_PID=""
  if xcrun simctl list devices booted | grep -q "$udid"; then
    echo "Simulator $udid is already booted."
    return
  fi
  echo "Booting simulator $udid in the background."
  xcrun simctl boot "$udid" >/dev/null 2>&1 &
  BOOT_PID=$!
}

# Usage: await_simulator <udid> <pid-from-begin_boot-or-empty>
await_simulator() {
  local udid="$1"
  local boot_pid="${2:-}"
  if [[ -n "$boot_pid" ]]; then
    wait "$boot_pid" || true
    xcrun simctl bootstatus "$udid" -b
    sleep 5
  fi
  xcrun simctl terminate "$udid" com.daviddegner.MileageTracker >/dev/null 2>&1 || true
}

if [[ -z "$SIMULATOR_ID" ]]; then
  SIMULATOR_ID="$(select_simulator)"
fi
if [[ "$RUN_IPAD_UI_TESTS" == "1" && -z "$IPAD_SIMULATOR_ID" ]]; then
  IPAD_SIMULATOR_ID="$(select_simulator iPad)"
fi

DESTINATION="platform=iOS Simulator,id=${SIMULATOR_ID}"

run_with_timeout() {
  local timeout_seconds="$1"
  shift
  python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout_seconds = float(sys.argv[1])
command = sys.argv[2:]
process = subprocess.Popen(command)
try:
    raise SystemExit(process.wait(timeout=timeout_seconds))
except subprocess.TimeoutExpired:
    sys.stderr.write(f"Command timed out after {timeout_seconds:.0f}s: {' '.join(command)}\n")
    process.terminate()
    try:
        process.wait(timeout=20)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    raise SystemExit(124)
PY
}

echo "==> Validation tier: $TIER"

echo "==> Starting simulator boot"
begin_boot "$SIMULATOR_ID"
IPHONE_BOOT_PID="$BOOT_PID"
IPAD_BOOT_PID=""
if [[ "$RUN_IPAD_UI_TESTS" == "1" ]]; then
  begin_boot "$IPAD_SIMULATOR_ID"
  IPAD_BOOT_PID="$BOOT_PID"
fi

echo "==> Generating Xcode project"
# XcodeGen output must match the committed project or every result below
# describes a project nobody reviewed. Compare parsed values so dictionary
# ordering and generated package reference IDs do not cause false failures;
# every actual value and ordered array must still match.
#
# The pin tracks whatever Homebrew ships, so bumping it means regenerating and
# committing the project in the same change.
xcodegen version | grep -q "2.46.0" || {
  echo "XcodeGen 2.46.0 required (found: $(xcodegen version)); install the pinned version." >&2
  exit 1
}
PBXPROJ_BEFORE_GENERATE="$(mktemp /tmp/MileageTrackerPbxproj.XXXXXX)"
cp MileageTracker.xcodeproj/project.pbxproj "$PBXPROJ_BEFORE_GENERATE"
xcodegen generate
if ! python3 - "$PBXPROJ_BEFORE_GENERATE" MileageTracker.xcodeproj/project.pbxproj <<'PYPROJECT'
import json
import subprocess
import sys

def project(path):
    data = json.loads(subprocess.check_output(["plutil", "-convert", "json", "-o", "-", path]))
    # XcodeGen 2.46 assigns random TEMP IDs to link:false package products.
    # Normalize those references by the complete product object, retaining
    # dependency membership and rejecting ambiguous duplicate objects.
    replacements = {}
    for key, value in data["objects"].items():
        if key.startswith("TEMP_") and value.get("isa") == "XCSwiftPackageProductDependency":
            stable = "PACKAGE:" + json.dumps(value, sort_keys=True)
            assert stable not in replacements.values()
            replacements[key] = stable
    def normalize(value):
        if isinstance(value, dict):
            return {
                replacements.get(k, k): (
                    json.loads(v.replace("[", "{").replace("]", "}"))
                    if k == "SystemCapabilities" and isinstance(v, str)
                    else normalize(v)
                ) for k, v in value.items()
            }
        if isinstance(value, list):
            return [normalize(v) for v in value]
        return replacements.get(value, value) if isinstance(value, str) else value
    return normalize(data)

# XcodeGen serializes capability dictionaries in nondeterministic order.
# Compare parsed project values; array order and every actual value still count.
raise SystemExit(0 if project(sys.argv[1]) == project(sys.argv[2]) else 1)
PYPROJECT
then
  rm -f "$PBXPROJ_BEFORE_GENERATE"
  echo "xcodegen generate changed MileageTracker.xcodeproj beyond dictionary ordering and generated package reference IDs; stage the regenerated project so the committed file matches what gets built." >&2
  exit 1
fi
rm -f "$PBXPROJ_BEFORE_GENERATE"

echo "==> Checking layer purity"
# Target dependencies gate package imports, not SDK modules - so the pure
# targets' platform-framework bans need their own check.
if grep -rnE "^import (CoreData|CoreLocation|CoreMotion|UIKit|AppKit|SwiftUI|EventKit|Contacts)$" \
  AppCorePackage/Sources/DriveCaptureEngine AppCorePackage/Sources/AppCoreModels; then
  echo "Pure targets must stay platform-framework-free; move the dependency behind a provider seam." >&2
  exit 1
fi

echo "==> Checking persistent-history hygiene"
# Local-store history has no consumer: the cloud-scoped fetch keeps a
# multi-million-transaction raw backlog from freezing launch, and the recurring
# purge keeps it from accumulating again (2026-08 field freeze). Fail loudly if
# either disappears.
if ! grep -q "affectedStores" AppCorePackage/Sources/AppCorePersistence/PersistentHistoryMonitor.swift; then
  echo "PersistentHistoryMonitor must scope history fetches to the Cloud store via affectedStores." >&2
  exit 1
fi
if ! grep -q "deleteHistory" AppCorePackage/Sources/AppCorePersistence/LocalHistoryPurger.swift; then
  echo "LocalHistoryPurger must purge Local-store history via deleteHistory(before:)." >&2
  exit 1
fi

echo "==> Checking UI tests do not match shell-shaped nav bars directly"
# "Trips", "Need Review", and "All Trips" mean different things per shell: in
# the split view the sidebar and the content column are mounted at the SAME
# time, so `app.navigationBars["Trips"]` is satisfied by the sidebar even when
# nothing is selected, and `XCTAssertFalse(...["Need Review"].exists)` is false
# by design. Those assertions pass vacuously rather than failing, which is
# worse than breaking. They go through MileageTrackerUITestCase's
# assertMailboxRootIsShowing / assertScopeIsOpen / assertNoScopeIsOpen, which
# scope the check to the right column in both shells.
#
# `navigationBars.firstMatch` is deliberately NOT banned: a launch smoke test
# that just wants "some bar appeared" is legitimate. Use navigationBar(in:)
# when the column matters.
if grep -rnE 'app\.navigationBars\["(Trips|Need Review|All Trips)"\]' \
  MileageTrackerUITests --include='*.swift' \
  | grep -v '^MileageTrackerUITests/MileageTrackerUITestCase.swift:'; then
  echo "Shell-shaped nav-bar assertions must go through MileageTrackerUITestCase." >&2
  exit 1
fi

echo "==> Running AppCore package tests"
swift test --package-path AppCorePackage

if [[ "$RUN_IOS_TRIPLE_BUILD" == "1" ]]; then
  echo "==> Building package for iOS (clean scratch path)"
  # The umbrella's capture shell is #if os(iOS); macOS swift test never compiles
  # it, and incremental xcodebuild caches once masked a cross-target visibility
  # break for days. A clean-triple build closes that blind spot cheaply.
  IOS_TRIPLE_SCRATCH="$(mktemp -d /tmp/MileageTrackerTripleBuild.XXXXXX)"
  swift build --package-path AppCorePackage \
    --scratch-path "$IOS_TRIPLE_SCRATCH" \
    --triple arm64-apple-ios26.0-simulator \
    --sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
  rm -rf "$IOS_TRIPLE_SCRATCH"
else
  echo "==> Skipping clean iOS-triple package build (MILEAGE_RUN_IOS_TRIPLE_BUILD=$RUN_IOS_TRIPLE_BUILD)"
fi

echo "==> Waiting for simulator"
await_simulator "$SIMULATOR_ID" "$IPHONE_BOOT_PID"

echo "==> Running app-hosted unit tests"
rm -rf "$UNIT_RESULT_BUNDLE"
run_with_timeout "$XCODEBUILD_TEST_TIMEOUT" xcodebuild test \
  -collect-test-diagnostics never \
  -project MileageTracker.xcodeproj \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -resultBundlePath "$UNIT_RESULT_BUNDLE" \
  -parallel-testing-enabled NO \
  -only-testing:MileageTrackerTests

if [[ "$RUN_IOS_UI_TESTS" == "1" ]]; then
  echo "==> Running iPhone functional UI regression tests"
  rm -rf "$RESULT_BUNDLE"
  run_with_timeout "$XCODEBUILD_UI_TEST_TIMEOUT" xcodebuild test \
    -collect-test-diagnostics never \
    -project MileageTracker.xcodeproj \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$RESULT_BUNDLE" \
    -parallel-testing-enabled NO \
    -only-testing:MileageTrackerUITests \
    -skip-testing:MileageTrackerUITests/AppStoreScreenshotUITests \
    -skip-testing:MileageTrackerUITests/AppStoreIPadScreenshotUITests \
    -skip-testing:MileageTrackerUITests/RedesignWalkthroughUITests \
    -skip-testing:MileageTrackerUITests/SiriCurrentDriveUITests \
    -skip-testing:MileageTrackerUITests/CurrentDriveAppIntentsSystemTests \
    -skip-testing:MileageTrackerUITests/SplitShellUITests \
    -skip-testing:MileageTrackerUITests/MacListSelectionUITests \
    -skip-testing:MileageTrackerUITests/MacCompactSelectionUITests \
    -skip-testing:MileageTrackerUITests/MacOnboardingUITests \
    -skip-testing:MileageTrackerUITests/TripSearchSelectionUITests
else
  echo "==> Skipping iPhone UI tests (MILEAGE_RUN_IOS_UI_TESTS=$RUN_IOS_UI_TESTS)"
fi

# The split-view shell mounts at regular width on iPad and Designed-for-iPad
# Macs. The iPad simulator exercises the shared NavigationShellResolution;
# --mac-mode=on also reaches the Mac selection, search, and onboarding paths.
# It cannot verify AppKit host behavior: docs/mac-manual-verification.md lists
# the checks that still require the actual Mac app.
#
# MileageTrackerTests has no size-class or idiom reference at all, and the
# unsigned build and the localization verify use the same binary and the same
# strings, so duplicating them would buy nothing but wall clock. Derived data is
# shared, making this install-and-launch only.
if [[ "$RUN_IPAD_UI_TESTS" == "1" ]]; then
  echo "==> Running split-shell, Mac selection, search, and onboarding UI tests on iPad"
  await_simulator "$IPAD_SIMULATOR_ID" "$IPAD_BOOT_PID"
  rm -rf "$IPAD_RESULT_BUNDLE"
  run_with_timeout "$XCODEBUILD_UI_TEST_TIMEOUT" xcodebuild test \
    -collect-test-diagnostics never \
    -project MileageTracker.xcodeproj \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=${IPAD_SIMULATOR_ID}" \
    -derivedDataPath "$DERIVED_DATA" \
    -resultBundlePath "$IPAD_RESULT_BUNDLE" \
    -parallel-testing-enabled NO \
    -only-testing:MileageTrackerUITests/SplitShellUITests \
    -only-testing:MileageTrackerUITests/MacListSelectionUITests \
    -only-testing:MileageTrackerUITests/MacCompactSelectionUITests \
    -only-testing:MileageTrackerUITests/MacOnboardingUITests \
    -only-testing:MileageTrackerUITests/TripSearchSelectionUITests
else
  echo "==> Skipping iPad split-shell UI tests (MILEAGE_RUN_IPAD_UI_TESTS=$RUN_IPAD_UI_TESTS)"
fi

echo "==> Building simulator app without signing"
xcodebuild build \
  -project MileageTracker.xcodeproj \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO

echo "==> Verifying extracted iPhone strings and translation coverage"
scripts/verify_ios_localizations.py "$DERIVED_DATA"

echo "Validation passed ($TIER tier)."
