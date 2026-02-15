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
│   │       ├── Infra/             # Logging (os.Logger)
│   │       └── Models/            # Track, Protocols, TrackStatus
│   ├── Services/                  # External world (APIs, Music.app, cache)
│   │   └── Sources/Services/
│   │       ├── Apple/             # AppleScriptBridge, InputSanitizer, ScriptInstaller
│   │       ├── MusicLibraryReader # MusicKit integration
│   │       └── Subscription/      # SubscriptionService, FeatureGate (StoreKit 2)
│   └── SharedUI/                  # Reusable SwiftUI components
├── Tests/                         # App-level tests
├── Resources/                     # AppleScript files, assets
├── docs/
│   ├── plans/                     # PRD.md, TDD.md
│   └── tasks/                     # Phase task files (phase-*.md)
├── .claude/
│   ├── hooks/                     # Claude Code quality gates
│   │   ├── lib/common.sh          # Shared helpers (jq-based, hardened)
│   │   ├── commit-docs-sync-check.sh  # Blocking: Swift commit → needs docs
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
- Use `static let` for DateFormatters — they're expensive to create:
  ```swift
  private static let isoFormatter: ISO8601DateFormatter = {
      let f = ISO8601DateFormatter()
      return f
  }()
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

## Build & Test

```bash
# Build all packages
cd Packages/Core && swift build
cd Packages/Services && swift build
cd Packages/SharedUI && swift build

# Run tests
cd Packages/Core && swift test
cd Packages/Services && swift test

# Full Xcode build
xcodebuild build -project GenreUpdater.xcodeproj -scheme GenreUpdater \
  -destination "platform=macOS,arch=arm64" -quiet

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

## Phase Status

| Phase | Status | Key Files |
|-------|--------|-----------|
| 1: Foundation | ✅ Done | 24 files, 2,893 LOC |
| 1.5: Hotfix | ✅ Done | Entitlements, TrackStatus, InputSanitizer, AppleScriptBridge, Logging |
| 2A: Persistence | ✅ Done | GRDB cache, SwiftData store, ProgressUpdate |
| 2B: Monetization | ✅ Done | Tier, AppFeature, SubscriptionService, FeatureGate, StoreKit Config |
| 3: Core Algorithms | Planned | Genre/Year determination |
| 4: API + Cache | Planned | MusicBrainz, Discogs, GRDB cache |
| 5: Workflows | Planned | Pipeline, Undo, Checkpoint |
| 6: Views | Planned | SwiftUI, VoiceOver |
| 7: Launch | Planned | Testing, App Store |

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

### Scrum Master Agent

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
| `swift-task-tracking-reminder.sh` | PreToolUse (Edit/Write) | Advisory | ALLOW | Reminds to update task checkboxes when editing `.swift` |
| `session-start-phase-context.sh` | SessionStart | Advisory | ALLOW | Loads current phase progress at session start |

Shared library: `lib/common.sh` — `hook_read_stdin`, `hook_parse_field`, `hook_allow`/`hook_deny`/`hook_skip`, ERR traps.
Test suite: `test-hooks.sh` — 18 tests, run with `bash .claude/hooks/test-hooks.sh`.
