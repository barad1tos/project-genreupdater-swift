#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): Remind to update task tracking when editing .swift files.
# Advisory only (always allows, adds systemMessage for .swift edits).
#
# Fail-safe: ALLOW (advisory hook — reminder must not block work)
# No set -e/-u/-o pipefail

# Resolve common.sh relative to this script
HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Silent skip if common.sh cannot be loaded (advisory = never block)
if [[ ! -f "$HOOK_LIB" ]]; then
  printf '{}\n'
  exit 0
fi
# shellcheck source=lib/common.sh
source "$HOOK_LIB" || { printf '{}\n'; exit 0; }

# ERR trap: any unexpected error → ALLOW silently
hook_trap_allow

# jq check — skip silently if missing (advisory hook)
hook_has_jq || hook_skip

# Project guard: only run in GenreUpdater
hook_is_genreupdater || hook_skip

# Read stdin with timeout
INPUT=$(hook_read_stdin)

# Extract file_path from tool input (try file_path, fallback filePath)
file_path=$(hook_parse_field "$INPUT" '.tool_input.file_path')
if [[ -z "$file_path" ]]; then
  file_path=$(hook_parse_field "$INPUT" '.tool_input.filePath')
fi

# Only trigger for .swift files
if [[ "$file_path" != *.swift ]]; then
  hook_skip
fi

# Find current phase task file
TASKS_DIR="docs/tasks"
task_file=""
if [[ -d "$TASKS_DIR" ]]; then
  for f in "$TASKS_DIR"/phase-*.md; do
    [[ -f "$f" ]] || continue
    status=$(awk '/^---$/{n++; next} n==1 && /^status:/{sub(/^status: */, ""); print; exit}' "$f" 2>/dev/null) || status=""
    if [[ "$status" == "active" ]]; then
      task_file="$(basename "$f")"
      break
    elif [[ "$status" == "planned" && -z "$task_file" ]]; then
      task_file="$(basename "$f")"
    fi
  done
fi

task_ref="docs/tasks/${task_file:-phase-*.md}"
base_name=$(basename "$file_path" 2>/dev/null) || base_name="$file_path"

# Build reminder message
msg="[TASK TRACKING] Editing Swift file: ${base_name}"
msg+=" | After this change, remember to:"
msg+=" (1) Update checkboxes in ${task_ref} for completed deliverables"
msg+=" (2) Add new files to the Files table in the task file"
msg+=" (3) Update docs/plans/TDD.md if architectural patterns changed"
msg+=" | Swift quality: ensure public access for cross-package types, use Core.Track in Services, .private for user data in logs"

# Advisory: allow + systemMessage
hook_allow "$msg"
