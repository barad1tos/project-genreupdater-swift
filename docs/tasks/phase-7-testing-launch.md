---
phase: 7
title: "Testing + Launch"
status: planned
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

## Deliverables

### Comprehensive Test Suite
> **TDD ref:** [[TDD#Verification Results]] (Phase 1 test baseline: 6 tests pass) | [[TDD#Lesson 1 SPM public Access Control]] (cross-package test visibility: все `public`)

- [ ] Unit tests: coverage ≥ 80% для Core, ≥ 70% для Services
- [ ] Integration tests: MusicKit + AppleScript на реальній бібліотеці
- [ ] API integration tests з live endpoints (rate-limited)
- [ ] Cache read/write/expiry cycle tests
- [ ] Subscription flow в StoreKit sandbox
- [ ] UI tests для critical user flows
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
- [ ] os_signpost markers для critical paths
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

- [ ] Justification letter для NSUserAppleScriptTask
  - [ ] Explain: Music.app has no write API
  - [ ] Document: officially supported approach
  - [ ] Reference: Apple documentation
- [ ] Video demo: onboarding → genre update flow
- [ ] Entitlements explanation: sandbox + scripting-targets + network.client
- [ ] Review notes: StoreKit sandbox test account
- [ ] Screenshots для App Store listing
- [ ] App Store description та keywords

### Privacy & Legal
- [ ] Privacy Policy URL (hosted page)
- [ ] Content: "No data collected, no telemetry, no tracking"
- [ ] App Privacy labels в App Store Connect
- [ ] License information для third-party dependencies (GRDB)

### TestFlight Beta
- [ ] Xcode Cloud CI/CD setup
- [ ] Automated: build, unit tests, lint on every push
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
Push → Xcode Cloud:
  ├── Build (all targets)
  ├── Unit Tests (Core + Services)
  ├── Lint (SwiftLint if configured)
  └── Archive (for TestFlight)
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
