# Phase 5: Dashboard Redesign - Context

**Gathered:** 2026-02-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Redesign the Dashboard to be a compelling, calm first impression. Replace the prototype GaugeView with HeroGauge, add cached-first metrics loading, smart quick-actions with live counts, and skeleton shimmer for first launch. The Dashboard shows library health state without pressure — users browse it with curiosity, not urgency.

</domain>

<decisions>
## Implementation Decisions

### Gauge Hero Section
- Center content: large track count number ("38,247") with "tracks" label underneath — focus on library size
- Legend: compact inline legend always visible below gauge (colored dots + labels: Genre 85%, Year 72%, Consistency 90%), plus hover on any arc reveals extended details (e.g. "Genre: 1,234 of 1,450 tagged")
- Size: dominant, approximately 40% of content width (~280–320pt) — the first thing visible on the Dashboard
- Arc layout: stacked segments on very close radii with subtle shadow between layers (layered depth effect, not concentric rings) — feels like physical layers with slight z-separation
- Arc colors: Ayu semantic palette — Genre = Ayu.purple, Year = Ayu.info, Consistency = Ayu.accent (consistent with existing app color usage)
- Consistency metric: percentage of tracks where BOTH genre AND year are filled — fully processed tracks
- Click behavior: clicking on an arc navigates to the relevant screen (genre/year arcs → Update)
- Title above gauge: Claude's Discretion — decide based on visual balance whether a "Library Health" title is needed or if gauge + legend are self-explanatory
- Animation: static fill values in Phase 5, draw-in animation deferred to Phase 8
- Top Genres section: REMOVED from Dashboard, moved to Reports screen

### Metric Cards
- Card set: 3 cards (NOT 4) — Need Genre, Need Year, Recently Added. Track count already in gauge center, no duplication
- Layout: single row of 3 cards below the gauge
- Style: minimal with trend indicator — arrow only (↑ ↓ =) visible by default, hover reveals delta number (e.g. "+12 since last scan")
- Trend baseline: compared to previous scan — requires persisting a metrics snapshot in SwiftData
- Clickable: all cards navigate (Need Genre → Update, Need Year → Update, Recently Added → Browse with "Recently Added" filter)
- Hover/press: combined elevation (shadow + subtle scale) + accent border glow — must be CONSISTENT with press/hover patterns across the entire app (same timing, same easing, same feel as list rows and other interactive elements)
- Design consistency: all interactive elements in the app must share consistent animation language — same curves, same durations, same feedback patterns

### Quick Actions
- Philosophy: soft shortcuts, not urgency-driven CTAs. Dashboard shows library STATE, does not pressure. User browses with curiosity and can navigate easily
- Tone: neutral labels with context (e.g. "Genre · 327 untagged") — informative, not "Fix Now!"
- Format and design: Claude's Discretion — must be soft, unobtrusive, consistent with the rest of Dashboard, and complementary to metric cards
- Live counts: derived from actual library state, update after background scan completes
- Zero-count actions: always show all actions even when count is 0 (display checkmark for completed states, e.g. "✓ All genres tagged")

### Loading & Empty States
- First launch (no cache): full shimmer on ALL Dashboard elements — gauge, metric cards, quick actions. Shape-matching shimmer (half-circle for gauge, rectangles for cards)
- Long load (>3 seconds): add progress text below gauge ("Loading library... 12,340 / 38,247") — only appears after 3s threshold
- Cache-to-live transition: subtle "Updating..." indicator at top, numbers animate smoothly from cached to live values
- Data refresh: auto-scan on app launch, cached data as immediate fallback, quiet footer timestamp ("Updated 2 min ago")
- Empty library (0 tracks): friendly illustration/icon + soft message "Ви можливо хочете додати музику в Music.app?" with a shortcut button to open Music.app
- MusicKit permission denied: clear permission prompt + "Open Settings" button to grant access
- Adaptive layout: cards reflow responsively on window resize (3 in row → 2+1 → stacked)

### Claude's Discretion
- Quick actions visual format and exact component design (soft, unobtrusive, complementary)
- Whether a title ("Library Health") appears above the gauge
- Exact spacing and typography between sections
- Shimmer timing and animation parameters
- Error state handling for failed scans
- Footer timestamp exact position and style

</decisions>

<specifics>
## Specific Ideas

- Dashboard should feel like a calm observatory — "стан роботи системи" (system health overview), not a task manager
- All animations must be consistent across the ENTIRE app — same curves, same durations, same feedback for hover/press everywhere
- Design must be "symmetrical, informative, and elegant"
- Quick actions are complementary to metric cards, not redundant
- Trend arrows show direction at a glance, hover reveals the delta number — progressive disclosure

</specifics>

<deferred>
## Deferred Ideas

- Customizable Dashboard layout — let users rearrange/hide Dashboard sections (future milestone)
- Draw-in animation for gauge arcs — Phase 8
- Top Genres chart — moved to Reports (Phase 7)
- Numeric text content transitions for cached → live values — Phase 8

</deferred>

---

*Phase: 05-dashboard-redesign*
*Context gathered: 2026-02-23*
