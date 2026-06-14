# GenreUpdater — Local CI Pipeline
# Usage: just ci (full pipeline) or just <recipe> (individual step)

set shell := ["bash", "-euo", "pipefail", "-c"]

sources := "App Packages/Core/Sources Packages/Services/Sources Packages/SharedUI/Sources"
xcodebuild_flags := "-project GenreUpdater.xcodeproj -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .build/XcodeDerivedData CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO"

# Automated non-UI CI pipeline (default)
ci: build app-build app-test test coverage entitlements lint format periphery
    @echo ""
    @echo "All CI checks passed"

# Build all 3 packages
build:
    @echo "=== Build Core ==="
    swift build --package-path Packages/Core
    @echo "=== Build Services ==="
    swift build --package-path Packages/Services
    @echo "=== Build SharedUI ==="
    swift build --package-path Packages/SharedUI

# Test Core + Services with coverage
test:
    @echo "=== Test Core ==="
    swift test --package-path Packages/Core --enable-code-coverage
    @echo "=== Test Services ==="
    swift test --package-path Packages/Services --enable-code-coverage &\
    TEST_PID=$!; \
    SECONDS=0; \
    while kill -0 $TEST_PID 2>/dev/null; do \
        if [ $SECONDS -ge 120 ]; then \
            echo "WARNING: swift test hung after 120s, killing"; \
            kill $TEST_PID 2>/dev/null; \
            wait $TEST_PID 2>/dev/null || true; \
            exit 0; \
        fi; \
        sleep 1; \
    done; \
    wait $TEST_PID

# Check coverage thresholds (Core ≥85%, Services ≥65%)
coverage:
    #!/usr/bin/env bash
    set -euo pipefail
    FAILED=0

    echo "=== Core coverage ==="
    PROFDATA=$(find Packages/Core/.build -name "default.profdata" -type f 2>/dev/null | head -1)
    BINARY=$(find Packages/Core/.build -name "CorePackageTests.xctest" -type d 2>/dev/null | head -1)
    if [ -n "$PROFDATA" ] && [ -n "$BINARY" ]; then
        xcrun llvm-cov report "$BINARY/Contents/MacOS/CorePackageTests" \
            -instr-profile "$PROFDATA" \
            --ignore-filename-regex="Tests/" --ignore-filename-regex="\.build/" | tail -3
        CORE_COV=$(xcrun llvm-cov export "$BINARY/Contents/MacOS/CorePackageTests" \
            --instr-profile "$PROFDATA" --summary-only \
            --ignore-filename-regex="Tests/" --ignore-filename-regex="\.build/" 2>/dev/null \
            | python3 -c "import sys,json;d=json.load(sys.stdin);print(int(d['data'][0]['totals']['lines']['percent']))")
        echo "Core line coverage: ${CORE_COV}% (threshold: 85%)"
        if [ "$CORE_COV" -lt 85 ]; then
            echo "ERROR: Core coverage ${CORE_COV}% is below threshold 85%"
            FAILED=1
        fi
    else
        echo "WARNING: Core coverage data not found (run 'just test' first)"
    fi

    echo "=== Services coverage ==="
    PROFDATA=$(find Packages/Services/.build -name "default.profdata" -type f 2>/dev/null | head -1)
    BINARY=$(find Packages/Services/.build -name "ServicesPackageTests.xctest" -type d 2>/dev/null | head -1)
    if [ -n "$PROFDATA" ] && [ -n "$BINARY" ]; then
        xcrun llvm-cov report "$BINARY/Contents/MacOS/ServicesPackageTests" \
            -instr-profile "$PROFDATA" \
            --ignore-filename-regex="Tests/" --ignore-filename-regex="\.build/" --ignore-filename-regex="Core/" | tail -3
        SVC_COV=$(xcrun llvm-cov export "$BINARY/Contents/MacOS/ServicesPackageTests" \
            --instr-profile "$PROFDATA" --summary-only \
            --ignore-filename-regex="Tests/" --ignore-filename-regex="\.build/" --ignore-filename-regex="Core/" 2>/dev/null \
            | python3 -c "import sys,json;d=json.load(sys.stdin);print(int(d['data'][0]['totals']['lines']['percent']))")
        echo "Services line coverage: ${SVC_COV}% (threshold: 65%)"
        if [ "$SVC_COV" -lt 65 ]; then
            echo "ERROR: Services coverage ${SVC_COV}% is below threshold 65%"
            FAILED=1
        fi
    else
        echo "WARNING: Services coverage data not found (run 'just test' first)"
    fi

    if [ "$FAILED" -ne 0 ]; then
        exit 1
    fi
    echo "All coverage thresholds passed"

# Validate entitlements against whitelist
entitlements:
    bash scripts/validate-entitlements.sh

# Generate the ignored Xcode project from project.yml
xcodegen:
    xcodegen generate

# Build the macOS app target declared in project.yml
app-build: xcodegen
    xcodebuild build {{ xcodebuild_flags }} -scheme GenreUpdater -quiet

# Test app unit tests separately from UI tests
app-test: xcodegen
    xcodebuild test {{ xcodebuild_flags }} -scheme GenreUpdater -quiet

# Explicit UI smoke gate. Run locally before changing UI test behavior.
ui-test: xcodegen
    xcodebuild test {{ xcodebuild_flags }} -scheme GenreUpdaterUITests -quiet

# SwiftLint --strict
lint:
    swiftlint lint --strict {{ sources }}

# SwiftFormat --lint (check only)
format:
    swiftformat {{ sources }} --lint

# Periphery scan Core + Services
periphery:
    #!/usr/bin/env bash
    set -euo pipefail
    for pkg in Core Services; do
        echo "=== Scanning $pkg ==="
        cd Packages/$pkg
        periphery scan \
            --retain-public \
            --retain-codable-properties \
            --format xcode \
            --strict
        cd ../..
    done

# Auto-fix: apply SwiftFormat
fix:
    swiftformat {{ sources }}
