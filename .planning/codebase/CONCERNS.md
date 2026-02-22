# Codebase Concerns

**Analysis Date:** 2026-02-22

## Tech Debt

**Duplicate Update View/ViewModel Pair:**
- Issue: Two parallel update flows exist side-by-side. `UpdateView` + `UpdateViewModel` is a sheet-based 5-phase flow; `UpdateWorkflowView` + `WorkflowViewModel` is an inline 7-phase flow. Both are wired in `MainView` — the inline one as the primary Update tab, the sheet-based one accessible via Cmd+U only. This is described in `MainView.swift` as "legacy Cmd+U support."
- Files: `App/Views/UpdateView.swift` (367 LOC), `App/Views/UpdateWorkflowView.swift` (413 LOC), `App/ViewModels/UpdateViewModel.swift` (234 LOC), `App/ViewModels/WorkflowViewModel.swift` (396 LOC)
- Impact: ~1,410 LOC of duplicated workflow logic. Any UI bug fix may need to be applied twice. The two phase enums (`UpdatePhase`, `WorkflowPhase`) diverge over time.
- Fix approach: Remove `UpdateView` + `UpdateViewModel`. Wire `WorkflowViewModel` for Cmd+U by presenting `UpdateWorkflowView` in a sheet.

**SmartFilter.lowConfidence is a No-Op Stub:**
- Issue: `SmartFilterType.lowConfidence` is exposed in the UI but its filter implementation returns all tracks unchanged — it doesn't actually filter anything.
- Files: `App/ViewModels/WorkflowViewModel.swift` lines 379–381
- Impact: Users see a "Low Confidence" filter option that does nothing. Incorrect behavior masquerading as a feature.
- Fix approach: Implement using `Track.trackStatus` or a stored confidence score, or remove the case until it can be properly implemented.

**Hard-Coded Genre Confidence Score:**
- Issue: Genre consensus confidence is hard-coded at `80` in `UpdateCoordinator.updateTrack()` — it does not derive from actual consensus strength.
- Files: `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift` line 126
- Impact: All genre changes are presented at exactly 80% confidence regardless of how many or few tracks agreed. Misleads users about certainty.
- Fix approach: Pass `GenreResult.confidence` from `GenreDeterminator.determineDominantGenre()` through to `ProposedChange`.

**Hard-Coded Bundle ID Strings in Services Package:**
- Issue: The `com.genreupdater` subsystem string is repeated verbatim in at least 11 Services source files as a Logger subsystem literal, and `com.genreupdater.discogs` appears in `DiscogsClient` as a Keychain service key.
- Files: `Packages/Services/Sources/Services/Workflow/BatchProcessor.swift`, `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift`, `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift`, and 8 others
- Impact: Renaming the bundle ID requires manual find-replace across Services. Services package should not know the bundle ID.
- Fix approach: Define a single `AppLogger.subsystem` constant in the `Core.AppLogger` infrastructure and use it in all Logger initialisations.

**`force_try` for Static Regex Compilation:**
- Issue: Two module-level `NSRegularExpression` constants use `try!`. SwiftLint suppression comments acknowledge this with `// swiftlint:disable:next force_try`.
- Files: `Packages/Core/Sources/Core/Matching/ArtistMatcher.swift` line 119, `Packages/Core/Sources/Core/Matching/AlbumMatcher.swift` line 110
- Impact: A typo in the regex pattern causes a crash at module load. The patterns are static and unchanging, so the risk is low but non-zero.
- Fix approach: Wrap in a fatalError-on-nil initialiser, or use Swift's `Regex` literal syntax (Swift 5.7+) which is compile-time validated.

## Security Considerations

**AppleScript Error Detection by String Matching:**
- Risk: `AppleScriptBridge.updateTrackProperty()` and `batchUpdateTracks()` both detect script errors by checking if the return string `contains("error")`. A track titled "Guitar Error Recovery" would incorrectly trigger an error.
- Files: `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift` lines 188 and 220
- Current mitigation: The `update_property.applescript` always prefixes failures with `"Error:"` (capital E, then colon), so a lowercase match on `"error"` would catch e.g. a song called "Error". The case-insensitive `lowercased()` widens the false positive surface.
- Recommendations: Change scripts to return a structured prefix — e.g. `"SUCCESS:"` or `"ERROR:"` — and check for the exact prefix in Swift rather than substring-matching.

**Discogs Personal Access Token in UserDefaults Path:**
- Risk: `AppDependencies.initializeAlgorithmsAndAPI()` reads `contactEmail` from `UserDefaults.standard`. If the same key were accidentally used to store a token, it would be unprotected.
- Files: `App/AppDependencies.swift` line 208
- Current mitigation: Only `contactEmail` is stored in UserDefaults; the Discogs PAT is correctly stored in Keychain via `DiscogsClient.fromKeychain()`.
- Recommendations: This is currently safe but fragile — document clearly which settings live in UserDefaults vs Keychain.

**`sanitizeArguments` Applies `sanitizeString` (Quote-Escape Only) Not Full Validation:**
- Risk: `InputSanitizer.sanitizeArguments()` calls `sanitizeString()` which only escapes `\` and `"`. It does NOT call `validateScriptCode()` which checks for dangerous patterns like `do shell script`. So arguments passed to `runScript()` are escape-sanitized but not pattern-validated.
- Files: `Packages/Services/Sources/Services/Apple/InputSanitizer.swift` lines 147–149, `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift` line 99
- Current mitigation: The sandboxed `NSUserAppleScriptTask` provides an outer boundary; arguments are passed as data strings not code fragments.
- Recommendations: This is defense-in-depth acceptable, but the distinction should be documented in `sanitizeArguments()` docstring.

## Performance Bottlenecks

**`BrowseView.allArtistSummaries` Recomputes On Every Render:**
- Problem: `allArtistSummaries` is a computed `var` that calls `Dictionary(grouping:)` over all 38K tracks plus two O(n) passes per artist (genre + health ratio). `filteredSections` calls `allArtistSummaries` on every SwiftUI body evaluation.
- Files: `App/Views/BrowseView.swift` lines 209–222, 225–243
- Cause: SwiftUI `View.body` recomputes when any `@State` changes (search text, navigation path, selected track). With 38K tracks the grouping is expensive.
- Improvement path: Cache the `allArtistSummaries` result in `@State` and invalidate only when `tracks` changes — same pattern that `MainView` uses for `artistGroups`/`albumGroups` (added in commit `404cdd6`). The `BrowseView` was not updated with the same caching.

**Single-Track API Call Per Track in Sequential Batch:**
- Problem: `UpdateCoordinator.updateTracks()` calls `updateTrack()` sequentially per track, which for year determination triggers one API round trip per unique album (cache miss path). With 38K tracks and poor cache state, this is extremely slow.
- Files: `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift` lines 176–197
- Cause: No album-level deduplication before API calls. Two tracks from the same album cause two identical API calls to `APIOrchestrator.getAlbumYear()`.
- Improvement path: Pre-group tracks by artist+album before the update loop and fetch API data once per album, then apply to all tracks in that album. GRDB cache mitigates this after the first run.

**`LibrarySyncService.detectChanges()` Fetches ALL Common-ID Tracks:**
- Problem: On libraries with 38K tracks, `detectChanges()` fetches ALL tracks that exist in both library and store (the `commonIDs` set) via AppleScript to compare `lastModified`. For a 38K track library after initial sync, this fetches ~38K tracks on every sync check.
- Files: `Packages/Services/Sources/Services/Workflow/LibrarySyncService.swift` lines 93–104
- Cause: `hasTrackChanged()` compares `lastModified` timestamps but only when both are non-nil. The fallback compares all fields, requiring full metadata.
- Improvement path: Store a hash or `lastModified` in `SwiftDataTrackStore` and compare before fetching full metadata. Only fetch tracks where the stored `lastModified` is stale.

**Performance Tests Use Toy Dataset Sizes:**
- Problem: `CorePerformanceTests` tests genre determination at 50 tracks, year scoring at 20 candidates, and normalization at 100 strings. `ServicesPerformanceTests` presumably tests similarly small datasets. No test exercises the 30K–38K track scale mentioned in performance targets.
- Files: `Packages/Core/Tests/CoreTests/PerformanceTests.swift`, `Packages/Services/Tests/ServicesTests/PerformanceTests.swift`
- Cause: Tests were written as stubs.
- Improvement path: Add a performance test that creates 30K track fixtures and validates library-load, filter, and grouping operations against the stated targets (<5s load, <50ms search).

## Fragile Areas

**AppleScript Track ID Format Sensitivity:**
- Files: `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift`, `Resources/Scripts/update_property.applescript`
- Why fragile: `update_property.applescript` validates the track ID with `tID as integer`. MusicKit IDs are strings (e.g., `"i.aBcDeFg123"`), not integers. The `TrackIDMapper` exists to map MusicKit string IDs to AppleScript integer IDs, but `UpdateCoordinator.applyChange()` only uses the mapper if it's non-nil. If `idMapper` is nil (it is by default in many code paths), integer-format IDs must already be in `change.track.id` — otherwise the script silently returns an error string.
- Safe modification: Always wire `idMapper` in `AppDependencies`, or assert non-nil mapper when writing.
- Test coverage: `TrackIDMapperTests.swift` tests the mapper itself but not the nil-idMapper path in `UpdateCoordinator`.

**`AppDependencies.initializeWorkflowServices()` Silent Failure:**
- Files: `App/AppDependencies.swift` lines 226–234
- Why fragile: If any prerequisite service is nil (logStore, trackStore, cache, orchestrator, genreDeterminator), the method logs an error and returns — leaving `updateCoordinator`, `batchProcessor`, `undoCoordinator`, and `librarySyncService` all `nil`. The app transitions to `.ready` state despite being unable to update tracks. `MainView.updateContent` shows a "Services Unavailable" placeholder, but the user has no actionable information.
- Safe modification: Propagate the partial-init failure back to `initialize()` as a thrown error so `appState` is set to `.error(...)`.

**`GRDB eraseDatabaseOnSchemaChange` in DEBUG builds:**
- Files: `Packages/Services/Sources/Services/Persistence/GRDB/GRDBCacheService.swift` line 50
- Why fragile: Any schema change during development silently wipes the entire API cache in DEBUG mode. If a developer accidentally triggers a DEBUG build with real library data, cached API results are destroyed.
- Safe modification: This is the intended GRDB developer ergonomics. Acceptable, but developers should be aware that `just build` (debug) may reset the cache.

**AppleScript Output Parsing Uses Non-Standard ASCII Delimiters:**
- Files: `Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift` lines 203–210, `Resources/Scripts/batch_update_tracks.applescript`
- Why fragile: Batch updates pass data using ASCII 30 (Record Separator) and ASCII 29 (Group Separator) as delimiters. These characters cannot appear in track metadata — but if they did (edge case: corrupt library), the script would silently split the data incorrectly.
- Safe modification: Document the assumption; consider length-prefixed encoding for production hardening.

## Scaling Limits

**iCloud KVS for Free Track Counter:**
- Current capacity: `NSUbiquitousKeyValueStore` has a 1MB total storage limit per app. The free track counter (`freeTracksUsed`) is an integer, negligible in isolation.
- Limit: iCloud KVS sync is fire-and-forget with no guaranteed delivery. If a user uses the app offline and the KVS store fails to sync, `freeTracksUsed` on different devices may diverge. A user could exhaust the free tier on device A while device B still shows slots available.
- Scaling path: Use a server-side counter (requires backend) or accept the inconsistency as a known limitation of the freemium model.

**AppleScript IPC for 38K Library:**
- Current capacity: `AppleScriptBridge.fetchAllTrackIDs()` fetches all track IDs in one call; `fetchTracksByIDs()` batches in chunks of 1000. Each AppleScript IPC call takes measurable time.
- Limit: A single call to `LibrarySyncService.detectChanges()` on a 38K library triggers at minimum one `fetchAllTrackIDs()` call plus potentially up to 38 batched `fetchTracksByIDs()` calls.
- Scaling path: Replace `fetchAllTrackIDs()` with MusicKit (read-only IDs available without AppleScript) to reduce IPC overhead for the sync check.

## Dependencies at Risk

**GRDB 7.x — Single Dependency for Persistence:**
- Risk: GRDB is a third-party SPM package with no Apple backing. It is well-maintained but any breaking change to GRDB's API (e.g., major version bump) requires migration work.
- Impact: `GRDBCacheService`, `GRDBMigrations`, `GRDBModels` — all GRDB-specific code in `Packages/Services/Sources/Services/Persistence/GRDB/`.
- Migration plan: The `CacheService` protocol isolates GRDB behind an abstraction. Replacing the backing store is a Services-internal concern that does not affect Core or App.

**NSUserAppleScriptTask — App Review Risk (HIGH):**
- Risk: Apple may flag `NSUserAppleScriptTask` during App Review as a mechanism to escape the sandbox, even though it is the documented Apple-sanctioned approach. The TDD lists this as a `🔴 High` risk.
- Impact: Rejection blocks the entire App Store distribution path.
- Current mitigation: `docs/appstore/justification-nsuserapplescripttask.md` written. Entitlements include `com.apple.security.scripting-targets`.
- Fallback: TDD documents `NSAppleScript + temporary-exception` as a ~2-week fallback if rejected.

**MusicKit Write API Gap:**
- Risk: MusicKit is read-only. All writes go through AppleScript. If Apple ever introduces write support in MusicKit, the dual-path architecture becomes redundant. More critically, if Apple removes AppleScript write access from the Music.app scripting target in a future macOS release, the write path breaks entirely.
- Impact: Entire genre/year update functionality.
- Migration plan: No workaround exists without AppleScript for writes. Monitor `com.apple.music.library.read-write` entitlement support across macOS releases.

## Missing Critical Features

**No Parallel Run Comparison Tool:**
- Problem: Phase 7 requires ≥95% agreement between Python and Swift scoring. A runbook exists (`docs/tasks/parallel-run-runbook.md`) but the comparison script itself does not exist in the repository (`scripts/` only contains `validate-entitlements.sh`).
- Blocks: Parallel run verification, which is a phase 7 acceptance criterion.

**No Real Performance Profiling Against Target Library:**
- Problem: All phase 7 performance targets are unverified. No Instruments profiling has been run against a 30K+ track library. Performance tests use 20–1000 item datasets.
- Blocks: Phase 7 acceptance criteria: library load <5s, search <50ms, peak memory <500MB.

**App Store Submission Blocklist (from Phase 7 Task):**
- App Privacy labels not submitted in App Store Connect
- Screenshots for all required size classes not yet created
- TestFlight distribution not set up (Xcode Cloud configuration exists in principle but not tested)
- Subscription flow not validated in StoreKit sandbox
- Video demo not recorded

## Test Coverage Gaps

**No Tests for App Layer (ViewModels, Views, AppDependencies):**
- What's not tested: `AppDependencies.initialize()`, partial-initialization failure paths, `WorkflowViewModel` phase transitions, `UpdateViewModel` phase transitions, `DashboardViewModel`, `BrowseView` computed grouping.
- Files: `App/AppDependencies.swift`, `App/ViewModels/WorkflowViewModel.swift`, `App/ViewModels/UpdateViewModel.swift`, `App/ViewModels/DashboardViewModel.swift`
- Risk: Regression in app initialization or view-state logic goes undetected. The CI only runs SPM package tests (`Core` + `Services`); the App target has no unit tests.
- Priority: High

**No API Integration Tests (Live Endpoints):**
- What's not tested: Real MusicBrainz, Discogs, Apple Music Search responses against production APIs. Rate limiting behavior. Network error recovery.
- Files: `Packages/Services/Sources/Services/API/MusicBrainzClient.swift`, `Packages/Services/Sources/Services/API/DiscogsClient.swift`, `Packages/Services/Sources/Services/API/AppleMusicSearchClient.swift`
- Risk: API contract changes or unexpected response shapes break year detection silently. Noted as open in phase-7 task (`[ ] API integration tests z live endpoints`).
- Priority: Medium

**`UpdateCoordinator.updateTracks()` Without idMapper:**
- What's not tested: The nil-idMapper code path in `applyChange()` — whether integer-format IDs survive the AppleScript write round-trip end-to-end.
- Files: `Packages/Services/Sources/Services/Workflow/UpdateCoordinator.swift` lines 302–306
- Risk: Writes silently fail or apply to wrong tracks when `idMapper` is nil.
- Priority: High

**UITests Not Runnable in CI:**
- What's not tested: `Tests/UITests/OnboardingFlowTests.swift`, `Tests/UITests/NavigationTests.swift`, `Tests/UITests/UpdateFlowTests.swift` — all three XCUITest files exist but CI only runs `swift test` on SPM packages. The Xcode project's UITest target is not exercised in GitHub Actions.
- Files: `Tests/UITests/`, `.github/workflows/ci.yml`
- Risk: XCUITests may be stale or broken without any CI feedback.
- Priority: Medium

---

*Concerns audit: 2026-02-22*
