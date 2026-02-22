# Technology Stack

**Analysis Date:** 2026-02-22

## Languages

**Primary:**
- Swift 6.0 — all application code, enforced via `SWIFT_VERSION = "6.0"` in `project.yml` and `swift-tools-version: 6.0` in all `Package.swift` files
- AppleScript — Music.app write bridge; 5 scripts compiled at build time via `osacompile` in `Resources/Scripts/`

**Secondary:**
- Bash — CI helper scripts, justfile recipes, hook scripts in `.claude/hooks/`
- Python 3 — used only in `Justfile` and `ci.yml` for JSON coverage-report parsing (one-liners only, not application code)

## Runtime

**Environment:**
- macOS 15.0+ (Sequoia) — deployment target set in `project.yml` (`MACOSX_DEPLOYMENT_TARGET: "15.0"`) and all three `Package.swift` platforms declarations (`.macOS(.v15)`)
- Mac App Store distribution — sandboxed with explicit entitlements

**Concurrency Model:**
- Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY: complete`) — all actors and `Sendable` conformances enforced at compile time
- `@Observable` macro (iOS 17+/macOS 14+ backport not needed — minimum is macOS 15)
- `async/await` throughout; no completion handlers

## Frameworks

**Core (Apple):**
- MusicKit — read-only Music library access and catalog search (`Packages/Services/Sources/Services/MusicLibraryReader.swift`, `AppleMusicSearchClient.swift`)
- SwiftUI — entire UI layer (`App/Views/`, `Packages/SharedUI/`)
- SwiftData — track processing state persistence (`Packages/Services/Sources/Services/Persistence/SwiftData/`)
- StoreKit 2 — subscription management (`Packages/Services/Sources/Services/Subscription/SubscriptionService.swift`)
- OSLog / Unified Logging — structured logging throughout all packages (`Packages/Core/Sources/Core/Infra/Logging.swift`)
- Network framework — `NWPathMonitor` for reachability (`Packages/Services/Sources/Services/Network/NetworkReachabilityMonitor.swift`)
- Security framework — Keychain API token storage (`Packages/Services/Sources/Services/API/KeychainHelper.swift`)
- Carbon.OpenScripting — AppleScript event constants for `NSUserAppleScriptTask` (`Packages/Services/Sources/Services/Apple/AppleScriptBridge.swift`)
- Foundation — throughout; URLSession for HTTP, URLComponents for URL building

**Build/Toolchain:**
- XcodeGen 2.x — generates `GenreUpdater.xcodeproj` from `project.yml` (declarative project spec)
- Swift Package Manager (SPM) — manages the three local packages and the GRDB external dependency
- Xcode 26.2 / Xcode 16.0 minimum (CI config specifies `xcodeVersion: "16.0"` in `project.yml`)

## Key Dependencies

**External (Third-Party):**

| Package | Version | Purpose | Location |
|---------|---------|---------|----------|
| GRDB.swift | 7.10.0 (resolved) / `from: "7.0.0"` | SQLite-backed API response cache with `DatabasePool` for concurrent reads | `Packages/Services/Package.swift` |

No other third-party dependencies. The entire stack is Apple frameworks + one SQLite ORM.

**Local Packages:**

| Package | Path | External Deps | Role |
|---------|------|---------------|------|
| Core | `Packages/Core/` | None | Domain logic, models, algorithms |
| Services | `Packages/Services/` | Core, GRDB | APIs, persistence, Apple Music integration |
| SharedUI | `Packages/SharedUI/` | Core | Reusable SwiftUI components |

## Configuration

**Environment:**
- No `.env` files — all configuration is JSON-backed via `AppConfiguration` (`Packages/Core/Sources/Core/Config/`)
- Discogs API token stored in macOS Keychain (service: `com.genreupdater.discogs`)
- iCloud KVS for free-tier track counter (`NSUbiquitousKeyValueStore`)
- API cache at `Application Support/GenreUpdater/api_cache.db` (SQLite via GRDB)
- SwiftData store created via `ModelContainerFactory` (`Packages/Services/Sources/Services/Persistence/SwiftData/ModelContainerFactory.swift`)

**Build:**
- `project.yml` — XcodeGen spec (single source of truth for Xcode project)
- `Packages/*/Package.swift` — per-package SPM manifests
- `.swiftlint.yml` — SwiftLint rule configuration (120 char line limit, force_unwrap = error)
- `.swiftformat` — SwiftFormat configuration (Swift 6.0, 4-space indent, 120 char width)
- Post-build script in `project.yml` compiles `.applescript` → `.scpt` via `/usr/bin/osacompile`

**Sandbox:**
- Debug: sandbox disabled (`ENABLE_APP_SANDBOX: false`)
- Release: sandbox enabled with entitlements from `App/GenreUpdater.entitlements`

## Dev Tooling

| Tool | Version | Installed Via | Purpose |
|------|---------|---------------|---------|
| just | 1.46.0 | Homebrew | Local CI task runner (`Justfile`) |
| SwiftLint | 0.63.2 | Homebrew | Lint enforcement (pre-commit hook + CI) |
| SwiftFormat | 0.59.1 | Homebrew | Auto-formatting and format checking |
| Periphery | 3.6.0 | Homebrew | Dead code detection |
| xcrun llvm-cov | Xcode bundled | Xcode | Coverage report generation |
| GitHub Actions | — | GitHub | CI pipeline (`.github/workflows/ci.yml`) |

## CI Pipeline

**Local:** `just ci` runs: `build → test → coverage → entitlements → lint → format → periphery`

**Remote:** `.github/workflows/ci.yml` on `macos-15` runner, triggers on push to `main`/`dev` and PRs to `main`

Coverage thresholds enforced:
- Core package: ≥ 85% line coverage
- Services package: ≥ 65% line coverage

## Platform Requirements

**Development:**
- macOS 15.0+ (required to run SwiftData + `@Observable`)
- Xcode 26.2 (current dev environment; project specifies Xcode 16.0 minimum)
- Homebrew for lint/format tools

**Production:**
- macOS 15.0+ (Sequoia)
- Mac App Store — sandboxed (`com.apple.security.app-sandbox`)
- Requires Music.app to be running for write operations
- Requires MusicKit authorization from user

---

*Stack analysis: 2026-02-22*
