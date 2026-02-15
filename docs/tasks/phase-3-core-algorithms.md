---
phase: 3
title: "Core Algorithms"
status: planned
priority: critical
depends_on:
  - "Phase 2"
---
> Parent: [[PRD]]

**Related:** [[phase-2-core-models|Phase 2: Core Models]] | [[phase-4-api-cache|Phase 4: API + Cache]] | [[phase-5-workflows|Phase 5: Workflows]]
**Technical ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] | [[TDD#Decision 9 Year Scoring → Pure Struct]]

# Phase 3: Core Algorithms — Hardest Phase

## Context

Ядро бізнес-логіки: алгоритми визначення жанру та року. Портуються з battle-tested Python-реалізації (32.7K LOC). Перед початком потрібен фіксований тестовий датасет з Python reference outputs для параметризованих тестів.

## Prerequisites

- [ ] Експортувати фіксований тестовий датасет (200-500 треків) з Python-версії
- [ ] Згенерувати known-good Python outputs для genre determination
- [ ] Згенерувати known-good Python outputs для year scoring
- [ ] Зберегти як test fixtures у проєкті

## Deliverables

### GenreManager
> **TDD ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] (`genre_manager.py` 684 LOC → `GenreDeterminator.swift` 🔴, classification trees, standalone)

- [ ] Створити `Packages/Services/Sources/Services/Genre/GenreManager.swift`
- [ ] Портувати алгоритм визначення жанру з Python
- [ ] Multi-source genre resolution (MusicBrainz tags, Discogs styles, Apple Music genre)
- [ ] Genre normalization та mapping (canonical genres)
- [ ] Confidence scoring для кожного визначення
- [ ] Параметризовані тести проти Python reference data
- [ ] Edge cases: CJK artists, compilations, various genres, empty/missing data

### YearManager
> **TDD ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] (`year_determination.py` + `year_fallback.py` merge → 1,588 LOC → `YearDeterminator.swift` 🔴)

- [ ] Створити `Packages/Services/Sources/Services/Year/YearManager.swift`
- [ ] Портувати year determination orchestrator
- [ ] Multi-source year querying (MusicBrainz, Discogs, Apple Music)
- [ ] Original release year detection (не remaster/reissue)
- [ ] Artist activity period validation
- [ ] Suspicious year detection (< 1900, future years)
- [ ] Параметризовані тести проти Python reference data

### ScoringEngine (найскладніший компонент)
> **TDD ref:** [[TDD#Decision 9 Year Scoring → Pure Struct]] (чому pure struct без actor: scoring є pure function inputs → score) | [[TDD#src/services/api/ → Packages/Services/Sources/Services/API/]] (`year_scoring.py` 945 LOC + `year_score_resolver.py` 524 LOC → `YearScorer.swift`, moved to Core)

- [ ] Створити `Packages/Services/Sources/Services/Year/ScoringEngine.swift`
- [ ] Портувати year candidate scoring з Python
- [ ] Конфігурований definitive threshold
- [ ] Weighted multi-source scoring
- [ ] Year candidate deduplication
- [ ] Рейтинг має бути ідентичний Python-версії для тестового датасету
- [ ] Extensive unit tests з edge cases

### AlbumMatcher
> **TDD ref:** [[TDD#src/core/models/ → Packages/Core/Sources/Core/Models/]] (`metadata_utils.py` 803 LOC → `MetadataUtils.swift` 🔴, regex-heavy) — album matching logic lives here

- [ ] Створити `Packages/Services/Sources/Services/Matching/AlbumMatcher.swift`
- [ ] Fuzzy album matching (Levenshtein distance, normalization)
- [ ] Remaster/deluxe/edition variant detection
- [ ] Disc number handling (Disc 1, CD2, etc.)
- [ ] Unit tests з real-world album name variations

### ArtistMatcher
> **TDD ref:** [[TDD#src/core/tracks/ → Packages/Core/ (Genre/, Year/, Processing/)]] (`artist_renamer.py` 194 LOC → `TrackCleaningFlow.swift` merge) — artist normalization + featured extraction

- [ ] Створити `Packages/Services/Sources/Services/Matching/ArtistMatcher.swift`
- [ ] Artist name normalization (The Beatles → Beatles)
- [ ] Featured artist extraction (feat., ft., with, &)
- [ ] CJK/Unicode script handling
- [ ] Collaboration detection (A & B → [A, B])
- [ ] Unit tests з real-world artist name variations

### MetadataUtils
> **TDD ref:** [[TDD#src/core/models/ → Packages/Core/Sources/Core/Models/]] (`metadata_utils.py` 803 LOC → `MetadataUtils.swift` 🔴, regex-heavy, direct port)

- [ ] Створити `Packages/Core/Sources/Core/Utils/MetadataUtils.swift`
- [ ] Track/album name cleaning
- [ ] Remaster detection та tag removal
- [ ] Edition/version normalization
- [ ] Unit tests

### ScriptDetector
> **TDD ref:** [[TDD#src/core/models/ → Packages/Core/Sources/Core/Models/]] (`script_detection.py` 519 LOC → `ScriptDetection.swift` 🟡, Swift Regex builder замість re module)

- [ ] Створити `Packages/Core/Sources/Core/Utils/ScriptDetector.swift`
- [ ] Unicode script detection для CJK handling
- [ ] Визначення мови тексту (Latin, CJK, Cyrillic, etc.)
- [ ] Unit tests з multi-script strings

## Files (~7, 5 з high complexity)

| File | Complexity | Description |
|------|-----------|-------------|
| `Services/Genre/GenreManager.swift` | High | Genre determination |
| `Services/Year/YearManager.swift` | High | Year orchestrator |
| `Services/Year/ScoringEngine.swift` | Critical | Year scoring — most complex |
| `Services/Matching/AlbumMatcher.swift` | High | Fuzzy album matching |
| `Services/Matching/ArtistMatcher.swift` | High | Artist normalization |
| `Core/Utils/MetadataUtils.swift` | Medium | Name cleaning |
| `Core/Utils/ScriptDetector.swift` | Medium | Unicode detection |

## Acceptance Criteria

- [ ] Genre determination matches Python версії для reference dataset
- [ ] Year scoring produces identical rankings для test cases
- [ ] Всі параметризовані тести проходять проти Python reference data
- [ ] Agreement rate ≥ 95% з Python-версією
- [ ] `swift test` проходить для всіх пакетів
- [ ] Performance: обробка одного треку < 100ms (без API calls)

## Dependencies

- Phase 2 (persistence, domain type extensions)
- Python reference dataset (MUST be ready before starting)

## Risks

- Складність портування Python scoring algorithm — може потребувати ітерацій
- Fuzzy matching в Swift може давати інші результати через Unicode normalization
- CJK handling потребує ретельного тестування

## Notes

- Це найскладніша фаза — планувати більше часу
- API client stubs з Phase 4 можна scaffold паралельно
- ScoringEngine має бути максимально покритий тестами (це серце додатку)
