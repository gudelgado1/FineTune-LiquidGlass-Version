#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="${DERIVED_DATA:-/private/tmp/FineTuneProfileBuild}"
OUTPUT_DIR="${OUTPUT_DIR:-/private/tmp/FineTuneProfiles}"
TEMPLATE="${TEMPLATE:-Time Profiler}"
TIME_LIMIT="${TIME_LIMIT:-60s}"
SCHEME="${SCHEME:-FineTune}"
CONFIGURATION="${CONFIGURATION:-Debug}"

mkdir -p "$OUTPUT_DIR"

if [[ ! -d "$ROOT_DIR/FineTune" ]]; then
  echo "error: Missing app source directory: $ROOT_DIR/FineTune" >&2
  echo "Restore the FineTune/ folder before building or profiling." >&2
  exit 66
fi

if [[ ! -f "$ROOT_DIR/FineTune/FineTune.entitlements" ]]; then
  echo "error: Missing entitlements file: $ROOT_DIR/FineTune/FineTune.entitlements" >&2
  echo "Restore the FineTune/ folder or the entitlements file before building or profiling." >&2
  exit 66
fi

DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcodebuild build \
  -project "$ROOT_DIR/FineTune.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -destination 'platform=macOS,arch=arm64'

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/FineTune.app"
STAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_PATH="$OUTPUT_DIR/FineTune-$TEMPLATE-$STAMP.trace"

echo "Recording $TEMPLATE for $TIME_LIMIT"
echo "App: $APP_PATH"
echo "Trace: $TRACE_PATH"

set +e
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
xcrun xctrace record \
  --template "$TEMPLATE" \
  --time-limit "$TIME_LIMIT" \
  --output "$TRACE_PATH" \
  --launch -- "$APP_PATH"
XCTRACE_STATUS=$?
set -e

if [[ $XCTRACE_STATUS -ne 0 && ! -d "$TRACE_PATH" ]]; then
  exit "$XCTRACE_STATUS"
fi

echo "Saved trace: $TRACE_PATH"
