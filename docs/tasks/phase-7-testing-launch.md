---
phase: 7
title: "Testing + Launch"
status: active
priority: high
depends_on:
  - "Phase 6 (views)"
---
> Parent: [[PRD]]

**Related:** [[phase-6-views-polish|Phase 6: Views + Polish]]
**Technical ref:** [[TDD#Risks & Mitigation]] | [[TDD#LOC Estimates]]

# Phase 7: Testing + Launch

## Context

Фінальна фаза: comprehensive тестування, performance profiling, parallel run з Python-версією, підготовка до App Review та публікація в Mac App Store.

## Sub-Phase Progress

### 7A: Test Coverage Expansion
- [x] A1: Extract shared test mocks to TestHelpers.swift
- [x] A2: InputSanitizer tests (32 tests, security critical)
- [x] A3: Track model tests (24 tests)
- [x] A4: AppConfiguration tests
- [x] A5: TrackStatus extended tests
- [x] A6: GRDB models tests
- [x] A7: SwiftData persistence model tests
- [x] A8: Logging infrastructure tests (6 tests)

### 7B: Performance & Instrumentation
- [x] B1: SignpostMarkers utility (AppSignpost enum)
- [x] B2: Signpost markers in 8 critical paths
- [x] B3: Performance regression test stubs (8 tests)
- [x] B4: CI coverage reporting (.github/workflows/ci.yml)

### 7C: Parity Testing Enhancement
- [x] C1: Expanded parity test fixtures (5 JSON files)
- [x] C2: Parallel run runbook

### 7D: App Store Preparation
- [x] D1: NSUserAppleScriptTask justification
- [x] D2: Privacy policy
- [x] D3: App Store listing
- [x] D4: Launch checklist
- [x] D5: Task file updated with sub-phase structure

### 7E: Phase 6-7 Gap Closure
- [x] E1: Fix store-listing.md pricing (500 lifetime, Week Pass, $4.99/mo, $29.99/yr)
- [x] E2: Sidebar sections (By Artist, By Album, Recent Changes, Playlists stub)
- [x] E3: CSV Export (CSVExporter + ReportsView toolbar button, feature-gated)
- [x] E4: Custom Genre Mappings (AppConfiguration + GenreDeterminator + SettingsView)
- [x] E5: Keyboard Shortcuts (Cmd+1..9 via NavigationCommands)
- [x] E6: Accessibility audit (Dynamic Type, WCAG AA colors, VoiceOver labels)
- [x] E7: testArtists filtering in MusicLibraryReader
- [x] E8: Dry-run mode UI + DryRunReport
- [x] E9: Integration tests (MusicKit + AppleScript, local only)
- [x] E10: Coverage targets raised (Core 94%, Services 69%) + CI enforcement
- [x] E11: Entitlements validation CI step
- [x] E12: Xcode Cloud decision (GitHub Actions CI + Xcode Cloud distribution)
- [x] E13: XCUITests for critical flows (OnboardingFlow, Navigation, UpdateFlow)
- [x] E14: Documentation sync (launch-checklist, phase-7, CLAUDE.md)
- [x] E15: Reports empty state CTA, year distribution aggregation, undo callback wiring
- [x] E16: Reports "Go to Update" navigation via notification

### Files Created/Modified in Phase 7

| File | Sub-Phase | Action |
|------|-----------|--------|
| `Services/Tests/ServicesTests/TestHelpers.swift` | 7A | New |
| `Services/Tests/ServicesTests/InputSanitizerTests.swift` | 7A | New |
| `Core/Tests/CoreTests/TrackModelTests.swift` | 7A | New |
| `Core/Tests/CoreTests/AppConfigurationTests.swift` | 7A | New |
| `Core/Tests/CoreTests/TrackStatusTests.swift` | 7A | New |
| `Services/Tests/ServicesTests/GRDBModelsTests.swift` | 7A | New |
| `Services/Tests/ServicesTests/PersistenceModelTests.swift` | 7A | New |
| `Core/Tests/CoreTests/LoggingTests.swift` | 7A | New |
| `Core/Sources/Core/Infra/SignpostMarkers.swift` | 7B | New |
| `Core/Tests/CoreTests/PerformanceTests.swift` | 7B | New |
| `Services/Tests/ServicesTests/PerformanceTests.swift` | 7B | New |
| `.github/workflows/ci.yml` | 7B | Modified |
| 8 source files (signpost markers) | 7B | Modified |
| 5 JSON fixture files | 7C | Modified |
| `docs/tasks/parallel-run-runbook.md` | 7C | New |
| `docs/appstore/justification-nsuserapplescripttask.md` | 7D | New |
| `docs/appstore/privacy-policy.md` | 7D | New |
| `docs/appstore/store-listing.md` | 7D | New |
| `docs/appstore/launch-checklist.md` | 7D | New |
| `Services/Sources/Services/Workflow/CSVExporter.swift` | 7E | New |
| `Services/Sources/Services/Workflow/DryRunReport.swift` | 7E | New |
| `App/Views/GenreMappingsEditor.swift` | 7E | New |
| `App/Views/DryRunSummaryView.swift` | 7E | New |
| `Tests/IntegrationTests/MusicLibraryIntegrationTests.swift` | 7E | New |
| `Tests/IntegrationTests/AppleScriptIntegrationTests.swift` | 7E | New |
| `Tests/UITests/OnboardingFlowTests.swift` | 7E | New |
| `Tests/UITests/NavigationTests.swift` | 7E | New |
| `Tests/UITests/UpdateFlowTests.swift` | 7E | New |
| `scripts/validate-entitlements.sh` | 7E | New |
| `Services/Tests/ServicesTests/MusicLibraryReaderFilterTests.swift` | 7E | New |
| `Services/Tests/ServicesTests/CSVExporterTests.swift` | 7E | New |
| `Services/Tests/ServicesTests/DryRunReportTests.swift` | 7E | New |
| `Services/Tests/ServicesTests/APIClientURLTests.swift` | 7E | New |
| `Services/Tests/ServicesTests/UpdateCoordinatorErrorTests.swift` | 7E | New |
| `Services/Tests/ServicesTests/BatchProcessorErrorTests.swift` | 7E | New |
| `Core/Tests/CoreTests/ProtocolModelTests.swift` | 7E | New |
| `Core/Tests/CoreTests/GenreDeterminatorTests.swift` | 7E | Modified |
| `App/Views/MainView.swift` | 7E | Modified (+ navigateToUpdate) |
| `App/Views/ReportsView.swift` | 7E | Modified |
| `App/Views/SettingsView.swift` | 7E | Modified |
| `App/Views/UpdateView.swift` | 7E | Modified |
| `App/ViewModels/UpdateViewModel.swift` | 7E | Modified |
| `App/GenreUpdaterApp.swift` | 7E | Modified |
| `Core/Sources/Core/Config/AppConfiguration.swift` | 7E | Modified |
| `Core/Sources/Core/Genre/GenreDeterminator.swift` | 7E | Modified |
| `Services/Sources/Services/MusicLibraryReader.swift` | 7E | Modified |
| `SharedUI/Sources/SharedUI/ConfidenceBadge.swift` | 7E | Modified |
| `SharedUI/Sources/SharedUI/TierBadge.swift` | 7E | Modified |
| `SharedUI/Sources/SharedUI/EmptyStateView.swift` | 7E | Modified |
| `SharedUI/Sources/SharedUI/Reports/ReportsChangeLog.swift` | 7E | Modified |
| `.github/workflows/ci.yml` | 7E | Modified |
| `project.yml` | 7E | Modified |
| `docs/appstore/store-listing.md` | 7E | Modified |
| `docs/appstore/launch-checklist.md` | 7E | Modified |

---

## Deliverables

### Comprehensive Test Suite
> **TDD ref:** [[TDD#Verification Results]] (Phase 1 test baseline: 6 tests pass) | [[TDD#Lesson 1 SPM public Access Control]] (cross-package test visibility: все `public`)

- [x] Unit tests: coverage ≥ 85% для Core (94.31%), ≥ 65% для Services (69.36%)
- [x] Integration tests: MusicKit + AppleScript на реальній бібліотеці
- [ ] API integration tests з live endpoints (rate-limited)
- [ ] Cache read/write/expiry cycle tests
- [ ] Subscription flow в StoreKit sandbox
- [x] UI tests для critical user flows
- [ ] Edge case tests: empty library, huge library, no internet, expired subscription

### Parallel Run Testing
> **TDD ref:** [[TDD#Risks & Mitigation]] (scoring algorithm porting bugs 🟡 — "Test suite with Python test data; parallel run both implementations") | [[TDD#Decision 9 Year Scoring → Pure Struct]] (scoring logic має бути ідентичною Python-версії)

- [ ] Створити comparison tool: Python vs Swift на одній бібліотеці
- [ ] Run на reference dataset (200-500 tracks)
- [ ] Diff outputs для genre determination
- [ ] Diff outputs для year determination
- [ ] Flag discrepancies для investigation
- [ ] Goal: ≥ 95% agreement
- [ ] Document всі відмінності з обґрунтуванням

### Performance Profiling
> **TDD ref:** [[TDD#LOC Estimates]] (Swift LOC ratios per package — менше коду = менше overhead) | [[TDD#Risks & Mitigation]] (SwiftData performance 30K+ tracks 🟡 — "Batch inserts, background context, lazy fetch; profile with Instruments")

- [ ] Instruments profiling на 30K+ track library
- [ ] Memory allocation tracking для batch operations
- [x] os_signpost markers для critical paths
- [ ] Verify performance targets:
  - [ ] Library load (30K tracks) < 5 seconds
  - [ ] Single track write < 500ms
  - [ ] Search/filter < 50ms
  - [ ] Cache lookup < 10ms
  - [ ] Peak memory < 500MB
  - [ ] App launch < 3 seconds
- [ ] Regression tests для performance targets

### App Review Preparation
> **TDD ref:** [[TDD#Decision 6 subprocess → NSUserAppleScriptTask actor]] (чому саме цей підхід: Apple-sanctioned, runs outside sandbox) | [[TDD#Fallback Plan]] (якщо App Review відхилить → NSAppleScript + temporary-exception, ~2 weeks) | [[TDD#Risks & Mitigation]] (NSUserAppleScriptTask rejection 🔴 High)

- [x] Justification letter для NSUserAppleScriptTask
  - [x] Explain: Music.app has no write API
  - [x] Document: officially supported approach
  - [x] Reference: Apple documentation
- [ ] Video demo: onboarding → genre update flow
- [x] Entitlements explanation: sandbox + scripting-targets + network.client
- [x] Review notes: StoreKit sandbox test account
- [ ] Screenshots для App Store listing
- [x] App Store description та keywords

### Privacy & Legal
- [x] Privacy Policy URL (hosted page)
- [x] Content: "No data collected, no telemetry, no tracking"
- [ ] App Privacy labels в App Store Connect
- [ ] License information для third-party dependencies (GRDB)

### TestFlight Beta
- [x] Xcode Cloud CI/CD setup (decision: GH Actions for CI, Xcode Cloud for distribution)
- [x] Automated: build, unit tests, lint on every push (GitHub Actions)
- [ ] TestFlight distribution для beta testers
- [ ] Feedback collection workflow
- [ ] Bug triage та fix cycle
- [ ] Minimum 2 тижні beta testing

### App Store Submission
- [ ] App Store Connect listing complete
- [ ] Screenshots (all required sizes)
- [ ] App description (EN)
- [ ] Keywords optimization
- [ ] Price тiers configured (Free + Pro subscription)
- [ ] Submit для review
- [ ] Respond to review feedback (if any)

## CI/CD Pipeline

```
Push → GitHub Actions:
  ├── Build (Core, Services, SharedUI + xcodebuild)
  ├── Unit Tests (Core 418 + Services 316)
  ├── Coverage thresholds (Core ≥85%, Services ≥65%)
  ├── Entitlements validation
  ├── SwiftLint --strict
  ├── SwiftFormat --lint
  └── Periphery (dead code)

Tag (v*) → Xcode Cloud:
  ├── Archive
  └── TestFlight distribution
```

## Acceptance Criteria

- [ ] Всі тести проходять в CI (Xcode Cloud)
- [ ] Performance targets met на реальній бібліотеці
- [ ] Parallel run: ≥ 95% agreement з Python
- [ ] App Review approval
- [ ] Zero critical bugs в TestFlight beta
- [ ] Privacy Policy опублікована
- [ ] App Store listing complete

## Dependencies

- Всі попередні фази (1-6) completed
- Apple Developer Account (для TestFlight + App Store)
- Real Music.app library для integration testing
- Python version доступна для parallel run

## Timeline Estimates

- Testing + profiling: потребує найбільше часу — реальні бібліотеки, real APIs
- App Review: 1-7 днів (може бути rejection + resubmit cycle)
- TestFlight beta: мінімум 2 тижні

## Risks

- App Review rejection через NSUserAppleScriptTask — мати готову justification
- Performance issues на великих бібліотеках — профілювати рано
- API rate limiting в production — monitor та adjust
