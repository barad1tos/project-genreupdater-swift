---
phase: 6
title: "Views + Polish"
status: planned
priority: medium
depends_on:
  - "Phase 5 (workflows)"
---
> Parent: [[PRD]]

**Related:** [[phase-5-workflows|Phase 5: Workflows]] | [[phase-7-testing-launch|Phase 7: Testing + Launch]] | [[phase-2-core-models|Phase 2: Core Models]]
**Technical ref:** [[TDD#New Swift files (no Python counterpart)]] | [[TDD#Lesson 7 SwiftUI `.accent` ShapeStyle Does Not Exist]]

# Phase 6: Views + Polish

## Context

Побудова повноцінного SwiftUI інтерфейсу, accessibility, анімації та локалізація. Після цієї фази додаток повністю функціональний і готовий до тестування.

## Deliverables

### MainView (розширення)
> **TDD ref:** [[TDD#New Swift files (no Python counterpart)]] (6 нових Views — Python CLI → SwiftUI) | [[TDD#Decision 5 DI Container → Constructor Injection + @Environment]] (`@Environment` для inject Services в Views)

- [ ] Розширити існуючий `App/Views/MainView.swift`
- [ ] Split-view layout: sidebar + content area
- [ ] Sidebar секції: All Tracks, By Artist, By Album, Playlists, Recent Changes
- [ ] Track table з сортуванням та фільтрацією
- [ ] Toolbar: Update Genre, Update Year, Settings
- [ ] Search bar для швидкого пошуку
- [ ] Empty state для порожньої бібліотеки
- [ ] Loading state для початкового сканування

### UpdateView
> **TDD ref:** [[TDD#src/app/ → Sources/App/]] (Python CLI update flow → SwiftUI modal: configure → process → preview → apply)

- [ ] Створити `App/Views/UpdateView.swift`
- [ ] Modal sheet over MainView
- [ ] Three states: Configuring → Processing → Preview
- [ ] Configuring: вибір опцій (genre/year/both, confidence threshold)
- [ ] Processing: progress bar з ETA
- [ ] Preview: results table (Track | Current | Proposed | Confidence | Source)
- [ ] Accept all / Reject all / Toggle individual
- [ ] Apply button з confirmation

### BatchView (Week Pass / Pro)
> **TDD ref:** [[TDD#Feature Gating — StoreKit 2]] (3-tier gating: `currentTier >= .weekPass`) | [[TDD#src/app/features/ → Sources/App/Workflows/]] (batch processing UI)

- [ ] Створити `App/Views/BatchView.swift`
- [ ] Full-screen view replacing MainView during batch
- [ ] Progress ring з percentage
- [ ] Current track info display
- [ ] Running statistics (processed, succeeded, failed, skipped)
- [ ] Pause/Resume/Cancel controls
- [ ] ETA display
- [ ] 3-tier paywall for Free users: show Week Pass ($1.99/7 days) and Pro ($4.99/mo) options
- [ ] Cooldown indicator: якщо Week Pass на cooldown, показати тільки Pro option

### ReportsView (Reports Tab)
> **TDD ref:** [[TDD#src/metrics/ → Packages/SharedUI/Sources/SharedUI/]] (Python HTML reports → Swift Charts: `change_reports.py` → `ReportsChangeLog.swift` + `ReportsCharts.swift`)

**Free tier — Change Log** (visible to all users):
- [ ] Створити `App/Views/ReportsView.swift` — container view for Reports tab
- [ ] Інтегрувати `SharedUI/ReportsChangeLog.swift` — change log table component
- [ ] Change log table showing ChangeLogEntry records (track, type, old → new, timestamp)
- [ ] Filters: by change type (genre/year/cleaning), by date range, by artist/album
- [ ] Sort: by date (default), by artist, by change type
- [ ] Empty state: "No changes yet — update some tracks to see your history here"

**Week Pass / Pro — Charts + Aggregate Stats** (gated):
- [ ] Інтегрувати `SharedUI/ReportsCharts.swift` — charts/stats component
- [ ] Summary cards: total tracks processed, genres corrected, years updated
- [ ] Timeline chart of corrections over time (Swift Charts)
- [ ] Genre distribution before/after (bar chart)
- [ ] API usage statistics
- [ ] Performance metrics (avg time per track)
- [ ] Paywall overlay for Free users: show Week Pass ($1.99/7 days) and Pro ($4.99/mo) options

### SettingsView (розширення)
> **TDD ref:** [[TDD#Decision 5 DI Container → Constructor Injection + @Environment]] (AppStorage для простих settings, `@Observable` model для складних) | [[TDD#src/services/ → Packages/Services/Sources/Services/]] (`dependency_container.py` 563 LOC → `AppDependencies.swift` ~100 LOC)

- [ ] Розширити Settings window
- [ ] Tabs: General, API Keys, Scoring, Cleaning, Subscription, Advanced
- [ ] General: default behavior, notifications
- [ ] API Keys: Discogs token input (securely stored in Keychain)
- [ ] Scoring: confidence thresholds, definitive threshold
- [ ] Cleaning: remaster detection settings
- [ ] Subscription: current plan, manage subscription
- [ ] Advanced: cache management, logging level, reset

### Accessibility
- [ ] VoiceOver labels на всіх interactive elements
- [ ] Keyboard navigation для всіх primary flows
- [ ] Dynamic Type support для text elements
- [ ] Sufficient contrast ratios (WCAG AA)
- [ ] Rotor actions для table navigation
- [ ] Accessibility audit з Xcode Accessibility Inspector

### Animations та Polish
- [ ] Loading states для всіх async operations
- [ ] Transition animations між view states
- [ ] Error presentation (alert sheets з actionable messages)
- [ ] Haptic feedback (де доречно)
- [ ] Menu bar integration (optional quick actions)
- [ ] Drag & drop для track selection

### String Catalogs
- [ ] Переконатись що всі user-facing strings використовують String Catalogs
- [ ] English base language повністю покритий
- [ ] Placeholder strings для майбутніх локалізацій
- [ ] Export/import workflow для перекладачів

## Files (~12)

| File | Type | Description |
|------|------|-------------|
| `App/Views/MainView.swift` | Modify | Full split-view layout + Reports sidebar item |
| `App/Views/UpdateView.swift` | New | Update workflow modal |
| `App/Views/BatchView.swift` | New | Batch processing (Week Pass / Pro) |
| `App/Views/ReportsView.swift` | New | Reports tab container (change log + charts) |
| `SharedUI/Sources/SharedUI/ReportsChangeLog.swift` | New | Change log table component (Free tier) |
| `SharedUI/Sources/SharedUI/ReportsCharts.swift` | New | Charts + aggregate stats component (Week Pass / Pro) |
| `App/Views/SettingsView.swift` | New/Modify | Settings tabs |
| `App/Views/Components/*.swift` | New | Reusable components |
| `SharedUI/Sources/SharedUI/*.swift` | Modify | Shared components |
| `Resources/Localizable.xcstrings` | New | String Catalogs |

## Acceptance Criteria

- [ ] Всі views функціональні та з'єднані з реальними даними
- [ ] VoiceOver навігує всю аплікацію
- [ ] Keyboard navigation працює для всіх primary flows
- [ ] No unhandled errors reach UI (все caught та presented)
- [ ] Dynamic Type працює коректно
- [ ] Animations smooth (60fps)
- [ ] Gated features показують 3-tier paywall (Week Pass / Pro) для Free users
- [ ] Auto-sync показує Pro-only paywall (не Week Pass)
- [ ] Reports tab visible in sidebar for all tiers
- [ ] Free users see change log in Reports; charts/stats show paywall overlay
- [ ] `xcodebuild build` проходить без warnings

## Dependencies

- Phase 5 (всі workflows для підключення до views)
- Phase 2 (SubscriptionService, FeatureGate)

## Notes

- Accessibility — не optional, має бути вбудована з початку кожного view
- Charts framework вимагає macOS 14+ (ми таргетимо 15, OK)
- Settings architecture: рекомендується AppStorage для простих settings, @Observable model для складних
