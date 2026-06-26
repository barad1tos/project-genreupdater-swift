#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-.build/xcode}"
DESTINATION="${XCODE_DESTINATION:-platform=macOS,arch=arm64}"
CONFIGURATION="${XCODE_CONFIGURATION:-Debug}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required for the Xcode app gate" >&2
  exit 127
fi

xcodegen generate

COMMON_ARGS=(
  -project GenreUpdater.xcodeproj
  -scheme GenreUpdater
  -configuration "$CONFIGURATION"
  -destination "$DESTINATION"
  -derivedDataPath "$DERIVED_DATA_PATH"
  CODE_SIGN_IDENTITY=-
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGNING_ALLOWED=NO
  -quiet
)

xcodebuild build "${COMMON_ARGS[@]}"
xcodebuild test "${COMMON_ARGS[@]}"
