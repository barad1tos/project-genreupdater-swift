#!/usr/bin/env bash
# PreToolUse hook (Bash): Check docs sync when committing.
# Any Swift file without docs = BLOCK. No tiers, no bypass via split commits.
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

# Skip for amend/no-edit/merge commits
if printf '%s' "$command" | grep -qE '\-\-amend|\-\-no\-edit|merge'; then
  hook_skip
fi

# Get staged files
staged_files=$(git diff --cached --name-only 2>/dev/null) || staged_files=""

if [[ -z "$staged_files" ]]; then
  hook_skip
fi

# Count staged Swift files (grep -c exits 1 on no match)
swift_count=$(printf '%s' "$staged_files" | grep -c '\.swift$') || swift_count=0
swift_count=${swift_count:-0}

# Check if docs are already staged
has_docs=$(printf '%s' "$staged_files" | grep -cE '^(docs/|CLAUDE\.md)') || has_docs=0
has_docs=${has_docs:-0}

# No Swift files staged — no check needed
if [[ "$swift_count" -eq 0 ]]; then
  hook_skip
fi

# Docs already staged — allow with positive feedback
if [[ "$has_docs" -gt 0 ]]; then
  hook_allow "[DOCS SYNC] Documentation files included in commit. Good practice!"
fi

# Any Swift file(s) without docs — BLOCK (no tiers, no bypass via split commits)
msg="[DOCS SYNC REQUIRED] Committing ${swift_count} Swift file(s) without any documentation updates."
msg+=" Every Swift commit requires at least one docs file."
msg+=" Please stage at least one of: docs/tasks/*.md, docs/plans/TDD.md, CLAUDE.md"
msg+=" Then retry the commit."
hook_deny "$msg"
