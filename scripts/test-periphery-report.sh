#!/usr/bin/env bash

set -euo pipefail

REPOSITORY_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VALIDATOR="$REPOSITORY_ROOT/scripts/validate-periphery-report.sh"
TEMPORARY_DIRECTORY=$(mktemp -d)
trap 'rm -rf "$TEMPORARY_DIRECTORY"' EXIT

run_case() {
    local name=$1
    local expected_status=$2
    local baseline=$3
    local report=$4
    local scan_status=${5:-0}
    local case_directory="$TEMPORARY_DIRECTORY/$name"
    mkdir -p "$case_directory"
    printf '%b' "$baseline" > "$case_directory/baseline"
    printf '%b' "$report" > "$case_directory/report"

    local actual_status
    if bash "$VALIDATOR" "$case_directory/baseline" "$case_directory/report" "$scan_status" \
        > "$case_directory/output" 2>&1; then
        actual_status=0
    else
        actual_status=$?
    fi

    if [[ $actual_status -ne $expected_status ]]; then
        echo "Case '$name' returned $actual_status; expected $expected_status"
        cat "$case_directory/output"
        return 1
    fi
}

unused_warning='/tmp/Unused.swift:1:1: warning: Unused declaration'
access_warning='/tmp/Public.swift:1:1: warning: Redundant public accessibility'

run_case exact-baseline 0 \
    'unused=1\nredundant_public_accessibility=1\n' \
    "$unused_warning\n$access_warning\n"
run_case reduced-debt 0 \
    'unused=2\nredundant_public_accessibility=2\n' \
    "$unused_warning\n$access_warning\n"
run_case scanner-failure 1 \
    'unused=1\nredundant_public_accessibility=1\n' \
    'Periphery failed before producing diagnostics\n' \
    2
run_case malformed-baseline 1 \
    'unused=one\nredundant_public_accessibility=1\n' \
    "$unused_warning\n$access_warning\n"
run_case empty-report 1 \
    'unused=1\nredundant_public_accessibility=1\n' \
    ''
run_case unknown-category 1 \
    'unused=0\nredundant_public_accessibility=0\n' \
    '/tmp/Other.swift:1:1: warning: New Periphery category\n'
run_case unused-growth 1 \
    'unused=1\nredundant_public_accessibility=1\n' \
    "$unused_warning\n$unused_warning\n$access_warning\n"
run_case accessibility-growth 1 \
    'unused=1\nredundant_public_accessibility=1\n' \
    "$unused_warning\n$access_warning\n$access_warning\n"
run_case cross-category-masking 1 \
    'unused=1\nredundant_public_accessibility=1\n' \
    "$unused_warning\n$unused_warning\n"

echo "Periphery report contract tests passed"
