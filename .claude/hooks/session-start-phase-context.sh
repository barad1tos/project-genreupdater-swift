#!/usr/bin/env bash
# SessionStart hook: Load current phase context for GenreUpdater project.
# Scans docs/tasks/phase-*.md for active/planned phases, counts progress.
#
# Fail-safe: ALLOW (advisory hook — context loading must not block session)
# No set -e/-u/-o pipefail

# Resolve common.sh relative to this script
HOOK_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Silent skip if common.sh cannot be loaded
if [[ ! -f "$HOOK_LIB" ]]; then
  printf '{}\n'
  exit 0
fi
# shellcheck source=lib/common.sh
source "$HOOK_LIB" || { printf '{}\n'; exit 0; }

# ERR trap: any unexpected error → ALLOW silently
hook_trap_allow

# jq check — skip silently if missing
hook_has_jq || hook_skip

# Project guard: only run in GenreUpdater
hook_is_genreupdater || hook_skip

# Consume stdin (SessionStart may or may not provide input)
hook_read_stdin >/dev/null

TASKS_DIR="docs/tasks"

# Check if tasks directory exists and has files
if [[ ! -d "$TASKS_DIR" ]]; then
  hook_session_message "[SCRUM MASTER] No docs/tasks/ directory found. Create phase task files before starting development."
fi

# Find active phase first, then first planned phase
active_file=""
active_phase=""
active_title=""
active_status=""

for task_file in "$TASKS_DIR"/phase-*.md; do
  [[ -f "$task_file" ]] || continue

  # Parse frontmatter (between --- markers) using awk for macOS compatibility
  phase=$(awk '/^---$/{n++; next} n==1 && /^phase:/{sub(/^phase: */, ""); print; exit}' "$task_file" 2>/dev/null) || phase=""
  title=$(awk '/^---$/{n++; next} n==1 && /^title:/{sub(/^title: *"?/, ""); sub(/"$/, ""); print; exit}' "$task_file" 2>/dev/null) || title=""
  status=$(awk '/^---$/{n++; next} n==1 && /^status:/{sub(/^status: */, ""); print; exit}' "$task_file" 2>/dev/null) || status=""

  # Prefer active, fallback to first planned
  if [[ "$status" == "active" ]]; then
    active_file="$task_file"
    active_phase="$phase"
    active_title="$title"
    active_status="active"
    break
  elif [[ "$status" == "planned" && -z "$active_file" ]]; then
    active_file="$task_file"
    active_phase="$phase"
    active_title="$title"
    active_status="planned"
  fi
done

if [[ -z "$active_file" ]]; then
  hook_session_message "[SCRUM MASTER] All phases complete or no task files found. Run @scrum-master for full status."
fi

# Count checkboxes in the active task file (grep -c exits 1 on no match)
done_count=$(grep -c '^\- \[x\]' "$active_file" 2>/dev/null) || done_count=0
done_count=${done_count:-0}
total_count=$(grep -c '^\- \[[ x]\]' "$active_file" 2>/dev/null) || total_count=0
total_count=${total_count:-0}

# Build context message
base_name=$(basename "$active_file" 2>/dev/null) || base_name="unknown"
msg="[SCRUM MASTER] Phase ${active_phase}: ${active_title}"
msg+=" | Status: ${active_status} | Progress: ${done_count}/${total_count} tasks"
msg+=" | BEFORE CODING: read docs/tasks/${base_name} + docs/plans/TDD.md"
msg+=" | After significant changes: update task checkboxes + CLAUDE.md Phase Status"

hook_session_message "$msg"
