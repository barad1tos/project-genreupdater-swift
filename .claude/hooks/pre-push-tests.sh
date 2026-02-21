#!/usr/bin/env bash
# PreToolUse hook (Bash): Run swift test before pushing.
# Catches test failures before they reach CI.
#
# Fail-safe: DENY (blocking hook — unknown state = safer to block)
# No set -e/-u/-o pipefail (crash = no JSON = allow by default in Claude Code)

# Resolve common.sh relative to this script
HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Inline deny fallback if common.sh cannot be loaded
if [[ ! -f "$HOOK_LIB" ]]; then
  printf '{"decision":"deny","reason":"Hook error: common.sh not found"}\n'
  exit 0
fi
# shellcheck source=lib/common.sh
source "$HOOK_LIB" || { printf '{"decision":"deny","reason":"Hook error: common.sh failed to source"}\n'; exit 0; }

# ERR trap: any unexpected error → DENY
hook_trap_deny

# jq is required for this blocking hook
hook_has_jq || hook_deny "jq not found — cannot validate push safely"

# Project guard: only run in GenreUpdater
hook_is_genreupdater || hook_skip

# Read stdin with timeout
INPUT=$(hook_read_stdin)

# Parse command from tool input
command=$(hook_parse_field "$INPUT" '.tool_input.command')

# Only trigger for git push commands
if ! printf '%s' "$command" | grep -qE 'git\s+push'; then
  hook_skip
fi

# Run tests for Core
core_output=""
core_exit=0
core_output=$(swift test --package-path Packages/Core 2>&1) || core_exit=$?

if [[ "$core_exit" -ne 0 ]]; then
  line_count=$(printf '%s' "$core_output" | wc -l | tr -d ' ')
  if [[ "$line_count" -gt 30 ]]; then
    core_output=$(printf '%s' "$core_output" | tail -30)
    core_output="... (truncated, showing last 30 lines)\n${core_output}"
  fi

  msg="[PRE-PUSH] Core tests failed — fix before pushing."
  msg+=" Run: swift test --package-path Packages/Core"
  msg+=$'\n'"${core_output}"
  hook_deny "$msg"
fi

# Run tests for Services
services_output=""
services_exit=0
services_output=$(swift test --package-path Packages/Services 2>&1) || services_exit=$?

if [[ "$services_exit" -ne 0 ]]; then
  line_count=$(printf '%s' "$services_output" | wc -l | tr -d ' ')
  if [[ "$line_count" -gt 30 ]]; then
    services_output=$(printf '%s' "$services_output" | tail -30)
    services_output="... (truncated, showing last 30 lines)\n${services_output}"
  fi

  msg="[PRE-PUSH] Services tests failed — fix before pushing."
  msg+=" Run: swift test --package-path Packages/Services"
  msg+=$'\n'"${services_output}"
  hook_deny "$msg"
fi

hook_allow "[PRE-PUSH] All tests passed (Core + Services)."
