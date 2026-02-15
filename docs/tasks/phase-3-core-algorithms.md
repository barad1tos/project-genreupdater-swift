---
phase: 3
title: "Core Algorithms"
status: active
priority: critical
depends_on:
  - "Phase 2"
---
> Parent: [[PRD]]

**Related:** [[phase-2-core-models|Phase 2: Core Models]] | [[phase-4-api-cache|Phase 4: API + Cache]] | [[phase-5-workflows|Phase 5: Workflows]]
**Technical ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] | [[TDD#Decision 9 Year Scoring → Pure Struct]]

# Phase 3: Core Algorithms — Hardest Phase

## Context

Ядро бізнес-логіки: алгоритми визначення жанру та року. Портуються з battle-tested Python-реалізації (32.7K LOC). Розбито на дві sub-phases: 3A (foundation utils + matchers) та 3B (genre/year algorithms).

## Sub-phases

### Phase 3A: Foundation (Utils + Matchers)

**Components:** Normalization, ScriptDetector, MetadataUtils, AlbumType, AlbumMatcher, ArtistMatcher
**Estimated:** ~2,200 LOC impl + ~900 LOC tests

### Phase 3B: Core Algorithms (Genre + Year + Scoring)

**Components:** GenreDeterminator, YearScorer, YearValidator, YearFallbackStrategy, YearDeterminator
**Estimated:** ~3,500 LOC impl + ~1,500 LOC tests

## Phase 3A Deliverables

### Normalization
> Port from: `normalization.py` 51 LOC

- [x] Create `Packages/Core/Sources/Core/Utils/Normalization.swift`
- [x] `normalizeForMatching(_:)` — standard pipeline (strip, lowercase)
- [x] `areNamesEqual(_:_:)` — convenience comparison
- [x] Unit tests with edge cases, diacritics, CJK, empty strings

### ScriptDetector
> Port from: `script_detection.py` 519 LOC

- [x] Create `Packages/Core/Sources/Core/Utils/ScriptDetector.swift`
- [x] `ScriptType` enum (latin, cjk, cyrillic, arabic, etc.)
- [x] Unicode range checks: `hasLatin(_:)`, `hasCJK(_:)`, `hasCyrillic(_:)`, etc.
- [x] `dominantScript(of:)` — primary script detection
- [x] `getAllScripts(_:)` — all detected scripts
- [x] CJK disambiguation (Japanese vs Chinese via hiragana/katakana)
- [x] Unit tests with multi-script, mixed strings

### MetadataUtils
> Port from: `metadata_utils.py` 803 LOC (cleaning functions only)

- [x] Create `Packages/Core/Sources/Core/Utils/MetadataUtils.swift`
- [x] Remaster detection and tag removal
- [x] Album name cleaning: "(Remastered)", "[Deluxe]", etc.
- [x] Edition/version normalization
- [x] Balanced parentheses/brackets removal with keyword matching
- [x] Uses `CleaningConfig` from `AppConfiguration`
- [x] Unit tests with remaster patterns, cleaning edge cases

### AlbumType
> Port from: `album_type.py` 405 LOC

- [x] Create `Packages/Core/Sources/Core/Models/AlbumType.swift`
- [x] `AlbumType` enum: normal, special, compilation, reissue
- [x] `YearHandlingStrategy` enum: normal, markAndSkip, markAndUpdate
- [x] `AlbumTypeInfo` struct with detected pattern + strategy
- [x] Pattern-based classification (special, compilation, reissue keywords)
- [x] `detectAlbumType(_:)` — main classification function
- [x] Unit tests with classification edge cases

### AlbumMatcher
> Port from: album matching logic in `metadata_utils.py`

- [x] Create `Packages/Core/Sources/Core/Matching/AlbumMatcher.swift`
- [x] Levenshtein distance implementation (~30 LOC)
- [x] Fuzzy album matching with configurable threshold
- [x] Remaster/deluxe/edition variant detection
- [x] Disc number handling (Disc 1, CD2)
- [x] Unit tests with fuzzy matching, variants, disc numbers

### ArtistMatcher
> Port from: `artist_renamer.py` 194 LOC + `year_utils.py` `normalize_collaboration_artist`

- [x] Create `Packages/Core/Sources/Core/Matching/ArtistMatcher.swift`
- [x] "The Beatles" → "Beatles" article normalization
- [x] Featured artist extraction: feat., ft., with, &
- [x] CJK-aware matching via ScriptDetector
- [x] Collaboration split: "A & B" → ["A", "B"]
- [x] `extractMainArtist(_:)` — extract main from collaboration
- [x] Unit tests with normalization, features, collabs, CJK

## Phase 3B Deliverables

### GenreUpdateConfig Extension

- [ ] Extend `GenreUpdateConfig` with `minimumConfidence`, `overrideExisting`, `normalization`

### GenreDeterminator
> Port from: `genre_manager.py` 684 LOC — **Pure struct** (TDD Decision 9 pattern)

- [ ] Create `Packages/Core/Sources/Core/Genre/GenreDeterminator.swift`
- [ ] `GenreInput` struct (musicBrainzTags, discogsStyles, appleMusicGenre, currentGenre)
- [ ] `GenreResult` struct (genre, confidence, source)
- [ ] Genre normalization to canonical genres (mapping table)
- [ ] Classification trees for genre hierarchy
- [ ] Confidence scoring 0-100
- [ ] Unit tests with classification, normalization, confidence, CJK

### YearValidator
> Port from: `year_consistency.py` 393 LOC + `year_utils.py` 128 LOC — **Pure struct**

- [ ] Create `Packages/Core/Sources/Core/Year/YearValidator.swift`
- [ ] Absurd year detection (< 1900), future dates
- [ ] Artist activity period cross-validation
- [ ] Album consistency (same album ≠ different years)
- [ ] Unit tests with sanity checks, consistency, activity period

### YearScorer
> Port from: `year_scoring.py` 945 LOC + `year_score_resolver.py` 524 LOC — **Pure struct, static methods** (TDD Decision 9)

- [ ] Create `Packages/Core/Sources/Core/Year/YearScorer.swift`
- [ ] Weighted multi-source scoring per `ScoringConfig` (30+ factors)
- [ ] Year candidate deduplication
- [ ] Definitive threshold check (configurable)
- [ ] Conflict resolution between sources
- [ ] CRITICAL: must produce identical rankings to Python
- [ ] Extensive unit tests with all scoring factors

### YearFallbackStrategy
> Extracted from: `year_fallback.py` 871 LOC — **Pure struct**

- [ ] Create `Packages/Core/Sources/Core/Year/YearFallbackStrategy.swift`
- [ ] Fallback chain: library year → earliest added date → artist period heuristics
- [ ] Configurable via `FallbackConfig`
- [ ] Unit tests with each fallback strategy

### YearDeterminator
> Port from: `year_determination.py` 717 LOC — **Orchestrator with protocol injection**

- [ ] Create `Packages/Core/Sources/Core/Year/YearDeterminator.swift`
- [ ] Accepts `ExternalAPIService` + `CacheService` through init
- [ ] Coordinates: query → score → validate → fallback
- [ ] Multi-source querying via `ExternalAPIService`
- [ ] Original release year detection (uses AlbumMatcher)
- [ ] Returns `YearResult` (already defined in Protocols.swift)
- [ ] Unit tests with mock API, end-to-end orchestration

## Files

| File | Location | Complexity | Description |
|------|----------|-----------|-------------|
| `Normalization.swift` | `Core/Utils/` | Low | Text normalization |
| `ScriptDetector.swift` | `Core/Utils/` | Medium | Unicode script detection |
| `MetadataUtils.swift` | `Core/Utils/` | Medium | Name cleaning |
| `AlbumType.swift` | `Core/Models/` | Medium | Album classification |
| `AlbumMatcher.swift` | `Core/Matching/` | High | Fuzzy album matching |
| `ArtistMatcher.swift` | `Core/Matching/` | High | Artist normalization |
| `GenreDeterminator.swift` | `Core/Genre/` | High | Genre determination |
| `YearScorer.swift` | `Core/Year/` | Critical | Year scoring — most complex |
| `YearValidator.swift` | `Core/Year/` | Medium | Year sanity checks |
| `YearFallbackStrategy.swift` | `Core/Year/` | Medium | Fallback chain |
| `YearDeterminator.swift` | `Core/Year/` | High | Year orchestrator |

## Acceptance Criteria

- [ ] Genre determination matches Python behaviour for test cases
- [ ] Year scoring produces identical rankings for test cases
- [ ] Agreement rate ≥ 95% with Python version
- [x] `cd Packages/Core && swift test` — all new tests pass (153 tests, 11 suites)
- [x] `cd Packages/Services && swift test` — existing tests pass (68 tests)
- [ ] `xcodebuild build -scheme GenreUpdater` — BUILD SUCCEEDED
- [ ] Performance: < 100ms per track (without API calls)

## Dependencies

- Phase 2 (persistence, domain type extensions) ✅ Done

## Risks

- YearScorer Python parity — parameterized fixtures for line-by-line porting
- Swift Regex vs Python re — use raw literals, test edge cases
- Unicode normalization differences — both use ICU; test Turkish locale
- Levenshtein performance — O(nm) fine for <200 char strings
- 6,200 LOC scope — sub-phases, incremental tests

## Notes

- Це найскладніша фаза — планувати більше часу
- API client stubs з Phase 4 можна scaffold паралельно
- YearScorer має бути максимально покритий тестами (це серце додатку)
