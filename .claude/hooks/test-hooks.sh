#!/usr/bin/env bash
# Hook validation suite — verifies all hooks produce valid JSON in all scenarios.
# Run: bash .claude/hooks/test-hooks.sh
#
# Tests each hook with various inputs (normal, empty, malformed, edge cases).
# Every test verifies: (1) exit code 0, (2) valid JSON output, (3) completes < 5s.

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
TOTAL=0

# Colors (if terminal supports them)
if [[ -t 1 ]]; then
  GREEN='\033[0;32m'
  RED='\033[0;31m'
  YELLOW='\033[0;33m'
  NC='\033[0m'
else
  GREEN='' RED='' YELLOW='' NC=''
fi

run_test() {
  local name="$1" hook="$2" input="$3" expect_field="${4:-}" expect_value="${5:-}"
  TOTAL=$((TOTAL + 1))

  # Run hook with input, capture output and exit code, with 5s timeout
  local output="" exit_code=0
  output=$(printf '%s' "$input" | timeout 5 bash "$hook" 2>/dev/null) || exit_code=$?

  # Check 1: exit code must be 0
  if [[ "$exit_code" -ne 0 ]]; then
    printf "${RED}FAIL${NC} [%s] exit code %d (expected 0)\n" "$name" "$exit_code"
    printf "     output: %s\n" "$output"
    FAIL=$((FAIL + 1))
    return
  fi

  # Check 2: output must be valid JSON
  if ! printf '%s' "$output" | jq empty 2>/dev/null; then
    printf "${RED}FAIL${NC} [%s] invalid JSON output\n" "$name"
    printf "     output: %s\n" "$output"
    FAIL=$((FAIL + 1))
    return
  fi

  # Check 3: optional field/value assertion
  if [[ -n "$expect_field" ]]; then
    local actual=""
    actual=$(printf '%s' "$output" | jq -r "$expect_field // empty" 2>/dev/null) || actual=""
    if [[ -n "$expect_value" && "$actual" != "$expect_value" ]]; then
      printf "${RED}FAIL${NC} [%s] %s = '%s' (expected '%s')\n" "$name" "$expect_field" "$actual" "$expect_value"
      FAIL=$((FAIL + 1))
      return
    fi
    if [[ -z "$expect_value" && -z "$actual" ]]; then
      printf "${RED}FAIL${NC} [%s] %s is empty (expected non-empty)\n" "$name" "$expect_field"
      FAIL=$((FAIL + 1))
      return
    fi
  fi

  printf "${GREEN}PASS${NC} [%s]\n" "$name"
  PASS=$((PASS + 1))
}

printf "\n${YELLOW}=== Hook Validation Suite ===${NC}\n\n"

# Helper: build a Bash tool_input JSON
make_bash_input() {
  local cmd="$1"
  jq -n --arg c "$cmd" '{"tool_input":{"command":$c}}'
}

# Helper: build an Edit/Write tool_input JSON
make_edit_input() {
  local fp="$1"
  jq -n --arg f "$fp" '{"tool_input":{"file_path":$f}}'
}

# ─── commit-docs-sync-check.sh ───
COMMIT_HOOK="$HOOKS_DIR/commit-docs-sync-check.sh"
printf '%b%s%b\n' "${YELLOW}" "--- commit-docs-sync-check.sh (blocking) ---" "${NC}"

run_test "non-commit command → skip (valid JSON)" \
  "$COMMIT_HOOK" \
  "$(make_bash_input 'ls -la')"

run_test "amend commit → skip" \
  "$COMMIT_HOOK" \
  "$(make_bash_input 'git commit --amend')"

run_test "merge commit → skip" \
  "$COMMIT_HOOK" \
  "$(make_bash_input 'git merge main')"

run_test "empty stdin → valid JSON" \
  "$COMMIT_HOOK" \
  ""

run_test "malformed JSON input → valid JSON" \
  "$COMMIT_HOOK" \
  "this is not json at all"

run_test "partial JSON → valid JSON" \
  "$COMMIT_HOOK" \
  '{"tool_input":{'

run_test "heredoc commit command → detected" \
  "$COMMIT_HOOK" \
  "$(make_bash_input 'git commit -m "$(cat <<'\''EOF'\''
feat: add new feature
EOF
)"')"

run_test "null command field → skip" \
  "$COMMIT_HOOK" \
  '{"tool_input":{"command":null}}'

# ─── swift-task-tracking-reminder.sh ───
SWIFT_HOOK="$HOOKS_DIR/swift-task-tracking-reminder.sh"
printf '\n%b%s%b\n' "${YELLOW}" "--- swift-task-tracking-reminder.sh (advisory) ---" "${NC}"

run_test "non-Swift file → skip" \
  "$SWIFT_HOOK" \
  "$(make_edit_input '/path/to/file.py')"

run_test "Swift file → allow + message" \
  "$SWIFT_HOOK" \
  "$(make_edit_input '/path/to/MyView.swift')" \
  ".decision" "allow"

run_test "Swift file has systemMessage" \
  "$SWIFT_HOOK" \
  "$(make_edit_input '/path/to/MyView.swift')" \
  ".systemMessage"

run_test "empty stdin → valid JSON" \
  "$SWIFT_HOOK" \
  ""

run_test "malformed JSON → valid JSON" \
  "$SWIFT_HOOK" \
  "not json"

run_test "file path with quotes → valid JSON" \
  "$SWIFT_HOOK" \
  "$(make_edit_input '/path/to/"My File".swift')"

run_test "filePath (camelCase) field → detected" \
  "$SWIFT_HOOK" \
  '{"tool_input":{"filePath":"/path/to/Test.swift"}}' \
  ".decision" "allow"

# ─── session-start-phase-context.sh ───
SESSION_HOOK="$HOOKS_DIR/session-start-phase-context.sh"
printf '\n%b%s%b\n' "${YELLOW}" "--- session-start-phase-context.sh (advisory) ---" "${NC}"

run_test "normal run → valid JSON" \
  "$SESSION_HOOK" \
  ""

run_test "normal run → has systemMessage" \
  "$SESSION_HOOK" \
  "" \
  ".systemMessage"

run_test "with random stdin → valid JSON (no hang)" \
  "$SESSION_HOOK" \
  '{"some":"random","data":true}'

# ─── Summary ───
printf "\n${YELLOW}=== Results ===${NC}\n"
printf "Total: %d | ${GREEN}Pass: %d${NC} | ${RED}Fail: %d${NC}\n\n" "$TOTAL" "$PASS" "$FAIL"

if [[ "$FAIL" -gt 0 ]]; then
  printf "${RED}SOME TESTS FAILED${NC}\n"
  exit 1
else
  printf "${GREEN}ALL TESTS PASSED${NC}\n"
  exit 0
fi
