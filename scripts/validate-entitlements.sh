#!/usr/bin/env bash
# Validates every code-signed entitlements file against its approved
# whitelist. Runs on macOS CI runners (plutil + PlistBuddy pre-installed).

set -euo pipefail

PLIST_BUDDY="/usr/libexec/PlistBuddy"
ERRORS=0

error() {
  echo "ERROR: $1" >&2
  ERRORS=$((ERRORS + 1))
}

# Whitelist + completeness + syntax for one entitlements file.
validate_keys() {
  local entitlements="$1"
  shift
  local allowed_keys=("$@")

  if [ ! -f "$entitlements" ]; then
    echo "ERROR: Entitlements file not found at $entitlements" >&2
    exit 1
  fi

  if ! plutil -lint "$entitlements" > /dev/null 2>&1; then
    echo "ERROR: $entitlements is not valid plist" >&2
    exit 1
  fi

  local actual_keys=()
  while IFS= read -r key; do
    [ -n "$key" ] && actual_keys+=("$key")
  done < <("$PLIST_BUDDY" -c "Print" "$entitlements" 2>/dev/null \
    | sed -n 's/^    \([^ ].*\) = .*/\1/p')

  if [ "${#actual_keys[@]}" -eq 0 ]; then
    echo "ERROR: Could not extract any keys from $entitlements" >&2
    exit 1
  fi

  local actual allowed found
  for actual in "${actual_keys[@]}"; do
    found=0
    for allowed in "${allowed_keys[@]}"; do
      if [ "$actual" = "$allowed" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      error "$entitlements: unexpected entitlement key: $actual"
    fi
  done

  for allowed in "${allowed_keys[@]}"; do
    found=0
    for actual in "${actual_keys[@]}"; do
      if [ "$actual" = "$allowed" ]; then
        found=1
        break
      fi
    done
    if [ "$found" -eq 0 ]; then
      error "$entitlements: missing required entitlement key: $allowed"
    fi
  done

  if grep -q "temporary-exception" "$entitlements"; then
    error "$entitlements: forbidden temporary-exception key(s)"
  fi
}

# --- App target ---
APP_ENTITLEMENTS="App/GenreUpdater.entitlements"
validate_keys "$APP_ENTITLEMENTS" \
  "com.apple.security.app-sandbox" \
  "com.apple.security.scripting-targets" \
  "com.apple.security.network.client" \
  "com.apple.developer.ubiquity-kvstore-identifier"

SANDBOX=$("$PLIST_BUDDY" -c "Print :com.apple.security.app-sandbox" "$APP_ENTITLEMENTS" 2>/dev/null)
if [ "$SANDBOX" != "true" ]; then
  error "$APP_ENTITLEMENTS: app-sandbox must be true, got: $SANDBOX"
fi

NETWORK=$("$PLIST_BUDDY" -c "Print :com.apple.security.network.client" "$APP_ENTITLEMENTS" 2>/dev/null)
if [ "$NETWORK" != "true" ]; then
  error "$APP_ENTITLEMENTS: network.client must be true, got: $NETWORK"
fi

if ! "$PLIST_BUDDY" -c "Print :com.apple.security.scripting-targets:com.apple.Music" "$APP_ENTITLEMENTS" > /dev/null 2>&1; then
  error "$APP_ENTITLEMENTS: scripting-targets must contain com.apple.Music"
fi

# --- Bundled waker agent: sandboxed, read-only Music assets, NOTHING else
# (no network, no scripting, no inherit — it only watches and nudges) ---
AGENT_ENTITLEMENTS="Agent/GenreUpdaterAgent.entitlements"
validate_keys "$AGENT_ENTITLEMENTS" \
  "com.apple.security.app-sandbox" \
  "com.apple.security.assets.music.read-only"

AGENT_SANDBOX=$("$PLIST_BUDDY" -c "Print :com.apple.security.app-sandbox" "$AGENT_ENTITLEMENTS" 2>/dev/null)
if [ "$AGENT_SANDBOX" != "true" ]; then
  error "$AGENT_ENTITLEMENTS: app-sandbox must be true, got: $AGENT_SANDBOX"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "Entitlements validation FAILED ($ERRORS error(s))" >&2
  exit 1
fi

echo "Entitlements validation passed"
exit 0
