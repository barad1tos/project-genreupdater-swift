---
phase: 01-design-system-foundation
plan: 01
subsystem: ui
tags: [swiftui, design-tokens, shadow, motion, animation, accessibility]

# Dependency graph
requires:
  - phase: none
    provides: "Existing DesignTokens.swift with Spacing, Radius, AppFont, Liquid Glass"
provides:
  - "Shadow enum with 5 elevation levels (subtle/medium/elevated/floating/inner)"
  - "ShadowToken struct for typed shadow application"
  - "Motion enum with 3 durations and 4 animation curves"
  - ".ayuShadow(_:) View extension"
  - ".motionAnimation(_:value:reduceMotion:) View extension with reduce-motion support"
affects: [02-ayu-color-system, 03-component-library, views, animations]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Caseless enum for design token namespaces (Shadow, Motion)"
    - "ShadowToken value type for multi-property shadow composition"
    - "Opaque generic parameter (some Equatable) over generic constraints"
    - "Reduce-motion accessibility gating via motionAnimation extension"

key-files:
  created: []
  modified:
    - "Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift"
    - "CLAUDE.md"

key-decisions:
  - "Used opaque generics (some Equatable) instead of <V: Equatable> per SwiftFormat opaqueGenericParameters rule"

patterns-established:
  - "Shadow tokens: caseless enum with ShadowToken struct, Ayu accent-tinted at varying opacities"
  - "Motion tokens: duration constants (0.2/0.3/0.4s) paired with named animation curves"
  - "Accessibility: motionAnimation extension gates animations on reduceMotion flag"

requirements-completed: [DSYS-02]

# Metrics
duration: 5min
completed: 2026-02-22
---

# Phase 01 Plan 01: Shadow + Motion Tokens Summary

**Shadow (5 elevations with Ayu accent tinting) and Motion (3 durations, 4 curves) design tokens with accessibility-aware View extensions**

## Performance

- **Duration:** 5 min
- **Started:** 2026-02-22T12:01:52Z
- **Completed:** 2026-02-22T12:07:12Z
- **Tasks:** 1
- **Files modified:** 2

## Accomplishments
- ShadowToken struct + Shadow enum with 5 elevation levels (subtle/medium/elevated/floating/inner), all Ayu accent-tinted
- Motion enum with 3 duration constants (200ms/300ms/400ms) and 4 animation curves (curveDefault/curveAppear/curveFast/curveEmphasis)
- `.ayuShadow(_:)` View extension replaces raw `.shadow(color:radius:x:y:)` calls
- `.motionAnimation(_:value:reduceMotion:)` View extension respects macOS "Reduce Motion" accessibility

## Task Commits

Each task was committed atomically:

1. **Task 1: Add Shadow and Motion tokens to DesignTokens.swift** - `4bfa8d4` (feat)

## Files Created/Modified
- `Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift` - Added ShadowToken struct, Shadow enum (5 levels), Motion enum (3 durations + 4 curves), ayuShadow and motionAnimation View extensions
- `CLAUDE.md` - Added SharedUI/Theme directory to project structure tree

## Decisions Made
- Used `some Equatable` (opaque generic parameter) instead of `<V: Equatable>` for `motionAnimation` — required by SwiftFormat `opaqueGenericParameters` rule and idiomatic in Swift 5.9+

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] SwiftFormat opaqueGenericParameters violation**
- **Found during:** Task 1 (commit attempt)
- **Issue:** Plan specified `<V: Equatable>` generic parameter; SwiftFormat requires `some Equatable` opaque parameter
- **Fix:** Changed `motionAnimation<V: Equatable>(_ animation:value:reduceMotion:)` to `motionAnimation(_ animation:value: some Equatable, reduceMotion:)`
- **Files modified:** `Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift`
- **Verification:** `swiftformat --lint` passes, `swift build --package-path Packages/SharedUI` succeeds
- **Committed in:** `4bfa8d4` (part of task commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Minor syntax adjustment required by project SwiftFormat config. No scope creep.

## Issues Encountered
- Pre-commit hook commit-msg gate required `codex-commit-style-marker` invocation before committing (project-specific workflow). Resolved by running the marker command.
- Pre-existing unstaged modifications to AyuColors.swift and GenreUpdater.entitlements were present in the working tree but were NOT included in this commit (out of scope for this plan).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Shadow and Motion tokens are ready for consumption by all downstream views
- The `.ayuShadow(_:)` extension is the canonical way to apply shadows going forward
- The `.motionAnimation(_:value:reduceMotion:)` extension should be used wherever animations are applied
- Next plan (01-02) can build on these tokens for component styling

## Self-Check: PASSED

- FOUND: `Packages/SharedUI/Sources/SharedUI/Theme/DesignTokens.swift`
- FOUND: `.planning/phases/01-design-system-foundation/01-01-SUMMARY.md`
- FOUND: commit `4bfa8d4` (feat(01-01): add Shadow + Motion tokens)

---
*Phase: 01-design-system-foundation*
*Completed: 2026-02-22*
