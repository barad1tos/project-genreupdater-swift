# Lessons Learned: First Green CI Pipeline

## Summary

| Metric | Value |
|--------|-------|
| Total time | ~45 min |
| Optimal time | ~15 min |
| Waste ratio | 3x |
| Key insight | CI had never run to completion; each fix exposed the next blocker |

## What Happened

A 1-line Keychain fix (add `kSecAttrAccessible`) triggered a cascade of CI failures that had
always been hidden by earlier blockers (billing limit, test hang). Each fix revealed the next
layer: billing -> test hang -> missing GNU `timeout` -> Periphery dead code -> superfluous
`periphery:ignore`. Six commits squashed into one after full pipeline passed.

## Chronology

| # | Approach | Result | Pivot Trigger |
|---|----------|--------|---------------|
| 1 | Add `kSecAttrAccessible` to KeychainHelper | pass (local) | CI blocked by billing |
| 2 | Rerun CI after billing fix | fail | `swift test` hangs indefinitely on macOS runner |
| 3 | Add `security unlock-keychain` + `timeout-minutes` | fail | Tests pass but process never exits |
| 4 | Wrap `swift test` with GNU `timeout` command | fail | `timeout: command not found` on macOS |
| 5 | Replace with background process + kill loop | pass | Periphery --strict finds 11 dead code warnings |
| 6 | Remove unused params from protocol + implementations | reverted | User: params are for Phase 5, don't delete |
| 7 | Use `_` internal names + delete unused struct | fail | `periphery:ignore` on protocol is superfluous |
| 8 | Remove superfluous comment | pass | Full CI green |

## Critical Mistakes

1. **Assumed GNU coreutils on macOS CI**: `timeout` is GNU, macOS has BSD userland.
   Used `timeout` without checking availability -> wasted a commit+push cycle.
   Fix: always use POSIX-compatible constructs in CI for macOS runners.

2. **Removed protocol params without consulting user**: YAGNI instinct overrode
   design intent. User correctly pushed back - params were Phase 5 placeholders.
   Fix: ask before removing forward-looking API surface.

3. **Added `periphery:ignore` without testing locally**: Periphery treats referenced
   declarations as superfluous-to-ignore. Should have run `periphery scan` locally first.
   Fix: always verify Periphery behavior locally before pushing ignore comments.

4. **Didn't anticipate CI cascade**: The 1-line fix was correct but CI had never run
   past billing errors. Should have checked CI history first to set expectations.
   Fix: check `gh run list` history before assuming CI will "just pass."

## Patterns Identified

- **Onion CI failures**: When CI has been broken for a while, fixing one layer exposes
  the next. Each step (build -> test -> lint -> Periphery) can independently fail.
  Recognition: CI runs that always failed early (billing, timeout, missing tool).
  Response: expect multiple iterations, don't promise "one more fix."

- **macOS CI != local macOS**: GitHub Actions macOS runners have BSD userland (no GNU
  `timeout`), Keychain may need explicit unlock, `swift test` can hang on process exit.
  Recognition: any shell command that works locally but targets CI macOS runner.
  Response: use POSIX or built-in bash constructs, never assume GNU tools.

- **swift test hang on CI**: SwiftData ModelContainer or similar resources prevent
  clean process exit after all tests pass. Tests succeed but runner never terminates.
  Recognition: CI log shows all tests passed, then silence until timeout.
  Response: background the test process, poll with kill timeout.

## Actionable Rules

```
WHEN writing shell commands for macOS CI runners
THEN use POSIX/bash builtins only (no timeout, no gtimeout, no GNU tools)
BECAUSE macOS runners ship BSD userland, not GNU coreutils
```

```
WHEN CI has been failing/cancelled for multiple runs
THEN expect cascading failures across pipeline stages
BECAUSE each stage may have untested issues hidden behind earlier failures
```

```
WHEN swift test passes but process hangs on CI
THEN use background process + polling kill pattern (not GNU timeout)
BECAUSE SwiftData cleanup can prevent clean exit on headless runners
```

```
WHEN Periphery flags unused params in protocol conformances
THEN use `_ paramName` in implementations, NOT periphery:ignore on protocol
BECAUSE Periphery considers referenced protocol methods as "used" (ignore is superfluous)
```

```
WHEN considering removing forward-looking API parameters
THEN ask the user first - they may be intentional placeholders
BECAUSE YAGNI instinct can conflict with phased development design
```

## Checklist: CI Fix for macOS Swift Projects

- [ ] Check `gh run list` history - has CI ever passed?
- [ ] Verify shell commands use POSIX/bash builtins (no GNU tools)
- [ ] Add `security unlock-keychain` before Keychain-dependent tests
- [ ] Wrap `swift test` with timeout guard for SwiftData hang
- [ ] Run `periphery scan` locally before pushing ignore comments
- [ ] Run full lint pipeline locally: SwiftLint, SwiftFormat, Periphery
- [ ] If removing code: confirm with user whether it's intentional placeholder

## CLAUDE.md Updates Needed

Add to Common Pitfalls:
- **macOS CI runners lack GNU coreutils**: `timeout` command unavailable — use bash
  background process + kill pattern instead
- **swift test hangs on CI**: SwiftData prevents clean exit — ci.yml uses background
  process with 120s kill timeout
- **Periphery `periphery:ignore` on referenced symbols**: Comment is superfluous for
  declarations that have conforming implementations — use `_` in implementations instead
