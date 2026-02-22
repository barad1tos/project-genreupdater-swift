# Coding Conventions

**Analysis Date:** 2026-02-22

## Naming Patterns

**Types (structs, classes, enums, protocols):**
- PascalCase: `Track`, `YearScorer`, `UpdateCoordinator`, `AppleScriptBridgeError`
- Error enums are named `<Module>Error` — e.g., `MusicBrainzError`, `SanitizationError`, `AppleScriptBridgeError`, `UpdateCoordinatorError`, `BatchProcessorError`, `LibrarySyncError`
- Protocols use noun or noun-phrase form: `CacheService`, `TrackStateStore`, `AppleScriptClient`, `ExternalAPIService`
- ViewModel suffix on observable state classes: `UpdateViewModel`, `WorkflowViewModel`, `DashboardViewModel`
- Actor types use noun form matching the thing they protect: `BatchProcessor`, `APIOrchestrator`, `GRDBCacheService`

**Functions and methods:**
- camelCase verb-noun: `scoreRelease`, `determineDominantGenre`, `sanitizeString`, `fetchAllTrackIDs`, `updateTrackProperty`
- Boolean queries use `is`, `has`, `can`, `should`: `isDefinitive`, `hasBeenProcessed`, `canEdit`, `shouldAutoVerify`
- Factory methods use `make` (in tests): `makeCandidate`, `makeService`, `makeTrack`
- Static factory on types use `create` prefix or `from` prefix: `createInMemory()`, `fromAppleScriptOutput(_:)`

**Variables and properties:**
- camelCase: `albumYear`, `trackCount`, `minConfidence`, `errorMessage`
- No abbreviations: `configuration` not `config` in public APIs (config is allowed for local vars per CLAUDE.md)
- Ignored parameters use `_` prefix: `arguments _:`, `timeout _:`, `batchSize _:` (protocol implementations that don't use the parameter)

**Files:**
- PascalCase matching the primary type: `YearScorer.swift`, `UpdateCoordinator.swift`, `AppleScriptBridge.swift`
- Test files: `<TypeName>Tests.swift` — e.g., `YearScorerTests.swift`, `InputSanitizerTests.swift`
- Parity test files: `<TypeName>ParityTests.swift` — e.g., `YearScoringParityTests.swift`, `GenreParityTests.swift`
- Support files: `TestHelpers.swift`, `FixtureModels.swift`

**Directories:**
- PascalCase matching the subdomain: `Workflow/`, `Persistence/GRDB/`, `Persistence/SwiftData/`, `API/`, `Apple/`
- Test targets mirror source targets: `CoreTests/`, `ServicesTests/`

## Code Style

**Formatting (SwiftFormat):**
- Swift 6.0 mode (`--swiftversion 6.0`)
- Max line width: 120 characters (`--maxwidth 120`)
- Indent: 4 spaces (`--indent 4`)
- `switch` cases NOT indented (`--indentcase false`)
- Function arguments wrap before-first when multiline (`--wraparguments before-first`)
- Collections wrap before-first (`--wrapcollections before-first`)
- `self.` in initializers only (`--self init-only`); `redundantSelf` is disabled (required for actor `os.Logger` autoclosures in Swift 6)
- Closing parens balanced (`--closingparen balanced`)
- `@funcattributes` go on previous line
- Testable imports sorted to bottom (`--importgrouping testable-bottom`)
- No semicolons (`--semicolons never`)
- Operators spaced (`--operatorfunc spaced`)
- File headers not managed (`--header ignore`)
- Extension access control applied to declarations, not the extension keyword (`--extensionacl on-declarations`)

**Disabled SwiftFormat rules (intentional conflicts):**
- `trailingCommas` — conflicts with SwiftLint
- `blankLinesBetweenScopes` — project style preference
- `wrapMultilineStatementBraces` — project style preference
- `modifierOrder` — conflicts with SwiftLint's `modifier_order` rule

**Linting (SwiftLint --strict):**
- Line length: 120 warning / 200 error (`ignores_comments`, `ignores_urls`, `ignores_interpolated_strings`)
- Type body: 300 warning / 500 error lines
- File length: 500 warning / 1000 error lines (use `// swiftlint:disable file_length` on intentionally long files)
- Function body: 60 warning / 100 error lines
- Cyclomatic complexity: 10 warning / 20 error
- `force_cast`, `force_try`, `force_unwrapping`: **error** (never use in production; disable per-line only when unavoidable in tests/statics with comment)
- Identifier name: min 2 chars (exceptions: `id`, `i`, `x`, `y`)
- Function parameters: 5 warning / 8 error
- Modifier order enforced (`modifier_order` opt-in rule)
- `trailing_comma` and `todo` are disabled

**Inline suppression pattern:**
```swift
// swiftlint:disable file_length      // whole file
// swiftlint:disable:next force_try   // next line only
// swiftlint:disable:this inclusive_language  // same line
```

## Import Organization

**Order (SwiftFormat `testable-bottom` grouping):**
1. System frameworks (alphabetical): `Carbon.OpenScripting`, `Foundation`, `OSLog`, `SwiftUI`
2. Third-party: `GRDB` (only in Services)
3. Internal packages: `Core`, `Services`, `SharedUI`
4. Testable imports last: `@testable import Core`, `@testable import Services`

**Example:**
```swift
import Foundation
import OSLog
import Core
import Services
import SwiftUI
@testable import Core
@testable import Services
```

**Cross-package disambiguation:**
- Use `Core.Track` when in Services context — MusicKit also defines `Track`
- `import Core` then qualify: `Core.Track`, `Core.YearResult`

## Section Markers

All files use `// MARK: -` for section separation (no `// ===` ASCII art):

```swift
// MARK: - Error Types
// MARK: - Initialization
// MARK: - ExternalAPIService
// MARK: - Helpers
```

File headers use single-line comment format:
```swift
// FileName.swift — Short description
// Ported from: src/path/file.py (LOC → LOC)
```

## Error Handling

**Pattern:**
- Each module/service defines one error enum named `<Module>Error` at the top of the file (before the type declaration), under a `// MARK: - Errors` section
- All public error enums conform to `Error`, `LocalizedError`, and `Sendable`
- Each case provides a human-readable `errorDescription` via `switch` on `self` in `var errorDescription: String?`
- Associated values in error cases use labeled parameters for clarity: `case scriptNotFound(name: String, searchPath: URL)`, `case writeFailed(trackID: String, property: String, reason: String)`

**Example:**
```swift
public enum AppleScriptBridgeError: Error, LocalizedError {
    case scriptNotFound(name: String, searchPath: URL)
    case executionFailed(scriptName: String, detail: String)
    case timeout(scriptName: String, duration: Duration)

    public var errorDescription: String? {
        switch self {
        case let .scriptNotFound(name, path):
            "Script '\(name).scpt' not found at \(path.path)"
        // ...
        }
    }
}
```

- Never bare `catch` — always catch specific error types or log before rethrowing
- Error chain preserved with `from:` pattern when re-throwing across layers
- `withRetry` utility (`Packages/Services/Sources/Services/API/RetryUtility.swift`) wraps transient API failures with exponential backoff + jitter

## Logging

**Framework:** `os.Logger` (macOS Unified Logging) via `AppLogger` factory in `Packages/Core/Sources/Core/Infra/Logging.swift`

**Subsystem:** `"com.genreupdater.app"` (centralized — never hardcode inline in Services; exceptions exist, e.g., `UpdateCoordinator` uses direct `Logger(subsystem:category:)` for a distinct subsystem)

**Pre-built category loggers (AppLogger):**
```swift
AppLogger.general    // "general"
AppLogger.appleScript // "applescript"
AppLogger.api         // "api"
AppLogger.cache       // "cache"
AppLogger.genre       // "genre"
AppLogger.year        // "year"
AppLogger.processing  // "processing"
AppLogger.subscription // "subscription"
AppLogger.sync        // "sync"
```

**Privacy rules (CRITICAL):**
- `.private` for ALL user-generated values: artist names, track names, album names, track IDs
- `.public` ONLY for system values: counts, property names, script names, error messages, attempt numbers

```swift
// Correct
log.info("Updated \(property, privacy: .public) for \(trackID, privacy: .private)")
log.warning("All \(maxAttempts, privacy: .public) attempts exhausted. Last error: \(error.localizedDescription, privacy: .public)")

// Wrong — never log user music data as .public
log.info("Artist: \(artist, privacy: .public)")  // FORBIDDEN
```

**File-level logger declarations:**
```swift
// In Services files that don't use AppLogger:
private let log = Logger(subsystem: "com.genreupdater.retry", category: "retry")

// In Services files using AppLogger:
private let log = AppLogger.make(category: "sanitizer")
private let log = AppLogger.api  // or any pre-built
```

## Concurrency Patterns

**Actors for shared mutable state:**
- `AppleScriptBridge`, `GRDBCacheService`, `APIOrchestrator`, `SwiftDataTrackStore`, `BatchProcessor`, `UndoCoordinator`, `CheckpointManager` are all `actor`
- Protocol requirements for actor-based services include `: Actor` in the protocol definition: `public protocol CacheService: Actor`

**`@Observable` for ViewModels** (not `ObservableObject`):
```swift
@Observable @MainActor
final class UpdateViewModel { ... }
```

**`Sendable` on all domain types:**
- `Track`, `YearResult`, `ChangeLogEntry`, `CachedAPIResult`, and all models conform to `Sendable`
- Structs with only `Sendable` stored properties are implicitly `Sendable`
- Reference types use `final class` where needed and must be explicitly `@unchecked Sendable` or isolated with `@MainActor`

**`UnsafeSendable` wrapper pattern:**
```swift
// Used for NSUserAppleScriptTask etc. — safe because actor serializes access
private struct UnsafeSendable<T>: @unchecked Sendable {
    let value: T
}
```

**`nonisolated(unsafe)` for non-Sendable formatters:**
```swift
private enum AppleScriptDateFormatters {
    // Safety: Configured once at init, never mutated — concurrent reads are safe.
    nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = .init()
    static let compact: DateFormatter = { /* ... */ }()  // DateFormatter IS Sendable
}
```

## DateFormatter Caching

- `DateFormatter` is `Sendable` — use `static let` in a private `enum` namespace
- `ISO8601DateFormatter` is NOT `Sendable` — use `nonisolated(unsafe)` with safety comment
- Static formatters always go in a private `enum` acting as a namespace (e.g., `private enum AppleScriptDateFormatters`)

## Access Control

**SPM package boundaries:**
- Any type/function used across packages MUST be `public`
- Types/functions within the same package default to `internal` (no modifier needed)
- `private` for file-scope helpers and implementation details

**SwiftUI action/outlet rules:**
- `private_action` and `private_outlet` opt-in rules are enabled: `@IBAction` and `@IBOutlet` must be `private`

**Extensions:**
- Access control applied to individual declarations, not the extension block (`--extensionacl on-declarations`)

## Documentation Style

**All public APIs** have a doc comment:
- One-line summary sentence ending with period
- `/// - Parameters:` block for non-obvious parameters
- `/// - Returns:` when return value needs clarification
- `/// - Throws:` for throwing functions

**Example:**
```swift
/// Scores a single release candidate against query metadata.
///
/// - Parameters:
///   - candidate: The release to score
///   - queryArtist: The artist name from the user's library
///   - currentYear: The existing year in the user's library (if any)
/// - Returns: Scored release with breakdown
public func scoreRelease(_ candidate: ReleaseCandidate, ...) -> ScoredRelease
```

**Private functions:** one-line summary or none if trivially obvious.
**Protocol methods:** documented on the protocol, not repeated on conformances.
**File headers:** single-line comment with filename, description, and `Ported from:` attribution when migrated from Python.

## Module Design

**No barrel files** — each Swift file exports its own types directly.
**Enums as namespaces** for constants and static utilities: `AppLogger`, `InputSanitizer`, `FixtureHelpers`, `FixtureLoader`
**Extensions for protocol conformances:** placed in the same file as the type for small types; separate `Extension` files for significant additions.
**Computed properties** for derived values that belong to a type: `effectiveArtist`, `hasBeenProcessed`, `canEdit`, `isDefinitive`.

---

*Convention analysis: 2026-02-22*
