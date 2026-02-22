# Phase 1: Design System Foundation - Context

**Gathered:** 2026-02-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Extend the SharedUI token layer with Shadow and Motion enums, fix Ayu light-mode contrast to WCAG AA, and set minimum/default window dimensions. No new screens or components — tokens only. Everything downstream reads from these values.

</domain>

<decisions>
## Implementation Decisions

### Shadow Tokens
- 4 elevation levels: subtle (cards), medium (dropdowns/popovers), elevated (modals/sheets), floating (drag-and-drop, tooltips)
- Color-tinted shadows using Ayu accent color for brand identity
- Inner shadows for pressed/inset button states
- Soft/diffuse spread style (Apple/Spotify aesthetic — large blur radius, wide spread)

### Motion Tokens
- Duration scale in the 200-400ms range (Spotify-style — noticeable but not slow)
- Bezier easing curves (easeInOut/easeOut), not spring-based
- Motion applies to all 4 interaction types: hover states, press feedback, view transitions, data loading animations
- Respect macOS "Reduce motion" accessibility setting — disable animations when enabled, use instant transitions instead

### Color Corrections
- fgPrimary (0x5C6166) must be darkened minimally to pass WCAG AA (≥4.5:1) on light background (0xFCFCFC) — preserve Ayu feel as close as possible
- fgSecondary (0x8A9199) also needs darkening — currently too faint in light mode for caption text
- Orange accent (0xFFAA33 light / 0xFFCC66 dark) is the primary brand color — do not change
- Dark mode (Ayu Mirage) palette is solid — no changes needed
- Ayu/Ayu Mirage color identity must be preserved throughout — extend, don't replace

### Spacing and Density
- Current 10-step spacing scale (4→64pt) is adequate — no changes needed
- Standard list row density: 40-44pt height (Spotify/Doppler style, mouse-optimized)
- Current 8 font tokens (display through metricSmall) are sufficient — no additions
- Minimum window width: 900pt (prevents layout collapse)
- Default window size on first launch: 1280x800 (generous, close to Spotify default)

### Claude's Discretion
- Exact hex values for corrected fgPrimary and fgSecondary (within constraint: minimal darkening to pass WCAG AA)
- Exact shadow blur radius and offset values per elevation level
- Specific bezier curve parameters (control points)
- Whether to add a Spacing.row constant (40-44pt) or handle row height in components

</decisions>

<specifics>
## Specific Ideas

- "Мені подобається візуальна стилістика кольорів Ayu / Ayu Mirage — їх варто залишити і танцювати навколо цієї гамми"
- Shadows should be Ayu accent-tinted (not generic black) to reinforce brand identity in both themes
- Row density of 40-44pt is a token-level decision that applies consistently to Browse artist rows, track rows, and report log entries

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-design-system-foundation*
*Context gathered: 2026-02-22*
