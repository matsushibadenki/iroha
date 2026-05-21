#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${ROOT_DIR}/build/logs"
CONFIGURATION="${CONFIGURATION:-Debug}"
BUILD_APP_NAME="iroha.app"
APP_NAME="iroha.app"
DEST_DIR="${HOME}/Library/Input Methods"
DEST_APP="${DEST_DIR}/${APP_NAME}"
DERIVED_DATA_DIR="${DERIVED_DATA_DIR:-${ROOT_DIR}/build/DerivedData}"
BUILD_LOG="${BUILD_LOG:-${LOG_DIR}/dev-install-xcodebuild-$$.log}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister"

cd "$ROOT_DIR"

mkdir -p "$LOG_DIR"

echo "[1/4] Building ${APP_NAME} (${CONFIGURATION})..."
echo "      DerivedData: ${DERIVED_DATA_DIR}"
echo "      Log: ${BUILD_LOG}"

set +e
xcodebuild \
  -project azooKeyMac.xcodeproj \
  -scheme azooKeyMac \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_DIR" \
  -skipPackagePluginValidation \
  -skipMacroValidation \
  build >"$BUILD_LOG" 2>&1
BUILD_STATUS=$?
set -e

if [ "$BUILD_STATUS" -ne 0 ]; then
  echo "xcodebuild failed with status ${BUILD_STATUS}." >&2
  if grep -q "database is locked" "$BUILD_LOG"; then
    echo "The build database is locked. Stop the other Xcode/script build, then run this script again." >&2
  fi
  echo "Last 80 log lines:" >&2
  tail -n 80 "$BUILD_LOG" >&2
  exit "$BUILD_STATUS"
fi

BUILT_APP="${DERIVED_DATA_DIR}/Build/Products/${CONFIGURATION}/${BUILD_APP_NAME}"

echo "[2/4] Checking built app..."
if [ ! -d "$BUILT_APP" ]; then
  echo "Built app was not found: $BUILT_APP" >&2
  exit 1
fi

echo "[3/4] Installing to ${DEST_APP}..."
pkill -x iroha 2>/dev/null || true
mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
/usr/bin/ditto "$BUILT_APP" "$DEST_APP"
# Xcode registers the build product with LaunchServices during Debug builds.
# Keep only the installed Input Methods copy visible to System Settings.
rm -rf "$BUILT_APP"

echo "[4/4] Refreshing input method registration..."
while IFS= read -r stale_app; do
  if [ "$stale_app" != "$DEST_APP" ]; then
    "$LSREGISTER" -u "$stale_app" 2>/dev/null || true
  fi
done < <(find "$HOME/Library/Developer/Xcode/DerivedData" \( -path "*/${BUILD_APP_NAME}" -o -path "*/${APP_NAME}" \) -type d 2>/dev/null)
while IFS= read -r stale_app; do
  if [ "$stale_app" != "$DEST_APP" ]; then
    "$LSREGISTER" -u "$stale_app" 2>/dev/null || true
  fi
done < <(find "$DERIVED_DATA_DIR" \( -path "*/${BUILD_APP_NAME}" -o -path "*/${APP_NAME}" \) -type d 2>/dev/null)

"$LSREGISTER" -f -R -trusted "$DEST_APP"
pkill -x TextInputMenuAgent 2>/dev/null || true
pkill -x TextInputSwitcher 2>/dev/null || true
pkill -x imklaunchagent 2>/dev/null || true

echo "      Selecting iroha Japanese input source..."
swift "$ROOT_DIR/script/select_iroha_input_source.swift" || {
    echo "Could not select iroha automatically." >&2
    echo "Open System Settings > Keyboard > Input Sources and select iroha (Japanese)." >&2
}

echo "Done."
echo "Installed ${APP_NAME} to ${DEST_APP}"
echo "iroha Japanese should now be the selected input source."
