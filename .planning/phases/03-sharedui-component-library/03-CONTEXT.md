# Phase 3: SharedUI Component Library - Context

**Gathered:** 2026-02-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Build all reusable UI components as independently previewable SwiftUI views in the SharedUI package: HeroGauge, StatCard, ArtistListRow, AlbumListRow, FilterChip, SectionIndexBar, and ShimmerPlaceholder. Each component must have correct hover, press, and focus states. Components accept plain data types (Double, String, Int) — no dependency on Track or other domain models. SwiftUI-Shimmer is the only new external dependency.

</domain>

<decisions>
## Implementation Decisions

### HeroGauge
- Concentric arcs layout (like Apple Fitness rings): 3 half-circle arcs at different radii — outer: genre, mid: year, inner: consistency
- Flat/butt caps on arc ends (not rounded) — technical, minimalist look
- Medium arc width (14-18pt) — balanced visual weight
- Subtle track background arc (semi-transparent 180° arc behind each layer showing the maximum)
- Ayu semantic colors: Genre = Ayu.accent (orange), Year = Ayu.success (green), Consistency = Ayu.info (blue)
- Center content is contextual/switchable: shows track count by default, shows layer-specific % coverage on hover over that arc
- Legend below gauge: colored dots + label + percentage for each layer (Genre 78% / Year 92% / Consistency 65%)
- Draw-in animation on appear: arcs fill from 0% to actual value when first shown
- API: accepts 3 Double values (0.0–1.0) for genre, year, consistency coverage + an Int for track count

### List Rows (ArtistListRow + AlbumListRow)
- ArtistListRow content: name (left) + album count badge + track count badge (right). Example: "Radiohead  12a  247t"
- AlbumListRow content: title (left) + genre badge (if present) + year (right). Example: "OK Computer  [Rock]  1997"
- Badge font: SF Mono (monospaced) for numeric badges — aligns in columns
- Row height: standard (44-48pt)
- No dividers between rows — spacing only (like Doppler/Spotify)
- Hover state: leading accent bar (thin vertical Ayu.accent stripe on left) + light background fill (like Slack selected channel)
- Press state: scale down to 0.98x — tactile iOS-like feedback
- Selected state: persistent accent bar + Ayu.accent.opacity(0.1) background — stays after click, needed for multi-select in Phase 6
- .contentShape(.rect) on all rows for macOS 15 scroll regression fix

### SectionIndexBar
- Smart mode: only shows letters that have corresponding artists (not full A-Z)
- Vertical bar on right side of list, drag scrolls to section
- Will handle 2,271 artists across ~26 alphabetical sections

### StatCard
- Floating card style: shadow.card + Ayu.bgSecondary background + rounded corners (Radius.md)
- Content: label (small text) + big number + mini progress bar below
- Mini progress bar animates width smoothly on data updates
- Hover state: shadow elevation (card → elevated) + Ayu.accent border appears simultaneously
- Press state: scale down 0.98x (consistent with list rows)

### FilterChip
- Squared tag style: Radius.sm rounding (not capsule)
- Active state: Ayu.accent background + white text
- Inactive state: border only (Ayu.fgMuted.opacity(0.3)) + Ayu.fgPrimary text
- Optional dismissable mode: shows xmark.circle for removing active filters
- Toggle animation: color cross-fade (~0.2s) between active/inactive states
- Press state: scale down 0.98x

### Claude's Discretion
- Exact spacing values within components (use DesignTokens Spacing)
- Font sizes for labels, numbers, badges (use DesignTokens AppFont)
- SectionIndexBar letter styling and spacing
- HeroGauge exact arc radii and gaps between concentric rings
- Progress bar height and corner radius inside StatCard
- Accessibility: VoiceOver labels and traits for interactive elements

</decisions>

<specifics>
## Specific Ideas

- HeroGauge should feel like Apple Fitness rings but in a half-circle — the concentric arcs with track background is key to that feeling
- List rows should be information-dense like Doppler but with the leading accent bar interaction from Slack
- StatCard floating cards with shadow elevation on hover give a "lifting" tactile quality
- All interactive components use consistent 0.98x scale-down for press — this creates a unified interaction language across the component library
- Genre badge on AlbumListRow uses the same ConfidenceBadge-style pill but with genre text

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 03-sharedui-component-library*
*Context gathered: 2026-02-22*
