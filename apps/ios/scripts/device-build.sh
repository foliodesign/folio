#!/bin/bash
set -euo pipefail
export PATH="$PATH:/opt/homebrew/bin"
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$ROOT"
OUTPUT="$ROOT/.tmp/device"
HELPER="$ROOT/apps/ios/scripts/b4-device-discovery.py"
mkdir -p "$OUTPUT"
# The caller holds any shared build lock; this script never takes one.
xcodegen generate --spec apps/ios/project.yml
DISCOVERY_STATUS=0
DEVICE_SELECTION="$(python3 -I "$HELPER" discover "$OUTPUT")" || DISCOVERY_STATUS=$?
if [ "$DISCOVERY_STATUS" -ne 0 ]; then
  echo 'No verified ready device selected. Build/install/launch NOT RUN.'
  exit "$DISCOVERY_STATUS"
fi
DESTINATION='generic/platform=iOS'
DEVICE_ID=''
if [ -n "$DEVICE_SELECTION" ]; then
  read -r DEVICE_ID DEVICE_UDID <<< "$DEVICE_SELECTION"
  DESTINATION="platform=iOS,id=$DEVICE_UDID"
fi
xcodebuild -project apps/ios/Folio.xcodeproj -scheme Folio -configuration Debug \
  -destination "$DESTINATION" -derivedDataPath "$OUTPUT/DerivedData" \
  -jobs 1 -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
if [ -z "$DEVICE_ID" ]; then
  echo 'Signed generic build complete; no verified ready physical device selected. Installation and launch NOT RUN.'
  exit "$DISCOVERY_STATUS"
fi
APP="$OUTPUT/DerivedData/Build/Products/Debug-iphoneos/Folio.app"
# Read the resolved product identity, including any build-setting overrides.
BUNDLE_ID="$(python3 -I "$HELPER" bundle-id "$APP/Info.plist")"
python3 -I "$HELPER" install xcrun devicectl device install app --device "$DEVICE_ID" \
  --timeout 120 "$APP"
EVIDENCE="$(mktemp -d "$OUTPUT/verification-XXXXXXXX")"
python3 -I "$HELPER" crashes-before "$DEVICE_ID" "$EVIDENCE"
# Normal launch only: no defaults, route, lab, tab or terminate-existing arguments.
python3 -I "$HELPER" launch xcrun devicectl device process launch --device "$DEVICE_ID" \
  --timeout 120 "$BUNDLE_ID"
sleep 10
python3 -I "$HELPER" verify "$DEVICE_ID" "$EVIDENCE" "$BUNDLE_ID"
