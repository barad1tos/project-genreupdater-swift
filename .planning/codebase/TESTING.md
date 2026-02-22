# Testing Patterns

**Analysis Date:** 2026-02-22

## Test Framework

**Primary runner:**
- Swift Testing (`import Testing`) — used for all new tests
- Config: none (uses SPM's built-in test discovery via `swift test`)
- Enabled with `swift-tools-version: 6.0` in `Package.swift`

**Secondary runner:**
- XCTest (`import XCTest`) — used only for performance tests (`measure {}` blocks) and UI tests
- Performance tests: `Packages/Core/Tests/CoreTests/PerformanceTests.swift`, `Packages/Services/Tests/ServicesTests/PerformanceTests.swift`
- UI tests: `Tests/UITests/` (XCUITest)
- Integration tests: `Tests/IntegrationTests/` (XCTest + `XCTSkipUnless` for local-only)

**Assertion library:**
- Swift Testing: `#expect(...)` and `#require(...)` macros
- XCTest: `XCTAssertTrue`, `XCTAssertEqual`, `XCTAssertNotNil`

**Strict concurrency:** Both packages enable `StrictConcurrency` experimental feature, so tests compile under Swift 6 strict concurrency rules.

**Run Commands:**
```bash
swift test --package-path Packages/Core                   # Core unit tests
swift test --package-path Packages/Services               # Services unit tests
swift test --package-path Packages/Core --enable-code-coverage   # with coverage
just test                                                  # both packages with coverage
just coverage                                             # check thresholds
```

## Test File Organization

**Location:** Tests are in separate `Tests/` directories within each package — NOT co-located with source.

```
Packages/Core/
├── Sources/Core/
└── Tests/CoreTests/           # 27 test files
    ├── FixtureModels.swift    # shared fixture types (not a test file)
    └── Fixtures/              # JSON fixture files (Bundle.module resource)
        ├── genre_reference.json
        ├── python_scoring_config.json
        ├── year_fallback_reference.json
        ├── year_resolution_reference.json
        ├── year_scoring_reference.json
        └── year_validation_reference.json

Packages/Services/
├── Sources/Services/
└── Tests/ServicesTests/       # 30 test files
    └── TestHelpers.swift      # shared mock actors and stubs

Tests/                         # App-level tests (Xcode test targets)
├── IntegrationTests/          # Local-only: MusicKit + AppleScript
│   ├── AppleScriptIntegrationTests.swift
│   └── MusicLibraryIntegrationTests.swift
└── UITests/                   # XCUITest: critical user flows
    ├── NavigationTests.swift
    ├── OnboardingFlowTests.swift
    └── UpdateFlowTests.swift
```

**Naming:**
- Test files: `<TypeName>Tests.swift` (e.g., `YearScorerTests.swift`)
- Parity test files: `<TypeName>ParityTests.swift` (e.g., `YearScoringParityTests.swift`, `GenreParityTests.swift`)
- Shared helpers: `TestHelpers.swift` (Services), `FixtureModels.swift` (Core)

## Test Structure

**Suite organization (Swift Testing):**
```swift
@Suite("YearScorer — Multi-Factor Release Scoring")
struct YearScorerScoringTests {

    let scorer = YearScorer()  // shared subject — initialized per-test-run

    // MARK: - Base Score

    @Test("Base score is always applied")
    func baseScore() {
        let candidate = makeCandidate(artist: "Test", album: "Test", year: 2000)
        let result = scorer.scoreRelease(candidate, queryArtist: "Test", queryAlbum: "Test")
        #expect(result.breakdown.base == 50)
    }
}
```

**Multiple suites per file** are normal — `YearScorerTests.swift` contains `YearScorerScoringTests` and `YearScorerResolutionTests`.

**Test isolation:** Each test struct is value-typed; the subject is re-initialized for each test. No shared mutable state between tests.

**Async tests:**
```swift
@Test("Progress handler called for each track")
func progressCallback() async throws {
    let processor = BatchProcessor(...)
    _ = try await processor.process(tracks: ..., operation: ..., progressHandler: ...)
    try await Task.sleep(for: .milliseconds(50))  // let async tasks complete
    #expect(updates.count == 6)
}
```

**Error testing:**
```swift
@Test("Throws emptyInput for empty string")
func throwsOnEmpty() {
    #expect(throws: SanitizationError.self) {
        try InputSanitizer.sanitizeString("")
    }
}
```

**Required-or-fail pattern:**
```swift
let release = try #require(fixture.release, "Missing release in \(fixture.id)")
```

## Parameterized Tests (Python Parity)

A key pattern: JSON fixture files capture expected Python outputs and drive parameterized test suites to ensure Swift logic is byte-for-byte equivalent to the Python port.

**Pattern:**
```swift
@Suite("Year Scoring Parity — Python reference fixtures")
struct YearScoringParityTests {

    let scorer: YearScorer

    init() throws {
        let config = try FixtureHelpers.loadPythonScoringConfig()
        scorer = YearScorer(config: config)
    }

    @Test("Individual release scoring matches Python",
          arguments: try! loadScoringFixtures().filter { !$0.isRanking })
    func individualScoring(fixture: ScoringFixtureCase) throws {
        let result = scorer.scoreRelease(...)
        #expect(
            result.totalScore == expected.totalScore,
            "[\(fixture.id)] totalScore: got \(result.totalScore), expected \(expected.totalScore)"
        )
    }
}

private func loadScoringFixtures() throws -> [ScoringFixtureCase] {
    try FixtureLoader.load("year_scoring_reference")
}
```

**Parity test files:**
- `Packages/Core/Tests/CoreTests/GenreParityTests.swift` — genre determination
- `Packages/Core/Tests/CoreTests/YearScoringParityTests.swift` — year scoring
- `Packages/Core/Tests/CoreTests/YearResolutionParityTests.swift` — year resolution
- `Packages/Core/Tests/CoreTests/YearFallbackParityTests.swift` — fallback strategy
- `Packages/Core/Tests/CoreTests/YearValidationParityTests.swift` — year validation

**Fixture loading:**
```swift
// FixtureLoader in FixtureModels.swift
static func load<T: Decodable>(_ filename: String) throws -> T {
    guard let url = Bundle.module.url(
        forResource: filename,
        withExtension: "json",
        subdirectory: "Fixtures"
    ) else {
        throw FixtureError.fileNotFound(filename)
    }
    let data = try Data(contentsOf: url)
    return try JSONDecoder().decode(T.self, from: data)
}
```

Fixtures are declared as `.copy("Fixtures")` resource in `Package.swift` and accessed via `Bundle.module`.

## Mocking

**Pattern:** Mock actors/structs implement protocol conformance. Located in `TestHelpers.swift` for Services and inline private functions/types in Core test files.

**Mock actors** (for protocol conformances requiring `Actor`):
```swift
actor MockAppleScriptClient: AppleScriptClient {
    var writtenProperties: [(trackID: String, property: String, value: String)] = []
    var shouldThrow = false

    func updateTrackProperty(trackID: String, property: String, value: String) async throws {
        if shouldThrow { throw MockScriptError.intentional }
        writtenProperties.append((trackID, property, value))
    }
    // ... other protocol requirements
}

actor MockTrackStore: TrackStateStore { ... }
actor MockCacheService: CacheService { ... }
```

**Mock structs** (for `Sendable` protocol conformances):
```swift
struct MockAPIService: ExternalAPIService {
    let yearResult: YearResult
    let shouldThrow: Bool
    let delay: Duration

    init(yearResult: YearResult = YearResult(), shouldThrow: Bool = false, delay: Duration = .zero) { ... }
    func getAlbumYear(...) async throws -> YearResult { ... }
}
```

**Mock error enums:**
```swift
enum MockScriptError: Error { case intentional }
enum MockAPIError: Error { case intentional }
```

**What to mock:**
- All protocol-typed dependencies (`AppleScriptClient`, `CacheService`, `TrackStateStore`, `ExternalAPIService`)
- External network calls (replaced with `MockAPIService`)
- Filesystem operations in unit tests (use `FileManager.default.temporaryDirectory`)

**What NOT to mock:**
- Pure domain logic (`YearScorer`, `GenreDeterminator`, `AlbumMatcher`, `ArtistMatcher`) — test directly
- GRDB with `createInMemory()` factory — use real in-memory database, not a mock

## Fixtures and Factories

**In-memory database factory:**
```swift
private func makeService() async throws -> GRDBCacheService {
    let service = try GRDBCacheService.createInMemory()
    try await service.initialize()
    return service
}
```

**Track builder helpers (private to test file):**
```swift
private func makeTrack(id: String) -> Track {
    Track(id: id, name: "Track \(id)", artist: "Artist", album: "Album")
}

private func makeTracks(count: Int) -> [Track] {
    (0 ..< count).map { makeTrack(id: "T\($0)") }
}

private func makeCandidate(
    artist: String, album: String, year: Int,
    source: APISource = .musicBrainz,
    releaseType: ReleaseType = .album,
    ...
) -> ReleaseCandidate { ... }
```

**Temporary directories** for filesystem tests:
```swift
let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("BP-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: dir) }
```

**Thread-safe accumulators** for async test coordination:
```swift
private actor Accumulator<T: Sendable> {
    var items: [T] = []
    func append(_ item: T) { items.append(item) }
    func getAll() -> [T] { items }
}
```

**Fixture types** live in `Packages/Core/Tests/CoreTests/FixtureModels.swift`:
- `TrackFixture` — `Codable` struct with `toTrack()` conversion method
- `ReleaseFixture` — with `toCandidate()` conversion
- `GenreFixtureCase`, `ScoringFixtureCase`, `ResolutionFixtureCase`, `ValidationFixtureCase`, `FallbackFixtureCase`

## Performance Tests

Performance tests use `XCTestCase.measure {}` because Swift Testing has no equivalent yet.
Located in `PerformanceTests.swift` files in each package.

```swift
final class CorePerformanceTests: XCTestCase {
    func testGenreDetermination50Tracks() {
        let determinator = GenreDeterminator()
        measure {
            _ = determinator.determineDominantGenre(artistTracks: tracks)
        }
    }

    func testYearScoring20Candidates() {
        measure {
            _ = determinator.determineYear(candidates: candidates, track: track)
        }
    }

    func testNormalization100Strings() {
        measure { for string in strings { _ = normalizeForMatching(string) } }
    }

    func testTrackCodable1000() {
        measure { for track in tracks { /* encode/decode roundtrip */ } }
    }
}
```

## Coverage

**Requirements:**
- Core package: ≥85% line coverage
- Services package: ≥65% line coverage (lower threshold because system-dependent code like MusicKit, AppleScript cannot be unit tested)

**Coverage is enforced in CI** — below-threshold builds fail.

**View Coverage:**
```bash
just coverage   # checks both thresholds after running tests
```

Coverage is measured via `llvm-cov` using `--enable-code-coverage` flag. Coverage for `Tests/` and `.build/` directories is excluded from reports. For Services, `Core/` sources in the binary are also excluded (measured separately).

## Test Types

**Unit Tests (Core — 27 files, ~463 test items):**
- Scope: Pure domain logic, algorithms, models
- Location: `Packages/Core/Tests/CoreTests/`
- No network, no filesystem, no external dependencies
- Includes both direct logic tests and Python parity verification tests

**Unit Tests (Services — 30 files, ~376 test items):**
- Scope: Service implementations with mocked dependencies
- Location: `Packages/Services/Tests/ServicesTests/`
- Uses in-memory GRDB, temporary directories, mock actors
- Includes network client tests with mock `URLSession` or fixture JSON responses

**Integration Tests (local-only):**
- Scope: Real MusicKit + AppleScript against actual Music.app
- Location: `Tests/IntegrationTests/`
- Skip pattern: `XCTSkipUnless(isMusicKitAuthorized(), "...")`
- Never run in CI — require real device with Music.app authorization

**UI Tests (XCUITest):**
- Scope: Critical user flows via accessibility identifiers
- Location: `Tests/UITests/`
- Files: `NavigationTests.swift`, `OnboardingFlowTests.swift`, `UpdateFlowTests.swift`
- Graceful degradation: `XCTSkipUnless` when app state not reachable (CI, no Music.app)
- `continueAfterFailure = false` in `setUpWithError()`

## CI Test Pipeline

**Trigger:** Push to `main`/`dev`, PR to `main`

**Keychain unlock** (required before test runs on CI):
```yaml
- name: Unlock Keychain for tests
  run: security unlock-keychain -p "" ~/Library/Keychains/login.keychain-db
```

**Services test hang workaround:** SwiftData prevents clean exit on headless CI runners. Tests run with a 120-second kill timeout:
```yaml
- name: Test Services
  run: |
    swift test --package-path Packages/Services --enable-code-coverage &
    TEST_PID=$!
    SECONDS=0
    while kill -0 $TEST_PID 2>/dev/null; do
      if [ $SECONDS -ge 120 ]; then
        echo "::warning::swift test hung after completion, killing"
        kill $TEST_PID 2>/dev/null
        wait $TEST_PID 2>/dev/null || true
        exit 0
      fi
      sleep 1
    done
    wait $TEST_PID
  timeout-minutes: 5
```

The `exit 0` after the kill means a hang is treated as a warning, not a failure. This is intentional — SwiftData's exit hang is cosmetic; all tests have already run.

**Full CI pipeline order:** Build Core → Build Services → Build SharedUI → Unlock Keychain → Test Core → Test Services → Check Coverage Thresholds → Validate Entitlements → SwiftLint → SwiftFormat check → Periphery dead-code scan

**CI gate job:** A separate `gate` job on `ubuntu-latest` checks that `build-and-lint` succeeded. This ensures PR blocking works even when jobs run in parallel.

## Common Test Patterns

**Testing async actors with accumulation:**
```swift
let accumulator = Accumulator<ProgressUpdate>()
_ = try await processor.process(
    tracks: tracks,
    operation: { _ in [] },
    progressHandler: { update in
        Task { await accumulator.append(update) }
    }
)
try await Task.sleep(for: .milliseconds(50))  // let queued Tasks complete
let updates = await accumulator.getAll()
#expect(updates.count == 6)
```

**Testing error conditions:**
```swift
let service = MockAPIService(shouldThrow: true)
await #expect(throws: MockAPIError.self) {
    try await service.getAlbumYear(...)
}
```

**Boundary testing:**
```swift
@Test("Succeeds at exactly maxInputSize (boundary)")
func succeedsAtBoundary() throws {
    let boundary = String(repeating: "x", count: InputSanitizer.maxInputSize)
    let result = try InputSanitizer.sanitizeString(boundary)
    #expect(result == boundary)
}
```

**Parity error messages** (include fixture ID for debuggability):
```swift
#expect(
    result.totalScore == expected.totalScore,
    "[\(fixture.id)] totalScore: got \(result.totalScore), expected \(expected.totalScore)"
)
```

---

*Testing analysis: 2026-02-22*
