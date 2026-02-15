---
phase: 2
title: "Core Models + Infrastructure + Subscription Foundation"
status: planned
priority: high
depends_on:
  - "Phase 1 ✅"
  - "Phase 1.5 ✅"
---
> Parent: [[PRD]]

**Related:** [[phase-3-core-algorithms|Phase 3: Core Algorithms]] | [[phase-4-api-cache|Phase 4: API + Cache]] | [[phase-5-workflows|Phase 5: Workflows]] | [[phase-6-views-polish|Phase 6: Views]]
**Technical ref:** [[TDD#Pattern Translation Decisions]] | [[TDD#Lessons Learned (CRITICAL for future phases)]]

# Phase 2: Core Models + Infrastructure + Subscription Foundation

## Context

Фаза побудови інфраструктури для підтримки підписок, персистенції та маппінгу між MusicKit і AppleScript ідентифікаторами. Після цієї фази додаток зможе зберігати дані, гейтити Pro-фічі та показувати прогрес довгих операцій.

## Deliverables

### SubscriptionService (StoreKit 2) — 3-Tier Model
> **TDD ref:** [[TDD#Feature Gating — StoreKit 2]] (code pattern: `@Observable SubscriptionManager`) | [[TDD#Decision 5 DI Container → Constructor Injection + @Environment]] (inject via `@Environment`)

**StoreKit Products:**
| Product ID | Type | Price |
|-----------|------|-------|
| `pro_monthly` | Auto-renewable subscription | $4.99/mo |
| `pro_annual` | Auto-renewable subscription | $29.99/yr |
| `week_pass` | Non-renewing subscription | $1.99 |

- [ ] Створити `Packages/Services/Sources/Services/Subscription/SubscriptionService.swift`
- [ ] Реалізувати `@Observable` клас на `@MainActor`
- [ ] `Tier` enum: `enum Tier: Comparable { case free, weekPass, pro }`
- [ ] `currentTier` computed property що враховує Pro subscription + Week Pass expiry
- [ ] Інтеграція з StoreKit 2 (Product, Transaction, renewalState)
- [ ] Pro purchase flow: purchase, restore, check entitlement (auto-renewable)
- [ ] **Week Pass purchase flow**: Non-Renewing Subscription purchase + expiry tracking
- [ ] **Week Pass expiry**: `Transaction.purchaseDate + 7 days` (StoreKit 2 `SubscriptionInfo` недоступний для non-renewing)
- [ ] **Week Pass cooldown**: 14-day gap після завершення Week Pass перед наступною покупкою
- [ ] `weekPassCooldownRemaining` computed property → `TimeInterval?` (nil = можна купити)
- [ ] **Week Pass persistence**: зберігати purchaseDate в Keychain для offline access
- [ ] Offline entitlement: кешування статусу в UserDefaults (TTL 7 днів)
- [ ] Grace period: 16 днів після закінчення Pro підписки (Week Pass без grace period — фіксовані 7 днів)
- [ ] **Progressive upsell tracking**: лічильник покупок Week Pass (для nudge після 2+)
- [ ] Unit tests для всіх станів: Pro active/expired/grace, Week Pass active/expired/cooldown, offline

### FeatureGate (3-Tier: Free / Week Pass / Pro)
> **TDD ref:** [[TDD#Feature Gating — StoreKit 2]] (`SubscriptionManager` + `currentTier` pattern) | 3-tier model: Free = 500 lifetime, Week Pass = unlimited (7 days), Pro = unlimited + auto-sync ([[PRD#Monetization]])

- [ ] Створити `Packages/Services/Sources/Services/Subscription/FeatureGate.swift`
- [ ] `@Observable` клас з `canAccess(_:)`, `canProcess(trackCount:)`, `minimumTier(for:)`
- [ ] `AppFeature` enum: genreUpdate, yearUpdate, preview, undo, libraryBrowsing, batchProcessing, autoSync, reportsCharts, csvExport, artistCleaning, albumCleaning, advancedCache
- [ ] `minimumTier(for:)` mapping: Free features (.free), Week Pass features (.weekPass), Auto-sync (.pro)
- [ ] `canAccess(_ feature:)` → `currentTier >= minimumTier(for: feature)`
- [ ] `canPurchaseWeekPass` → перевірка cooldown period (14 днів)
- [ ] **Free tier counter**: `NSUbiquitousKeyValueStore` (iCloud key-value storage) — прив'язаний до iCloud account
- [ ] Fallback для counter: UserDefaults якщо iCloud недоступний, sync при відновленні зв'язку
- [ ] **Progressive upsell nudge logic**: після 2+ Week Pass покупок показувати порівняння цін
- [ ] Unit tests: Free limits, Week Pass access, Pro access, cooldown blocking, iCloud counter, progressive nudge thresholds

### GRDB Setup
> **TDD ref:** [[TDD#Decision 8 3-Tier Cache → SwiftData + GRDB + NSCache]] (чому GRDB для API cache: raw speed, 10 Python files 2,993 LOC → 3 Swift files ~800 LOC) | [[TDD#Caching — SwiftData + GRDB]] (code pattern: `@Model CachedAPIResult` з TTL)

- [ ] Додати GRDB dependency в `Packages/Services/Package.swift`
- [ ] Створити `CachedAPIResult` GRDB Row type
- [ ] Composite index на (artist, album, source)
- [ ] Реалізувати `GRDBCacheService` що відповідає `CacheService` протоколу
- [ ] Міграційна схема (VersionedSchema) для майбутніх змін
- [ ] Unit tests: CRUD, TTL expiry, index performance

### PersistedTrack (SwiftData @Model)
> **TDD ref:** [[TDD#Decision 1 Pydantic → Three-Layer Types]] (чому 3 шари: domain `Track` struct + `PersistedTrack` @Model + Codable DTO — prevents persistence leaking into business logic) | [[TDD#src/core/models/ → Packages/Core/Sources/Core/Models/]] (`track_models.py` 713 LOC → split)

- [ ] Створити `PersistedTrack` @Model клас
- [ ] Mapping функції: `Track` ↔ `PersistedTrack`
- [ ] Indexed fields: id, artist, album, genre
- [ ] Relationships з ChangeLogEntry
- [ ] Unit tests: mapping correctness, persistence cycle

### MusicKit-AppleScript ID Mapping
> **TDD ref:** [[TDD#Music.app Integration]] (MusicKit reads + AppleScript writes = потрібен маппінг між двома ID systems) | [[TDD#Lesson 5 MusicItemID Init is NOT Failable]] | [[TDD#Decision 6 subprocess → NSUserAppleScriptTask actor]] (scripts run outside sandbox)

- [ ] Створити маппінг-сервіс для кореляції MusicKit IDs ↔ AppleScript IDs
- [ ] Стратегія: match по (name + artist + album) з fuzzy fallback
- [ ] Кеш маппінгів для повторних операцій
- [ ] Unit tests: exact match, fuzzy match, collision handling

### ProgressUpdate Stream
> **TDD ref:** [[TDD#Decision 3 asyncio.gather → async let / TaskGroup]] (`AsyncStream` pattern для progress reporting від `TaskGroup` до UI)

- [ ] Створити `AsyncStream<ProgressUpdate>` based infrastructure
- [ ] `ProgressUpdate` struct: phase, current, total, message, estimatedTimeRemaining
- [ ] Інтеграція з Services для reporting progress до UI
- [ ] Unit tests: stream emission, cancellation

### String Catalogs
- [ ] Налаштувати String Catalogs для локалізації
- [ ] English як base language
- [ ] Підготувати всі user-facing strings для Phase 2

## Files (~17)

| File | Type | Description |
|------|------|-------------|
| `Services/Subscription/SubscriptionService.swift` | New | StoreKit 2 integration (3-tier: Free/Week Pass/Pro) |
| `Services/Subscription/FeatureGate.swift` | New | 3-tier feature gating + iCloud counter + cooldown |
| `Services/Package.swift` | Modify | Add GRDB dependency |
| `Services/Cache/GRDBCacheService.swift` | New | GRDB cache implementation |
| `Services/Cache/CachedAPIResult.swift` | New | GRDB Row type |
| `Services/Cache/VersionedSchema.swift` | New | DB migrations |
| `Services/Persistence/PersistedTrack.swift` | New | SwiftData @Model |
| `Services/MusicLibraryReader.swift` | Modify | Add ID mapping |
| `Core/Models/ProgressUpdate.swift` | New | Progress reporting |
| `Core/Models/AppFeature.swift` | New | Feature enum (replaces ProFeature) |
| `Core/Models/Tier.swift` | New | Tier enum (free, weekPass, pro) |
| `ServicesTests/SubscriptionTests.swift` | New | Subscription tests |
| `ServicesTests/FeatureGateTests.swift` | New | FeatureGate tests |
| `ServicesTests/GRDBCacheTests.swift` | New | Cache tests |
| `CoreTests/ProgressUpdateTests.swift` | New | Progress tests |

## Acceptance Criteria

- [ ] Всі domain types компілюються і мають unit tests
- [ ] SubscriptionService працює в StoreKit sandbox
- [ ] FeatureGate правильно гейтить Pro features
- [ ] GRDB database створюється і мігрує
- [ ] `swift build` + `swift test` проходять для всіх пакетів
- [ ] `xcodebuild build` проходить без помилок

## Dependencies

- Phase 1 ✅ (SPM structure, protocols, models)
- Phase 1.5 ✅ (entitlements, sanitizer fixes)

## Notes

- GRDB потребує SPM dependency — перевірити сумісність версій
- StoreKit sandbox потребує Apple Developer account
- PersistedTrack та CachedAPIResult — різні persistence engines (SwiftData vs GRDB)
- Week Pass = Non-Renewing Subscription (не consumable/non-consumable). Apple трекає per Apple ID через `Transaction.currentEntitlements`
- `NSUbiquitousKeyValueStore` для Free tier counter — потребує iCloud entitlement (вже є через sandbox)
- Week Pass cooldown (14 днів) реалізується app-side, не через StoreKit
- Server-side receipt validation для Week Pass abuse detection відкладено до Phase 7
