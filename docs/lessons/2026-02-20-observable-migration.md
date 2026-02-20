# Lessons Learned: @Observable Migration & Code Review Fixes

## Summary
| Metric | Value |
|--------|-------|
| Total time | ~20 minutes |
| Optimal time | ~12 minutes |
| Waste ratio | ~1.7x |
| Key insight | Swift 6 strict concurrency treats Foundation formatters inconsistently: `DateFormatter` is Sendable, `ISO8601DateFormatter` is NOT — always test-build before committing static formatter caches |

## What Happened
Applied 4 Critical + 1 High fixes from agent code review. The @Observable migration (4 files) was mechanical and succeeded first try. DateFormatter caching hit Swift 6 strict concurrency: `ISO8601DateFormatter` required `nonisolated(unsafe)`, while `DateFormatter` was already `Sendable` (adding `nonisolated(unsafe)` to it produced a warning). One review finding (C4: @State without private) was a false positive — all @State properties were already private.

## Critical Mistakes

1. **Applied `nonisolated(unsafe)` to both formatters without checking Sendable conformance** (~2 min)
   - `DateFormatter` is already `Sendable` on macOS 15 SDK — the annotation was unnecessary and produced a warning
   - Fix: Check Sendable conformance of each type before applying concurrency annotations

2. **Didn't validate C4 finding before creating a task for it** (~1 min)
   - The review flagged "@State var without private" but all @State in the actual code was already `private`
   - Fix: Always read the actual code before accepting a review finding — agent reviews can produce false positives

3. **First xcodebuild attempt failed on signing** (~2 min)
   - Entitlements require signing certificate; CI/local needs `CODE_SIGNING_ALLOWED=NO`
   - Fix: Use `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` for unsigned builds

## Patterns Identified

| Pattern | Recognition Signal | Correct Response |
|---------|-------------------|------------------|
| Foundation Sendable Inconsistency | Caching Foundation formatters as `static let` in Swift 6 | Check each type's Sendable conformance individually — don't assume related types have same status |
| Agent Review False Positive | Review finding about code style/annotation | Read the actual code before acting — reviews are heuristic, not authoritative |
| @Observable Migration Path | Need to modernize ObservableObject-based state | Mechanical: remove @Published, swap wrappers, swap injection — always follow the full chain (class → creation site → all consumers) |
| xcodebuild Signing in CI | xcodebuild fails with "requires signing" | Add `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` |

## Actionable Rules

```
WHEN caching Foundation formatters as static let in Swift 6
THEN check Sendable conformance per-type — `DateFormatter` is Sendable, `ISO8601DateFormatter` is NOT
BECAUSE Foundation types have inconsistent Sendable adoption, blanket `nonisolated(unsafe)` produces warnings
```

```
WHEN applying code review findings
THEN read the actual current code for each finding before creating fix tasks
BECAUSE agent reviews can produce false positives (e.g. flagging "@State without private" when all @State are already private)
```

```
WHEN migrating ObservableObject → @Observable
THEN follow the complete chain: class definition → creation site → all consumer views
BECAUSE missing any consumer leaves @EnvironmentObject referencing a type no longer conforming to ObservableObject
```

```
WHEN building with xcodebuild in non-signing context
THEN add CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
BECAUSE entitlements trigger mandatory signing that fails without a certificate
```

```
WHEN using nonisolated(unsafe) on a static property
THEN document the safety invariant (why concurrent access is safe) in a comment above
BECAUSE CLAUDE.md requires documented safety invariants for all nonisolated(unsafe) usage
```

## Checklist: @Observable Migration

- [ ] Replace `ObservableObject` conformance with `@Observable` macro
- [ ] Remove all `@Published` property wrappers
- [ ] Keep `@MainActor` if no default actor isolation (or project targets < Swift 6.1)
- [ ] Replace `@StateObject` with `@State` at creation site
- [ ] Replace `.environmentObject()` with `.environment()` at injection site
- [ ] Replace `@EnvironmentObject var x: Type` with `@Environment(Type.self) private var x` at all consumers
- [ ] Search for ALL `@EnvironmentObject.*TypeName` across codebase (not just known files)
- [ ] Build incrementally (package → app) to catch concurrency issues early
- [ ] Run full test suite

## Checklist: Static Formatter Caching (Swift 6)

- [ ] Use `private enum` namespace for related formatters
- [ ] Check Sendable conformance of each formatter type
- [ ] Add `nonisolated(unsafe)` only for non-Sendable types
- [ ] Add safety invariant comment explaining why concurrent access is safe
- [ ] Build and verify no warnings from unnecessary `nonisolated(unsafe)`

## Additions to Project Docs

### CLAUDE.md — add to Build & Test:
- `xcodebuild` requires `CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO` for unsigned builds

### CLAUDE.md — add to Common Pitfalls:
- `ISO8601DateFormatter` is NOT Sendable in Swift 6 — use `nonisolated(unsafe)` with safety comment
- `DateFormatter` IS Sendable — no `nonisolated(unsafe)` needed
- Agent review findings can be false positives — always verify against actual code before fixing
