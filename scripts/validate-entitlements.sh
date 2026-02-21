#!/usr/bin/env bash
# Validates GenreUpdater.entitlements against the approved whitelist.
# Runs on macOS CI runners (plutil + PlistBuddy are pre-installed).

set -euo pipefail

ENTITLEMENTS="App/GenreUpdater.entitlements"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
ERRORS=0

# Allowed entitlement keys (exhaustive whitelist)
ALLOWED_KEYS=(
  "com.apple.security.app-sandbox"
  "com.apple.security.scripting-targets"
  "com.apple.security.network.client"
  "com.apple.developer.ubiquity-kvstore-identifier"
)

error() {
  echo "ERROR: $1" >&2
  ERRORS=$((ERRORS + 1))
}

if [ ! -f "$ENTITLEMENTS" ]; then
  echo "ERROR: Entitlements file not found at $ENTITLEMENTS" >&2
  exit 1
fi

# Validate plist syntax
if ! plutil -lint "$ENTITLEMENTS" > /dev/null 2>&1; then
  echo "ERROR: Entitlements file is not valid plist" >&2
  exit 1
fi

# Extract top-level keys via PlistBuddy (indent=4 spaces, pattern: "    key = value")
ACTUAL_KEYS=()
while IFS= read -r key; do
  [ -n "$key" ] && ACTUAL_KEYS+=("$key")
done < <("$PLIST_BUDDY" -c "Print" "$ENTITLEMENTS" 2>/dev/null \
  | sed -n 's/^    \([^ ].*\) = .*/\1/p')

if [ "${#ACTUAL_KEYS[@]}" -eq 0 ]; then
  echo "ERROR: Could not extract any keys from $ENTITLEMENTS" >&2
  exit 1
fi

# Whitelist check: every key in the file must be in the allowed list
for actual in "${ACTUAL_KEYS[@]}"; do
  found=0
  for allowed in "${ALLOWED_KEYS[@]}"; do
    if [ "$actual" = "$allowed" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    error "Unexpected entitlement key: $actual"
  fi
done

# Completeness check: every allowed key must be present
for allowed in "${ALLOWED_KEYS[@]}"; do
  found=0
  for actual in "${ACTUAL_KEYS[@]}"; do
    if [ "$actual" = "$allowed" ]; then
      found=1
      break
    fi
  done
  if [ "$found" -eq 0 ]; then
    error "Missing required entitlement key: $allowed"
  fi
done

# Value checks
SANDBOX=$("$PLIST_BUDDY" -c "Print :com.apple.security.app-sandbox" "$ENTITLEMENTS" 2>/dev/null)
if [ "$SANDBOX" != "true" ]; then
  error "app-sandbox must be true, got: $SANDBOX"
fi

NETWORK=$("$PLIST_BUDDY" -c "Print :com.apple.security.network.client" "$ENTITLEMENTS" 2>/dev/null)
if [ "$NETWORK" != "true" ]; then
  error "network.client must be true, got: $NETWORK"
fi

# scripting-targets must contain com.apple.Music
if ! "$PLIST_BUDDY" -c "Print :com.apple.security.scripting-targets:com.apple.Music" "$ENTITLEMENTS" > /dev/null 2>&1; then
  error "scripting-targets must contain com.apple.Music"
fi

# Forbidden: no temporary-exception keys
if grep -q "temporary-exception" "$ENTITLEMENTS"; then
  error "Forbidden: entitlements contain temporary-exception key(s)"
fi

if [ "$ERRORS" -gt 0 ]; then
  echo "Entitlements validation FAILED ($ERRORS error(s))" >&2
  exit 1
fi

echo "Entitlements validation passed"
exit 0
