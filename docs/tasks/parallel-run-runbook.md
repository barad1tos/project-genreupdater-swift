# Parallel Run Runbook -- Python vs Swift Parity Testing

## Prerequisites

- Python MGU (original) installed and configured
- Swift GenreUpdater built (`cd Packages/Core && swift build`)
- Sample library export (JSON or CSV) with 100+ tracks
- Both apps configured with identical API keys (MusicBrainz, Discogs)

## Export Steps

### 1. Export from Python MGU

```bash
python -m mgu export --format json --output python_results.json
```

This produces a JSON file containing genre determinations, year scores, and fallback
decisions for every processed track in the library.

### 2. Run Swift Parity Tests

```bash
cd Packages/Core && swift test --filter ParityTests
```

This runs all fixture-based parity tests:
- `GenreParityTests` -- genre determination against `genre_reference.json`
- `YearScoringParityTests` -- year scoring against `year_scoring_reference.json`
- `YearResolutionParityTests` -- year resolution against `year_resolution_reference.json`
- `YearValidationParityTests` -- year validation against `year_validation_reference.json`
- `YearFallbackParityTests` -- fallback decisions against `year_fallback_reference.json`

### 3. Generate Comparison Report

Compare fixture-based outputs (genre determination, year scoring, year fallback).
Differences indicate algorithm drift between Python and Swift implementations.

```bash
# Run parity tests with verbose output to capture individual case results
cd Packages/Core && swift test --filter ParityTests -v 2>&1 | tee parity_results.txt

# Count passes and failures
grep -c "Test Case.*passed" parity_results.txt
grep -c "Test Case.*failed" parity_results.txt
```

## Interpretation Guide

| Scenario | Action |
|----------|--------|
| Exact match | No action needed |
| Minor year difference (+/-1) | Check reissue/remaster handling in `YearScorer` |
| Genre mismatch | Verify genre mapping table in `GenreDeterminator` |
| Score difference > 10 points | Investigate scoring formula in `python_scoring_config.json` |
| Missing results | Check API response caching in `GRDBCacheService` |
| Fallback decision differs | Compare threshold constants in `YearFallbackStrategy` |

## Known Differences

1. **Unicode normalization**: Swift uses NFC by default; Python uses NFD in some paths.
   Affects CJK and Cyrillic artist/album name matching.

2. **Date parsing**: AppleScript date formats differ by macOS locale.
   The `dateAdded` field may parse differently in edge cases.

3. **Float precision**: Year scoring has minor floating-point differences (< 0.01)
   between Python `float` and Swift `Double`. Scores are rounded to `Int` before
   comparison, so this rarely affects results.

4. **API rate limiting**: Timing-dependent tests may vary by network conditions.
   Fixture-based tests are deterministic and avoid this issue.

5. **Sorting stability**: When multiple albums share the same date, tie-breaking
   order may differ between Python (`list.sort` is stable) and Swift (`sorted` is
   also stable, but initial order may differ from Python's dict iteration).

## Running Full Parallel Comparison

For comprehensive parity testing beyond fixtures:

1. Export your full library from Python MGU (`python -m mgu export`)
2. Run Swift processing in dry-run mode (no writes to Music.app)
3. Diff the genre/year assignments:
   ```bash
   diff <(jq -S '.tracks[] | {id, genre, year}' python_results.json) \
        <(jq -S '.tracks[] | {id, genre, year}' swift_results.json)
   ```
4. Focus on tracks where both apps had API results (skip cache-only entries)
5. Investigate any differences using the interpretation guide above

## Adding New Parity Fixtures

When a difference is found during parallel runs:

1. Extract the minimal reproduction case (artist, album, tracks)
2. Add it to the appropriate fixture file in `Packages/Core/Tests/CoreTests/Fixtures/`
3. Include the Python-expected result in the `expected` field
4. Run `swift test --filter ParityTests` to confirm the Swift implementation matches
5. If it does not match, fix the Swift algorithm before proceeding
