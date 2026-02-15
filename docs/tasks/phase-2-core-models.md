---
phase: 2
title: "Core Models + Infrastructure + Subscription Foundation"
status: done
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
| `genreupdater.pro.monthly` | Auto-renewable subscription | $4.99/mo |
| `genreupdater.pro.yearly` | Auto-renewable subscription | $29.99/yr |
| `genreupdater.weekpass` | Non-renewing subscription | $1.99 |

- [x] Створити `Packages/Services/Sources/Services/Subscription/SubscriptionService.swift`
- [x] Реалізувати `@Observable` клас на `@MainActor`
- [x] `Tier` enum: `enum Tier: Comparable { case free, weekPass, pro }` (Core/Models/Tier.swift)
- [x] `currentTier` computed property що враховує Pro subscription + Week Pass expiry
- [x] Інтеграція з StoreKit 2 (Product, Transaction, renewalState)
- [x] Pro purchase flow: purchase, restore, check entitlement (auto-renewable)
- [x] **Week Pass purchase flow**: Non-Renewing Subscription purchase + expiry tracking
- [x] **Week Pass expiry**: `Transaction.purchaseDate + 7 days` (StoreKit 2 `SubscriptionInfo` недоступний для non-renewing)
- [x] **Week Pass cooldown**: 14-day gap після завершення Week Pass перед наступною покупкою
- [x] `weekPassCooldownRemaining` — реалізовано як `isCooldownOver()` + `weekPassCooldownEndDate()`
- [x] **Week Pass persistence**: iCloud KVS (`weekPassPurchaseCount`)
- [x] Offline entitlement: `SubscriptionDuration.offlineCacheDays = 7`
- [x] Grace period: 16 днів після закінчення Pro підписки (Week Pass без grace period — фіксовані 7 днів)
- [x] **Progressive upsell tracking**: лічильник покупок Week Pass в iCloud KVS
- [x] Unit tests для всіх станів: Pro active/expired/grace, Week Pass active/expired/cooldown (19 тестів)

### FeatureGate (3-Tier: Free / Week Pass / Pro)
> **TDD ref:** [[TDD#Feature Gating — StoreKit 2]] (`SubscriptionManager` + `currentTier` pattern) | 3-tier model: Free = 500 lifetime, Week Pass = unlimited (7 days), Pro = unlimited + auto-sync ([[PRD#Monetization]])

- [x] Створити `Packages/Services/Sources/Services/Subscription/FeatureGate.swift`
- [x] `@MainActor` клас з `canAccess(_:)`, `canProcessTracks(count:)`, `require(_:) throws`
- [x] `AppFeature` enum (Core/Models/AppFeature.swift): 13 features з `minimumTier` property
- [x] `minimumTier` mapping: Free(7), WeekPass(5), Pro(1) — per PRD Section 7
- [x] `canAccess(_ feature:)` → `currentTier >= feature.minimumTier`
- [x] Cooldown перевірка реалізована в `SubscriptionService.isCooldownOver()`
- [x] **Free tier counter**: `NSUbiquitousKeyValueStore` (iCloud key-value storage) — прив'язаний до iCloud account
- [ ] Fallback для counter: UserDefaults якщо iCloud недоступний, sync при відновленні зв'язку
- [ ] **Progressive upsell nudge logic**: після 2+ Week Pass покупок показувати порівняння цін (UI — Phase 6)
- [x] Unit tests: Free limits, Week Pass access, Pro access, track capacity (18 тестів FeatureGate + 9 Core)

### GRDB Setup
> **TDD ref:** [[TDD#Decision 8 3-Tier Cache → SwiftData + GRDB + NSCache]] (чому GRDB для API cache: raw speed, 10 Python files 2,993 LOC → 3 Swift files ~800 LOC) | [[TDD#Caching — SwiftData + GRDB]] (code pattern: `@Model CachedAPIResult` з TTL)

- [x] Додати GRDB dependency в `Packages/Services/Package.swift` *(done in Phase 2A)*
- [x] Створити `CachedAPIResult` GRDB Row type *(done in Phase 2A — GRDBModels.swift)*
- [x] Composite index на (artist, album, source) *(done in Phase 2A)*
- [x] Реалізувати `GRDBCacheService` що відповідає `CacheService` протоколу *(done in Phase 2A)*
- [x] Міграційна схема (VersionedSchema) для майбутніх змін *(done in Phase 2A — GRDBMigrations.swift)*
- [x] Unit tests: CRUD, TTL expiry, index performance *(done in Phase 2A — 15 tests)*

### PersistedTrack (SwiftData @Model)
> **TDD ref:** [[TDD#Decision 1 Pydantic → Three-Layer Types]] (чому 3 шари: domain `Track` struct + `PersistedTrack` @Model + Codable DTO — prevents persistence leaking into business logic) | [[TDD#src/core/models/ → Packages/Core/Sources/Core/Models/]] (`track_models.py` 713 LOC → split)

- [x] Створити `PersistedTrack` @Model клас *(done in Phase 2A)*
- [x] Mapping функції: `Track` ↔ `PersistedTrack` *(done in Phase 2A)*
- [x] Indexed fields: id, artist, album, genre *(done in Phase 2A)*
- [ ] Relationships з ChangeLogEntry *(deferred — ChangeLogEntry not yet defined)*
- [x] Unit tests: mapping correctness, persistence cycle *(done in Phase 2A — 9 tests)*

### MusicKit-AppleScript ID Mapping
> **TDD ref:** [[TDD#Music.app Integration]] (MusicKit reads + AppleScript writes = потрібен маппінг між двома ID systems) | [[TDD#Lesson 5 MusicItemID Init is NOT Failable]] | [[TDD#Decision 6 subprocess → NSUserAppleScriptTask actor]] (scripts run outside sandbox)

- [ ] Створити маппінг-сервіс для кореляції MusicKit IDs ↔ AppleScript IDs
- [ ] Стратегія: match по (name + artist + album) з fuzzy fallback
- [ ] Кеш маппінгів для повторних операцій
- [ ] Unit tests: exact match, fuzzy match, collision handling

### ProgressUpdate Stream
> **TDD ref:** [[TDD#Decision 3 asyncio.gather → async let / TaskGroup]] (`AsyncStream` pattern для progress reporting від `TaskGroup` до UI)

- [x] Створити `AsyncStream<ProgressUpdate>` based infrastructure *(done in Phase 2A — ProgressUpdate.swift)*
- [x] `ProgressUpdate` struct: phase, current, total, message, estimatedTimeRemaining *(done in Phase 2A)*
- [ ] Інтеграція з Services для reporting progress до UI *(deferred — Phase 5 workflows)*
- [x] Unit tests: stream emission, cancellation *(done in Phase 2A — 8 tests)*

### String Catalogs
- [ ] Налаштувати String Catalogs для локалізації
- [ ] English як base language
- [ ] Підготувати всі user-facing strings для Phase 2

## Files (~17+)

| File | Type | Description |
|------|------|-------------|
| `Core/Models/Tier.swift` | New ✅ | Tier enum (free, weekPass, pro) — Comparable, Sendable |
| `Core/Models/AppFeature.swift` | New ✅ | 13 features з minimumTier property |
| `CoreTests/TierTests.swift` | New ✅ | 4 tests: ordering, equality, cases |
| `CoreTests/AppFeatureTests.swift` | New ✅ | 5 tests: feature distribution per PRD |
| `Services/Subscription/SubscriptionService.swift` | New ✅ | StoreKit 2 integration (~260 LOC) |
| `Services/Subscription/FeatureGate.swift` | New ✅ | @MainActor feature gating (~100 LOC) |
| `ServicesTests/SubscriptionServiceTests.swift` | New ✅ | 19 tests: expiry, cooldown, grace |
| `ServicesTests/FeatureGateTests.swift` | New ✅ | 18 tests: access, require, limits |
| `Resources/GenreUpdater.storekit` | New ✅ | StoreKit config (3 products) |
| `App/GenreUpdater.entitlements` | Modify ✅ | + iCloud KVS entitlement |
| `App/AppDependencies.swift` | Modify ✅ | + SubscriptionService, FeatureGate DI |
| `project.yml` | Modify ✅ | Remove entitlements block (xcodegen fix) |
| `Services/Package.swift` | Modify ✅ | Add GRDB dependency (Phase 2A) |
| `Services/Persistence/GRDB/GRDBCacheService.swift` | New ✅ | GRDB cache implementation (Phase 2A) |
| `Services/Persistence/GRDB/GRDBModels.swift` | New ✅ | GRDB Row types (Phase 2A) |
| `Services/Persistence/GRDB/GRDBMigrations.swift` | New ✅ | DB migrations (Phase 2A) |
| `Services/Persistence/SwiftData/PersistedTrack.swift` | New ✅ | SwiftData @Model (Phase 2A) |
| `Services/Persistence/SwiftData/SwiftDataTrackStore.swift` | New ✅ | TrackStateStore impl (Phase 2A) |
| `Services/MusicLibraryReader.swift` | Modify | Add ID mapping (Phase 4-5) |
| `Core/Models/ProgressUpdate.swift` | New ✅ | Progress reporting (Phase 2A) |

## Acceptance Criteria

- [x] Всі domain types компілюються і мають unit tests (Tier, AppFeature, FeatureGate)
- [x] SubscriptionService працює в StoreKit sandbox (стorekit config created)
- [x] FeatureGate правильно гейтить features по тірах (18 тестів)
- [x] GRDB database створюється і мігрує *(done in Phase 2A — 15 tests pass)*
- [x] `swift build` + `swift test` проходять для Core (27) + Services (68)
- [x] `xcodebuild build` проходить без помилок (BUILD SUCCEEDED)

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
