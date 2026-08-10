#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 4 ]]; then
    echo "Usage: $0 <baseline> <report> <scan-log> <scan-status>"
    exit 2
fi

BASELINE_PATH=$1
REPORT_PATH=$2
SCAN_LOG_PATH=$3
SCAN_STATUS=$4

if [[ ! $SCAN_STATUS =~ ^[0-9]+$ ]]; then
    echo "::error::Periphery scan status must be a non-negative integer"
    exit 1
fi

if [[ $SCAN_STATUS -ne 0 ]]; then
    echo "::error::Periphery scan failed with exit code $SCAN_STATUS"
    [[ -f $SCAN_LOG_PATH ]] && cat "$SCAN_LOG_PATH"
    [[ -f $REPORT_PATH ]] && cat "$REPORT_PATH"
    exit 1
fi

if [[ ! -f $BASELINE_PATH || ! -f $REPORT_PATH || ! -f $SCAN_LOG_PATH ]]; then
    echo "::error::Periphery baseline, report, and scan log files must exist"
    exit 1
fi

if ! grep -Eq '^\[xcode:project\] Loading .*/GenreUpdater\.xcodeproj$' "$SCAN_LOG_PATH" \
    || ! grep -Fxq '* Analyzing...' "$SCAN_LOG_PATH" \
    || ! grep -Eq '^\[index:swift:phase:one\] .+ \(Genre_Updater\) \([0-9.]+s\)$' "$SCAN_LOG_PATH"; then
    echo "::error::Periphery scan log does not prove analysis of the GenreUpdater app target"
    cat "$SCAN_LOG_PATH"
    exit 1
fi

UNUSED_BASELINE=$(awk -F= '$1 == "unused" { print $2 }' "$BASELINE_PATH")
ACCESSIBILITY_BASELINE=$(awk -F= '$1 == "redundant_public_accessibility" { print $2 }' "$BASELINE_PATH")
BASELINE_ENTRY_COUNT=$(awk 'NF { count++ } END { print count + 0 }' "$BASELINE_PATH")
if [[ $BASELINE_ENTRY_COUNT -ne 2 || ! $UNUSED_BASELINE =~ ^[0-9]+$ || ! $ACCESSIBILITY_BASELINE =~ ^[0-9]+$ ]]; then
    echo "::error::Periphery baseline must contain exactly two non-negative integer categories"
    exit 1
fi

UNUSED_COUNT=$(grep -c "warning: Unused" "$REPORT_PATH" || true)
ACCESSIBILITY_COUNT=$(grep -c "warning: Redundant public accessibility" "$REPORT_PATH" || true)
WARNING_COUNT=$(grep -c "warning:" "$REPORT_PATH" || true)
KNOWN_WARNING_COUNT=$((UNUSED_COUNT + ACCESSIBILITY_COUNT))
BASELINE_WARNING_COUNT=$((UNUSED_BASELINE + ACCESSIBILITY_BASELINE))

echo "Unused declarations: ${UNUSED_COUNT} (baseline: ${UNUSED_BASELINE})"
echo "Redundant public accessibility: ${ACCESSIBILITY_COUNT} (baseline: ${ACCESSIBILITY_BASELINE})"
grep "warning:" "$REPORT_PATH" || true

if [[ $WARNING_COUNT -eq 0 && $BASELINE_WARNING_COUNT -gt 0 ]]; then
    echo "::error::Scan reported zero warnings against nonzero baselines; treating as a failed scan"
    cat "$REPORT_PATH"
    exit 1
fi

if [[ $WARNING_COUNT -ne $KNOWN_WARNING_COUNT ]]; then
    echo "::error::Periphery reported an unclassified warning category"
    exit 1
fi

if [[ $UNUSED_COUNT -gt $UNUSED_BASELINE ]]; then
    echo "::error::Unused declarations rose from ${UNUSED_BASELINE} to ${UNUSED_COUNT}"
    exit 1
fi

if [[ $ACCESSIBILITY_COUNT -gt $ACCESSIBILITY_BASELINE ]]; then
    echo "::error::Redundant public accessibility rose from ${ACCESSIBILITY_BASELINE} to ${ACCESSIBILITY_COUNT}"
    exit 1
fi

if [[ $UNUSED_COUNT -lt $UNUSED_BASELINE ]]; then
    echo "::notice::Unused declarations fell to ${UNUSED_COUNT}; lower its baseline to lock it in"
fi

if [[ $ACCESSIBILITY_COUNT -lt $ACCESSIBILITY_BASELINE ]]; then
    echo "::notice::Redundant public accessibility fell to ${ACCESSIBILITY_COUNT}; lower its baseline to lock it in"
fi
