---
phase: 6
title: "Views + Polish"
status: done
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

- [x] Розширити існуючий `App/Views/MainView.swift`
- [x] Split-view layout: sidebar + content area
- [x] Sidebar секції: Library, Genre Update, Year Update, Batch, Reports
- [x] Track table з сортуванням та фільтрацією
- [x] Toolbar: Update Tracks (wand.and.stars), Refresh (arrow.clockwise)
- [x] Search bar для швидкого пошуку
- [x] Empty state для порожньої бібліотеки (ContentUnavailableView)
- [x] Loading state для початкового сканування
- [x] Content routing: Library→trackList, Batch→BatchView, Reports→ReportsView

### UpdateView
> **TDD ref:** [[TDD#src/app/ → Sources/App/]] (Python CLI update flow → SwiftUI modal: configure → process → preview → apply)

- [x] Створити `App/Views/UpdateView.swift`
- [x] Modal sheet over MainView
- [x] Five states: Configuring → Processing → Preview → Applying → Done
- [x] Configuring: вибір опцій (genre/year/both, confidence threshold slider)
- [x] Processing: ProgressRing з message
- [x] Preview: results table (Track | Change Type | Old→New | Confidence Badge | Toggle)
- [x] Accept all / Reject all / Toggle individual
- [x] Apply button з accepted count
- [x] Створити `App/ViewModels/UpdateViewModel.swift` — @Observable @MainActor ViewModel

### BatchView (Week Pass / Pro)
> **TDD ref:** [[TDD#Feature Gating — StoreKit 2]] (3-tier gating: `currentTier >= .weekPass`) | [[TDD#src/app/features/ → Sources/App/Workflows/]] (batch processing UI)

- [x] Створити `App/Views/BatchView.swift`
- [x] FeatureGatedView wrapper for .batchProcessing
- [x] Progress ring з percentage (ProgressRing from SharedUI)
- [x] Current track info display
- [x] Running statistics (processed, changes applied, failed)
- [x] Pause/Resume/Cancel controls
- [x] State machine: idle → running → paused → completed → cancelled → error
- [x] Paywall overlay for Free users via FeatureGatedView
- [x] Створити `App/ViewModels/BatchViewModel.swift` — @Observable @MainActor ViewModel

### ReportsView (Reports Tab)
> **TDD ref:** [[TDD#src/metrics/ → Packages/SharedUI/Sources/SharedUI/]] (Python HTML reports → Swift Charts)

**Free tier — Change Log** (visible to all users):
- [x] Створити `App/Views/ReportsView.swift` — container view with @Query
- [x] Створити `SharedUI/Reports/ReportsChangeLog.swift` — change log table component
- [x] Table with columns: Date, Track, Artist, Change Type, Old→New
- [x] Filters: by change type picker, search by artist/track name
- [x] Sort: by date (default), sortable columns
- [x] Empty state via EmptyStateView

**Week Pass / Pro — Charts + Aggregate Stats** (gated):
- [x] Створити `SharedUI/Charts/ReportsCharts.swift` — charts/stats component
- [x] Summary cards: total tracks processed, genres corrected, years updated
- [x] Genre distribution bar chart (Swift Charts, horizontal BarMark)
- [x] Changes over time line chart (LineMark + AreaMark)
- [x] FeatureGatedView wrapping charts for Free users

### SettingsView
> **TDD ref:** [[TDD#Decision 5 DI Container → Constructor Injection + @Environment]]

- [x] Створити `App/Views/SettingsView.swift` (замінює SettingsPlaceholderView)
- [x] Tabs: General, API Keys, Scoring, Cleaning, Subscription, Advanced
- [x] General: default behavior picker (@AppStorage), notifications toggle
- [x] API Keys: Discogs token SecureField + Save/Delete/Test via KeychainHelper
- [x] Scoring: confidence thresholds, definitive threshold, year diff penalty
- [x] Cleaning: remaster keywords + album suffixes editable lists
- [x] Subscription: embedded SubscriptionView component
- [x] Advanced: cache statistics, clear cache, debug mode, reset config

### SubscriptionView
- [x] Створити `App/Views/SubscriptionView.swift`
- [x] Current tier TierBadge + usage stats
- [x] Product list with displayPrice and purchase buttons
- [x] Week Pass cooldown indicator
- [x] Restore Purchases button
- [x] Feature comparison grid

### SharedUI Components
- [x] Створити `SharedUI/ConfidenceBadge.swift` — color-coded confidence badge
- [x] Створити `SharedUI/ProgressRing.swift` — circular progress indicator
- [x] Створити `SharedUI/EmptyStateView.swift` — configurable empty state
- [x] Створити `SharedUI/TierBadge.swift` — subscription tier badge
- [x] Створити `SharedUI/PaywallOverlay.swift` — feature-gated paywall overlay
- [x] Екстрагувати `SharedUI/TrackRow.swift` з MainView
- [x] Екстрагувати `SharedUI/TrackDetailView.swift` з MainView

### App Infrastructure
- [x] Розширити `App/AppDependencies.swift` — wire Phase 5 services (13 new properties)
- [x] Оновити `App/GenreUpdaterApp.swift` — ModelContainer, Settings, keyboard shortcuts
- [x] Створити `App/Views/Components/FeatureGatedView.swift` — generic feature gate wrapper

### Accessibility
- [x] VoiceOver labels на interactive elements
- [x] Keyboard navigation: Cmd+U (Update), Cmd+R (Refresh)
- [x] .accessibilityLabel, .accessibilityValue, .accessibilityHint на controls
- [x] .accessibilityHidden(true) на decorative icons
- [x] .accessibilityElement(children: .combine) на TrackRow

### Animations та Polish
- [x] Loading states для async operations (ProgressView)
- [x] Error presentation (alert sheets)
- [x] Menu bar integration: Library menu (Refresh), Update menu (Update Selected)

## Files

| File | Type | LOC | Description |
|------|------|-----|-------------|
| `App/AppDependencies.swift` | Modify | +115 | Wire Phase 5 services, ModelContainer |
| `App/GenreUpdaterApp.swift` | Modify | +20 | ModelContainer, SettingsView, keyboard shortcuts |
| `App/Views/MainView.swift` | Modify | +40 | Content routing, update sheet, accessibility |
| `App/Views/UpdateView.swift` | New | ~328 | Update workflow modal sheet |
| `App/Views/BatchView.swift` | New | ~302 | Batch processing (feature-gated) |
| `App/Views/ReportsView.swift` | New | ~90 | Reports container with @Query |
| `App/Views/SettingsView.swift` | New | ~471 | 6-tab settings |
| `App/Views/SubscriptionView.swift` | New | ~241 | Subscription management |
| `App/Views/Components/FeatureGatedView.swift` | New | ~55 | Generic feature gate wrapper |
| `App/ViewModels/UpdateViewModel.swift` | New | ~219 | Update workflow ViewModel |
| `App/ViewModels/BatchViewModel.swift` | New | ~197 | Batch processing ViewModel |
| `SharedUI/ConfidenceBadge.swift` | New | ~65 | Color-coded confidence badge |
| `SharedUI/ProgressRing.swift` | New | ~111 | Circular progress indicator |
| `SharedUI/EmptyStateView.swift` | New | ~76 | Configurable empty state |
| `SharedUI/TierBadge.swift` | New | ~71 | Subscription tier badge |
| `SharedUI/PaywallOverlay.swift` | New | ~263 | Paywall overlay |
| `SharedUI/TrackRow.swift` | New | ~39 | Track row (extracted from MainView) |
| `SharedUI/TrackDetailView.swift` | New | ~47 | Track detail (extracted from MainView) |
| `SharedUI/Reports/ReportsChangeLog.swift` | New | ~219 | Change log table |
| `SharedUI/Charts/ReportsCharts.swift` | New | ~232 | Charts + summary cards |
| `SharedUI/Theme/AyuColors.swift` | Modified | ~183 | Ayu color palette tokens (fgSecondary light fixed: 0x8A9199 -> 0x697078 for WCAG AA) |
| `SharedUI/Theme/DesignTokens.swift` | New | ~95 | Spacing, typography, glass helpers |
| `App/Views/Components/GaugeView.swift` | New | ~211 | Multi-ring library health gauge |
| `App/Views/Components/MetricCard.swift` | New | ~146 | Dashboard metric card |
| `App/Views/Components/QuickActionButton.swift` | New | ~92 | Horizontal action button with hover |
| `App/Views/Components/AlbumCard.swift` | New | — | Album card component |
| `App/Views/Components/ArtistRow.swift` | New | — | Artist row component |
| `App/Views/DashboardView.swift` | New | ~231 | Library health dashboard |
| `App/Views/BrowseView.swift` | New | — | Browse/search library view |
| `App/Views/UpdateWorkflowView.swift` | New | — | Unified update workflow |
| `App/ViewModels/DashboardViewModel.swift` | New | ~112 | Dashboard metrics computation |
| `App/ViewModels/WorkflowViewModel.swift` | New | — | Update workflow ViewModel |

## Acceptance Criteria

- [x] Всі views функціональні та з'єднані з реальними даними
- [x] VoiceOver labels на всіх interactive elements
- [x] Keyboard navigation працює (Cmd+U, Cmd+R)
- [x] No unhandled errors reach UI (alert sheets for errors)
- [x] Gated features показують paywall для Free users
- [x] Auto-sync показує Pro-only paywall (не Week Pass)
- [x] Reports tab visible for all tiers
- [x] Free users see change log; charts show paywall overlay
- [x] `xcodebuild build` проходить без errors
- [x] SwiftLint --strict: 0 violations
- [x] SwiftFormat --lint: 0 files require formatting
- [x] Core tests: 322 passed
- [x] Services tests: 174 passed

## Dependencies

- Phase 5 (всі workflows для підключення до views)
- Phase 2 (SubscriptionService, FeatureGate)
