#!/usr/bin/env bash
# PreToolUse hook (Bash): Run SwiftLint before committing Swift files.
# Matches CI exactly: swiftlint lint --strict App Packages/Core/Sources
#   Packages/Services/Sources Packages/SharedUI/Sources
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
hook_has_jq || hook_deny "jq not found — cannot validate commit safely"

# Project guard: only run in GenreUpdater
hook_is_genreupdater || hook_skip

# Read stdin with timeout
INPUT=$(hook_read_stdin)

# Parse command from tool input
command=$(hook_parse_field "$INPUT" '.tool_input.command')

# Only trigger for git commit commands (handles heredoc and multi-line)
if ! printf '%s' "$command" | grep -qE 'git\s+commit'; then
  hook_skip
fi

# Skip for amend commits (merge commits should still be linted)
if printf '%s' "$command" | grep -qE '\-\-amend|\-\-no\-edit'; then
  hook_skip
fi

# Get staged files
staged_files=$(git diff --cached --name-only 2>/dev/null) || staged_files=""

if [[ -z "$staged_files" ]]; then
  hook_skip
fi

# Check if any staged files are Swift
swift_count=$(printf '%s' "$staged_files" | grep -c '\.swift$') || swift_count=0
swift_count=${swift_count:-0}

# No Swift files staged — no SwiftLint check needed
if [[ "$swift_count" -eq 0 ]]; then
  hook_skip
fi

# Check swiftlint is available
if ! command -v swiftlint >/dev/null 2>&1; then
  hook_deny "[SWIFTLINT] swiftlint not found. Install with: brew install swiftlint"
fi

# Run SwiftLint matching CI exactly
lint_output=""
lint_exit=0
lint_output=$(swiftlint lint --strict \
  App \
  Packages/Core/Sources \
  Packages/Services/Sources \
  Packages/SharedUI/Sources 2>&1) || lint_exit=$?

if [[ "$lint_exit" -ne 0 ]]; then
  # Truncate output if too long (keep last 40 lines for most relevant violations)
  line_count=$(printf '%s' "$lint_output" | wc -l | tr -d ' ')
  if [[ "$line_count" -gt 40 ]]; then
    lint_output=$(printf '%s' "$lint_output" | tail -40)
    lint_output="... (truncated, showing last 40 lines)\n${lint_output}"
  fi

  msg="[SWIFTLINT] SwiftLint violations found — fix before committing."
  msg+=" Run: swiftlint lint --strict App Packages/Core/Sources Packages/Services/Sources Packages/SharedUI/Sources"
  msg+=$'\n'"${lint_output}"
  hook_deny "$msg"
fi

hook_allow "[SWIFTLINT] All checks passed for ${swift_count} staged Swift file(s)."
