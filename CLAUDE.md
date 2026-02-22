# GenreUpdater — Project Instructions

> Swift macOS app for updating genres/years in Apple Music. Ported from Python (32.7K LOC).
> Target: Mac App Store, Freemium + Subscription.

## Project Structure

```
GenreUpdater/
├── App/                          # Main app target (SwiftUI)
│   ├── GenreUpdater.entitlements  # Sandbox + scripting-targets + network
│   ├── GenreUpdaterApp.swift      # @main entry point
│   ├── AppDependencies.swift      # DI container
│   └── Views/                     # SwiftUI views
├── Packages/
│   ├── Core/                      # Pure domain logic (NO external deps)
│   │   └── Sources/Core/
│   │       ├── Config/            # AppConfiguration (JSON-backed)
│   │       ├── Genre/             # GenreDeterminator (Phase 3B)
│   │       ├── Infra/             # Logging (os.Logger)
│   │       ├── Matching/          # AlbumMatcher, ArtistMatcher (Phase 3A)
│   │       ├── Models/            # Track, Protocols, TrackStatus, Tier, AppFeature, ProgressUpdate, AlbumType
│   │       ├── Utils/             # Normalization, ScriptDetector, MetadataUtils (Phase 3A)
│   │       └── Year/              # YearScorer, YearValidator, YearFallbackStrategy, YearDeterminator (Phase 3B)
│   ├── Services/                  # External world (APIs, Music.app, cache)
│   │   └── Sources/Services/
│   │       ├── Apple/             # AppleScriptBridge, InputSanitizer, ScriptInstaller
│   │       ├── MusicLibraryReader # MusicKit integration
│   │       ├── Persistence/
│   │       │   ├── GRDB/          # GRDBCacheService, GRDBModels, GRDBMigrations
│   │       │   └── SwiftData/     # PersistedTrack, SwiftDataTrackStore
│   │       ├── Subscription/      # SubscriptionService, FeatureGate (StoreKit 2)
│   │       └── Workflow/          # UpdateCoordinator, BatchProcessor, UndoCoordinator, CheckpointManager, LibrarySyncService, ChangePreviewPipeline
│   └── SharedUI/                  # Reusable SwiftUI components
│       └── Theme/                 # DesignTokens (Spacing, Radius, AppFont, Shadow, Motion), AyuColors, AppearanceMode
├── Tests/
│   ├── GenreUpdaterTests/         # App-level unit tests
│   ├── IntegrationTests/          # MusicKit + AppleScript (local only)
│   └── UITests/                   # XCUITests for critical flows
├── Resources/                     # AppleScript files, assets
├── scripts/                       # CI helper scripts (validate-entitlements.sh)
├── docs/
│   ├── plans/                     # PRD.md, TDD.md
│   └── tasks/                     # Phase task files (phase-*.md)
├── .claude/
│   ├── hooks/                     # Claude Code quality gates
│   │   ├── lib/common.sh          # Shared helpers (jq-based, hardened)
│   │   ├── commit-docs-sync-check.sh  # Blocking: Swift commit → needs docs
│   │   ├── swiftlint-precommit-check.sh   # Blocking: SwiftLint --strict before commit
│   │   ├── swift-task-tracking-reminder.sh  # Advisory: .swift edit reminder
│   │   ├── session-start-phase-context.sh   # Advisory: phase context on start
│   │   └── test-hooks.sh          # Validation suite (18 tests)
│   └── agents/                    # Custom agents (scrum-master, swift-expert)
└── project.yml                    # XcodeGen spec
```

## Architecture Rules

### Package Dependencies (STRICT)
```
App → Services → Core
App → SharedUI → Core
```
- Core has ZERO external dependencies (no SwiftData, no MusicKit)
- Services depends on Core only
- SharedUI depends on Core only
- App depends on everything

### Access Control in SPM
- All types/functions used across package boundaries MUST be `public`
- Internal types stay `internal` (default)
- This is the most common build error — if "cannot find type X", add `public`

### Namespace Disambiguation
- Use `Core.Track` when referencing Track from Services (MusicKit has its own Track type)
- Pattern: `import Core` then qualify with `Core.Track` where ambiguous

## Coding Patterns

### Concurrency
- **Actors** for shared mutable state: `AppleScriptBridge`, `CacheService`, `APIOrchestrator`
- **Sendable** on all domain types (Track, YearResult, etc.)
- **UnsafeSendable wrapper** for Foundation types that are safe in actor context but not marked Sendable:
  ```swift
  private struct UnsafeSendable<T>: @unchecked Sendable {
      let value: T
  }
  ```
- **async/await** everywhere, no completion handlers
- `@Observable` instead of `ObservableObject` for SwiftUI state

### InputSanitizer (CRITICAL — two functions)
- `sanitizeScriptCode()` — for AppleScript CODE fragments (strips `; | & $ () {}`)
- `escapeStringValue()` — for DATA values (track names, etc.) (escapes `"` and `\` only)
- NEVER use `sanitizeScriptCode()` on track metadata — it destroys parentheses in song titles

### Logging Privacy
- `.private` for ALL user-generated values (artist names, track names, album titles)
- `.public` ONLY for system identifiers (counts, property names, script names, error messages)
- Example: `log.info("Updated \(property, privacy: .public) for \(trackID, privacy: .private)")`

### DateFormatter Caching
- Use `static let` for DateFormatters — they're expensive to create
- `DateFormatter` is `Sendable` — no special annotation needed
- `ISO8601DateFormatter` is NOT `Sendable` — requires `nonisolated(unsafe)` with safety comment:
  ```swift
  private enum Formatters {
      // Safety: configured once, never mutated — concurrent reads are safe.
      nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
          let f = ISO8601DateFormatter()
          return f
      }()
      static let natural: DateFormatter = { /* ... */ }()
  }
  ```

### Error Handling
- Per-module error enums: `AppleScriptBridgeError`, `SanitizationError`, `MusicLibraryError`
- `AppError` at App level wraps all module errors
- Always preserve error chain with `from:` in re-throws

## Dependencies

### Current (Phase 1–2B)
- MusicKit (Apple framework)
- OSLog (Apple framework)
- Carbon.OpenScripting (for AppleScript event constants)
- **GRDB 7.x** — API response cache (SQLite, Services package)
- **SwiftData** (Apple framework) — track state persistence (Services package)
- **StoreKit 2** (Apple framework) — subscriptions (Services package)

### Dev Tools (Homebrew)
- **SwiftLint** — linting (pre-commit + CI, `--strict`)
- **SwiftFormat** — auto-formatting (pre-commit + CI, config: `.swiftformat`)
- **Periphery** — dead code detection (pre-commit + CI, `--strict`)

## Build & Test

```bash
# Local CI — full pipeline (mirrors .github/workflows/ci.yml)
# Requires: brew install just
just ci

# Individual steps
just build        # Build Core → Services → SharedUI
just test         # Test Core + Services (with coverage)
just coverage     # Check coverage thresholds (Core ≥85%, Services ≥65%)
just entitlements # Validate entitlements whitelist
just lint         # SwiftLint --strict
just format       # SwiftFormat --lint (check only)
just periphery    # Periphery scan Core + Services
just fix          # Auto-fix: apply SwiftFormat

# Build all packages
swift build --package-path Packages/Core
swift build --package-path Packages/Services
swift build --package-path Packages/SharedUI

# Run tests
swift test --package-path Packages/Core
swift test --package-path Packages/Services

# Full Xcode build (unsigned — no certificate required)
xcodebuild build -project GenreUpdater.xcodeproj -scheme GenreUpdater \
  -destination "platform=macOS,arch=arm64" \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO -quiet

# Lint
swiftlint lint --strict App Packages/Core/Sources Packages/Services/Sources Packages/SharedUI/Sources
swiftformat App Packages/Core/Sources Packages/Services/Sources Packages/SharedUI/Sources --lint

# Auto-format (applies fixes)
swiftformat App Packages/Core/Sources Packages/Services/Sources Packages/SharedUI/Sources

# XcodeGen (if project.yml changed)
xcodegen generate
```

## Entitlements (App Sandbox)
The app runs in sandbox with these entitlements:
- `com.apple.security.app-sandbox` — required for App Store
- `com.apple.security.scripting-targets` → `com.apple.Music` — read/write Music.app library
- `com.apple.security.network.client` — outbound API requests (MusicBrainz, Discogs)
- `com.apple.developer.ubiquity-kvstore-identifier` — iCloud KVS for free track counter

## Key Design Decisions

1. **MusicKit reads + AppleScript writes**: Music.app API is read-only; writes go through NSUserAppleScriptTask
2. **NSUserAppleScriptTask**: Apple's mechanism for sandboxed apps to run AppleScript (scripts in ~/Library/Application Scripts/)
3. **Hybrid cache**: SwiftData for track state (SwiftUI integration), GRDB for API cache (raw speed)
4. **Three-layer types**: Track (domain) / PersistedTrack (SwiftData) / DTO (Codable) — prevents persistence leaking into business logic
5. **nil trackStatus = available**: MusicKit tracks often lack status; they must NOT be filtered out

## Common Pitfalls

- **Forgetting `public`**: SPM enforces access control. If a type is used in another package, it must be `public`.
- **Track namespace collision**: `MusicKit.Track` vs `Core.Track` — always qualify with `Core.Track` in Services.
- **sanitizeScriptCode on data**: This strips `(){}` — never use on track/artist/album names.
- **`.public` in logs**: Never log user music data as `.public` — use `.private`.
- **nil trackStatus filtering**: `filterAvailableTracks` must return `true` for `nil` status (not `false`).
- **ISO8601DateFormatter not Sendable**: Swift 6 strict concurrency — use `nonisolated(unsafe)` with safety comment. `DateFormatter` IS Sendable.
- **xcodebuild requires signing override**: Entitlements trigger mandatory signing. Add `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO`.
- **Agent review false positives**: Always verify review findings against actual code before fixing — reviews are heuristic, not authoritative.

### Tool Integration Pitfalls

- **SwiftFormat + Swift 6 actors**: `--self remove` breaks actor autoclosures (os.Logger interpolation requires explicit `self.`). Use `--self init-only` and `--disable redundantSelf`.
- **SwiftFormat + SwiftLint modifier_order**: SwiftFormat puts `private nonisolated`, SwiftLint requires `nonisolated private`. Disable `modifierOrder` in `.swiftformat`.
- **SwiftFormat CLI syntax**: Paths BEFORE flags — `swiftformat App ... --lint`, NOT `swiftformat --lint App ...`.
- **Periphery + SPM**: No `--targets` flag. Use per-package scanning: `cd Packages/$pkg && periphery scan`.
- **Periphery false positives**: Always use `--retain-public` (phased dev) and `--retain-codable-properties` (GRDB/SwiftData models).
- **Periphery inline ignore**: `// periphery:ignore` does NOT work for "assign-only property" warnings — use global flags instead.
- **Periphery ignore on referenced symbols**: `// periphery:ignore` is superfluous for protocol methods with conforming implementations — use `_ paramName` in implementations instead.
- **macOS CI runners lack GNU coreutils**: `timeout` command unavailable — use bash background process + kill pattern.
- **swift test hangs on CI**: SwiftData prevents clean exit on headless runners — ci.yml uses background process with 120s kill timeout.

## Phase Status

| Phase | Status | Key Files |
|-------|--------|-----------|
| 1: Foundation | ✅ Done | 24 files, 2,893 LOC |
| 1.5: Hotfix | ✅ Done | Entitlements, TrackStatus, InputSanitizer, AppleScriptBridge, Logging |
| 2A: Persistence | ✅ Done | GRDB cache, SwiftData store, ProgressUpdate |
| 2B: Monetization | ✅ Done | Tier, AppFeature, SubscriptionService, FeatureGate, StoreKit Config |
| 3: Core Algorithms | ✅ Done | Normalization, ScriptDetector, MetadataUtils, AlbumType, AlbumMatcher, ArtistMatcher, GenreDeterminator, YearScorer, YearValidator, YearFallbackStrategy, YearDeterminator |
| 4: API + Cache | ✅ Done | TokenBucketRateLimiter, MusicBrainzClient, DiscogsClient, AppleMusicSearchClient, KeychainHelper, APIOrchestrator, GRDBCacheService (bulk+stats) |
| 5: Workflows | ✅ Done | ChangePreviewPipeline, CheckpointManager, UndoCoordinator, BatchProcessor, UpdateCoordinator, LibrarySyncService |
| 6: Views + Polish | ✅ Done | 20 files, ~3,100 LOC — UpdateView, BatchView, ReportsView, SettingsView (4 tabs incl. Appearance), SubscriptionView, FeatureGatedView, SharedUI components (ConfidenceBadge, ProgressRing, EmptyStateView, TierBadge, PaywallOverlay, TrackRow, TrackDetailView, ReportsChangeLog, ReportsCharts), ViewModels (UpdateViewModel, BatchViewModel), AppDependencies wiring |
| 7: Launch | 🔄 Active | Testing (418+316 tests), CSVExporter, DryRunReport, GenreMappings, Keyboard Shortcuts, Accessibility, Integration Tests, UI Tests, Entitlements CI, Coverage enforcement |

## Development Workflow

### Source of Truth Hierarchy

Documentation authority flows top-down — conflicts resolve in favor of the higher source:

1. **PRD** (`docs/plans/PRD.md`) — product requirements, features, business rules
2. **TDD** (`docs/plans/TDD.md`) — technical design, architecture decisions, patterns
3. **Task Files** (`docs/tasks/phase-*.md`) — per-phase deliverables with checkboxes
4. **CLAUDE.md** — project instructions, coding patterns, Phase Status table

When a decision is made during implementation that contradicts a higher-level doc, update the higher-level doc first, then propagate downward.

### Phase-Driven Development

- **Always know your phase**: Check `docs/tasks/` for the file with `status: active` (or first `planned`)
- **Read before coding**: Before starting work, read the current phase task file AND relevant TDD sections
- **One phase at a time**: Don't implement Phase 4 deliverables while Phase 2 is active
- **Phase transitions**: A phase is complete only when ALL checkboxes are checked AND build/tests pass
- **Status updates**: When a phase completes, update its frontmatter `status: done` and set the next phase to `status: active`

### Task Tracking Standards

Task files in `docs/tasks/phase-*.md` follow this structure:
- **Frontmatter**: `phase`, `title`, `status` (planned/active/done), `priority`, `depends_on`
- **Deliverables**: Grouped by component, each item is `- [ ]` or `- [x]`
- **Files table**: Lists all files created/modified in the phase
- **Acceptance criteria**: At the bottom, conditions that must pass before phase completion

When working on code:
- Check off `- [x]` each deliverable as you complete it
- Add new files to the Files table immediately after creation
- If a deliverable splits into sub-tasks, add them as indented checkboxes

### Documentation Sync Rules

| Change Type | Update Required |
|-------------|----------------|
| New file created | Add to task file Files table |
| Deliverable completed | Check off in task file |
| Architecture pattern changed | Update TDD.md |
| New feature/requirement | Update PRD.md |
| Phase completed | Update CLAUDE.md Phase Status + PRD.md Phase checkboxes & Overview |
| Build dependency added | Update CLAUDE.md Dependencies section + TDD.md |
| Any Swift file in commit | Must include docs/ or CLAUDE.md in staged files (hook-enforced) |

### Custom Agents

Project-local agents in `.claude/agents/` (gitignored — not in repo, set up manually per machine; discovered at session start, restart required after changes):

| Agent | Scope | Overrides Built-in? |
|-------|-------|---------------------|
| `swift-expert` | Non-UI Swift: concurrency, protocols, SPM, testing, domain logic | Yes |
| `swiftui-expert` | SwiftUI views, state management, animations, navigation, Liquid Glass | No (new type) |
| `scrum-master` | Read-only project auditing, sprint planning, docs consistency | No (new type) |

- `swiftui-expert` has 14 reference files in `.claude/agents/swiftui-references/`
- `swift-expert` delegates SwiftUI work to `swiftui-expert` and vice versa
- Agent placement: ONLY project-local `.claude/agents/` works — global `~/.claude/agents/` is inert
- Based on [AvdLee/SwiftUI-Agent-Skill](https://github.com/AvdLee/SwiftUI-Agent-Skill) v1.1.2

#### Scrum Master Usage

Use `@scrum-master` for project auditing:
- **Status check**: "What's the current project status?" — phase progress with % completion
- **Consistency audit**: "Check docs consistency" — cross-reference PRD/TDD/tasks/CLAUDE.md
- **Sprint planning**: "What should I work on next?" — prioritized deliverables in dependency order
- **Phase gate**: "Is Phase N ready to close?" — acceptance criteria verification
- **Gap analysis**: "Find documentation gaps" — staleness, missing files, broken links

The agent is read-only and never modifies code or documentation.

### Claude Code Hooks

Quality gates in `.claude/hooks/`, enforced automatically. All hooks use `jq` (not python3), never `set -e`, always output valid JSON, always `exit 0`.

| Hook | Event | Type | Fail-safe | What it does |
|------|-------|------|-----------|-------------|
| `commit-docs-sync-check.sh` | PreToolUse (Bash) | Blocking | DENY | Any `git commit` with Swift files requires docs staged |
| `swiftlint-precommit-check.sh` | PreToolUse (Bash) | Blocking | DENY | Runs SwiftLint --strict on staged Swift files before commit (matches CI) |
| `pre-push-tests.sh` | PreToolUse (Bash) | Blocking | DENY | Runs `swift test` for Core + Services before `git push` |
| `swift-task-tracking-reminder.sh` | PreToolUse (Edit/Write) | Advisory | ALLOW | Reminds to update task checkboxes when editing `.swift` |
| `session-start-phase-context.sh` | SessionStart | Advisory | ALLOW | Loads current phase progress at session start |

Shared library: `lib/common.sh` — `hook_read_stdin`, `hook_parse_field`, `hook_allow`/`hook_deny`/`hook_skip`, ERR traps.
Test suite: `test-hooks.sh` — 18 tests, run with `bash .claude/hooks/test-hooks.sh`.
