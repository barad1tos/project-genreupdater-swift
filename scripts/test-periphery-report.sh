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
    local scan_log=${6-"$valid_scan_log"}
    local case_directory="$TEMPORARY_DIRECTORY/$name"
    mkdir -p "$case_directory"
    printf '%b' "$baseline" > "$case_directory/baseline"
    printf '%b' "$report" > "$case_directory/report"
    printf '%b' "$scan_log" > "$case_directory/scan.log"

    local actual_status
    if bash "$VALIDATOR" \
        "$case_directory/baseline" \
        "$case_directory/report" \
        "$case_directory/scan.log" \
        "$scan_status" > "$case_directory/output" 2>&1; then
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
valid_scan_log='[xcode:project] Loading /tmp/GenreUpdater.xcodeproj\n* Analyzing...\n[index:swift:phase:one] /tmp/App.swift (Genre_Updater) (0.001s)\n'
one_each_baseline='unused=1\nredundant_public_accessibility=1\n'
zero_baseline='unused=0\nredundant_public_accessibility=0\n'

run_case exact-baseline 0 \
    "$one_each_baseline" \
    "$unused_warning\n$access_warning\n"
run_case reduced-debt 0 \
    'unused=2\nredundant_public_accessibility=2\n' \
    "$unused_warning\n$access_warning\n"
run_case zero-clean-report 0 \
    "$zero_baseline" \
    ''
run_case zero-missing-project 1 \
    "$zero_baseline" \
    '' \
    0 \
    '* Analyzing...\n[index:swift:phase:one] /tmp/App.swift (Genre_Updater) (0.001s)\n'
run_case zero-missing-analysis 1 \
    "$zero_baseline" \
    '' \
    0 \
    '[xcode:project] Loading /tmp/GenreUpdater.xcodeproj\n[index:swift:phase:one] /tmp/App.swift (Genre_Updater) (0.001s)\n'
run_case zero-missing-app-unit 1 \
    "$zero_baseline" \
    '' \
    0 \
    '[xcode:project] Loading /tmp/GenreUpdater.xcodeproj\n* Analyzing...\n'
run_case scanner-failure 1 \
    "$one_each_baseline" \
    'Periphery failed before producing diagnostics\n' \
    2 \
    'Periphery terminated before analysis\n'
run_case malformed-baseline 1 \
    'unused=one\nredundant_public_accessibility=1\n' \
    "$unused_warning\n$access_warning\n"
run_case empty-report 1 \
    "$one_each_baseline" \
    ''
run_case unknown-category 1 \
    "$zero_baseline" \
    '/tmp/Other.swift:1:1: warning: New Periphery category\n'
run_case unused-growth 1 \
    "$one_each_baseline" \
    "$unused_warning\n$unused_warning\n$access_warning\n"
run_case accessibility-growth 1 \
    "$one_each_baseline" \
    "$unused_warning\n$access_warning\n$access_warning\n"
run_case cross-category-masking 1 \
    "$one_each_baseline" \
    "$unused_warning\n$unused_warning\n"

echo "Periphery report contract tests passed"
