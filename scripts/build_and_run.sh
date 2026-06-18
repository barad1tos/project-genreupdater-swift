#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_NAME="GenreUpdater"
SCHEME="GenreUpdater"
APP_NAME="Genre Updater"
PROCESS_NAME="Genre Updater"
LOG_SUBSYSTEM_PREFIX="com.genreupdater"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA_PATH="$ROOT_DIR/.build/XcodeDerivedData"
APP_BUNDLE="$DERIVED_DATA_PATH/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
SOURCE_ENTITLEMENTS="$ROOT_DIR/App/GenreUpdater.entitlements"
LOCAL_ENTITLEMENTS="$DERIVED_DATA_PATH/GenreUpdater.local.entitlements"

usage() {
  cat >&2 <<USAGE
usage: $0 [run|--debug|--logs|--telemetry|--verify]

Modes:
  run          Build, stop the old app, and launch the fresh app bundle.
  --verify    Run, then verify the fresh process is alive.
  --logs      Run, then stream logs for the app process.
  --telemetry Run, then stream unified logs for GenreUpdater subsystems.
  --debug     Run, then attach lldb to the launched app process.
USAGE
}

build_app() {
  local destination_spec
  destination_spec="$(build_destination)"

  xcodebuild build -quiet \
    -project "$ROOT_DIR/$PROJECT_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -destination "$destination_spec" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO
}

build_destination() {
  local host_arch
  host_arch="$(uname -m 2>/dev/null || true)"

  case "$host_arch" in
    arm64|x86_64)
      printf 'platform=macOS,arch=%s\n' "$host_arch"
      ;;
    *)
      printf 'platform=macOS\n'
      ;;
  esac
}

sign_app_for_local_run() {
  mkdir -p "$(dirname "$LOCAL_ENTITLEMENTS")"
  cp "$SOURCE_ENTITLEMENTS" "$LOCAL_ENTITLEMENTS"

  # Local ad-hoc signing cannot satisfy the iCloud KVS entitlement without a
  # provisioning profile. Keep the source entitlements intact for release builds,
  # but omit KVS for Codex/local runs so Keychain and Music scripting can work.
  /usr/libexec/PlistBuddy \
    -c "Delete :com.apple.developer.ubiquity-kvstore-identifier" \
    "$LOCAL_ENTITLEMENTS" >/dev/null 2>&1 || true

  /usr/bin/codesign --force --sign - --entitlements "$LOCAL_ENTITLEMENTS" "$APP_BUNDLE"
}

stop_existing_app() {
  pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

process_id() {
  pgrep -nx "$PROCESS_NAME"
}

verify_app() {
  sleep 1
  local pid
  pid="$(process_id)"
  [[ -n "$pid" ]]
  echo "$PROCESS_NAME is running with PID $pid"
  echo "$APP_BINARY"
}

run_app() {
  build_app
  [[ -x "$APP_BINARY" ]]
  sign_app_for_local_run
  stop_existing_app
  open_app
}

case "$MODE" in
  run)
    run_app
    ;;
  --verify|verify)
    run_app
    verify_app
    ;;
  --logs|logs)
    run_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$PROCESS_NAME\""
    ;;
  --telemetry|telemetry)
    run_app
    /usr/bin/log stream --info --style compact --predicate "subsystem BEGINSWITH \"$LOG_SUBSYSTEM_PREFIX\""
    ;;
  --debug|debug)
    run_app
    sleep 1
    exec lldb -p "$(process_id)"
    ;;
  --help|help|-h)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
