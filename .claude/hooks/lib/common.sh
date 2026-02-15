#!/usr/bin/env bash
# Shared library for Claude Code hooks.
# Source this from every hook: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
#
# Principles:
#   - Never set -e/-u/-o pipefail (crash = no JSON = allow by default)
#   - Always exit 0 with valid JSON (non-zero = undefined behavior)
#   - Blocking hooks: fail → DENY (unknown state = safer to block)
#   - Advisory hooks: fail → ALLOW (reminder must not block work)
#   - printf instead of echo (no flag injection)
#   - read -t 2 instead of cat (no infinite blocking)

# Read stdin with timeout. Returns content or empty string.
hook_read_stdin() {
  local _input=""
  _input=$(timeout 2 cat 2>/dev/null) || true
  printf '%s' "$_input"
}

# Extract a field from JSON input using jq.
# Usage: value=$(hook_parse_field "$json" '.tool_input.command')
# Returns empty string on any error.
hook_parse_field() {
  local _json="$1" _field="$2"
  local _result=""
  _result=$(printf '%s' "$_json" | jq -r "$_field // empty" 2>/dev/null) || true
  printf '%s' "$_result"
}

# Escape a string for safe JSON embedding via jq.
# Usage: escaped=$(hook_json_escape "$raw_string")
hook_json_escape() {
  local _raw="$1"
  local _escaped=""
  _escaped=$(printf '%s' "$_raw" | jq -Rs . 2>/dev/null) || _escaped='"hook error"'
  printf '%s' "$_escaped"
}

# Output allow decision with optional message and exit 0.
# Usage: hook_allow "message text"
#        hook_allow  (no message = empty JSON object)
hook_allow() {
  local _msg="${1:-}"
  if [[ -n "$_msg" ]]; then
    jq -n --arg m "$_msg" '{"decision":"allow","systemMessage":$m}' 2>/dev/null || printf '{"decision":"allow"}\n'
  else
    printf '{}\n'
  fi
  exit 0
}

# Output deny decision with reason and exit 0.
# Usage: hook_deny "reason text"
hook_deny() {
  local _reason="${1:-Hook denied without reason}"
  jq -n --arg r "$_reason" '{"decision":"deny","reason":$r}' 2>/dev/null || printf '{"decision":"deny","reason":"Hook error"}\n'
  exit 0
}

# Output a session message (for SessionStart hooks) and exit 0.
# Usage: hook_session_message "message text"
hook_session_message() {
  local _msg="${1:-}"
  if [[ -n "$_msg" ]]; then
    jq -n --arg m "$_msg" '{"systemMessage":$m}' 2>/dev/null || printf '{}\n'
  else
    printf '{}\n'
  fi
  exit 0
}

# Skip silently — output empty JSON and exit 0.
hook_skip() {
  printf '{}\n'
  exit 0
}

# Check if current project is GenreUpdater.
# Returns 0 (true) if yes, 1 (false) if no.
hook_is_genreupdater() {
  [[ -f "CLAUDE.md" ]] && grep -q "GenreUpdater" "CLAUDE.md" 2>/dev/null
}

# Check if jq is available.
hook_has_jq() {
  command -v jq >/dev/null 2>&1
}

# Setup ERR trap for BLOCKING hooks (fail → DENY).
# Call this at the top of blocking hooks after sourcing common.sh.
hook_trap_deny() {
  trap 'jq -n --arg r "Hook internal error — denying as precaution" '"'"'{"decision":"deny","reason":$r}'"'"' 2>/dev/null || printf '"'"'{"decision":"deny","reason":"Hook crash"}\n'"'"'; exit 0' ERR
}

# Setup ERR trap for ADVISORY hooks (fail → ALLOW silently).
# Call this at the top of advisory hooks after sourcing common.sh.
hook_trap_allow() {
  trap 'printf '"'"'{}\n'"'"'; exit 0' ERR
}
