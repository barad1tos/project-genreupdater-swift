# Phase 6: Browse Redesign - Context

**Gathered:** 2026-02-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Artist/Album/Track drill-down navigation with multi-select, debounced search, sticky section headers, and filter chips for a 38K+ track library (2,271 artists). Users can navigate hierarchies, select items for batch processing, and search with instant results — without lag or layout collapse.

</domain>

<decisions>
## Implementation Decisions

### Drill-down interaction
- Inline expand (disclosure style) — click artist row expands albums below it as indented sub-rows
- Multiple artists can be open simultaneously (NOT accordion)
- Click anywhere on artist row toggles expand/collapse (not just disclosure triangle)
- Album tracks show in right detail panel (NavigationSplitView third column) on album click
- Initial state: all artists collapsed; expanded state preserved on tab switch return
- Expand/collapse is instant (no animation) for snappy feel with 2,271 artists
- Prev/Next album arrows in detail panel header to cycle through albums within same artist
- Track rows in detail panel are selectable (click/Cmd+click) for per-track batch actions

### Detail panel states
- No album selected: muted HeroGauge watermark (brand identity), no text — interaction is discoverable
- Album selected: large album art header at top, artist name, album title, year, track count, then track list
- Album art source: MusicKit artwork URL preferred, styled placeholder fallback if unsigned builds can't access artwork (researcher to verify)

### Duplicate artist handling
- Variants grouped under canonical name (most common spelling)
- Primary name shown with variant count badge (e.g., "~2 var")
- Expanding shows variant names with per-variant track counts before album list
- Grouping uses existing ArtistMatcher normalization from Core

### Multi-select & bulk actions
- Modifier keys always active: Cmd+click toggles, Shift+click selects range
- Hover checkbox: invisible by default, checkbox appears at left edge on row hover (Finder-style)
- After Cmd+click or checkbox click, checkbox stays visible on selected rows
- Selection is artist/album-level — selecting artist means "all tracks for this artist" (no cascade sub-selection)
- Bulk action bar in top toolbar area (not floating bottom bar)
- Toolbar shows selection count + action buttons when items selected
- Actions: Update Genres, Update Years, Dry Run Preview, Clear Selection

### Search & filtering
- Single search field searches across artists, albums, AND tracks simultaneously
- Results grouped by type (Artists section, Albums section, Tracks section)
- Search replaces browse list (not overlay/popover). Clearing search restores browse state
- Clicking a search result: clears search, scrolls to that artist (expanded), selects album in detail panel
- Debounced search: 300ms debounce, computation off main thread
- Smart filter chips above list: "Missing Genre", "Missing Year", "Recently Added", "Updated Today"
- Multiple chips can be active simultaneously (AND logic)

### List density & visual style
- Artist rows: compact single-line by default with muted metadata indicators
- Hover-expand effect: row expands symmetrically (up + down) on hover, revealing full info at normal opacity
- Compact state shows: artist name, track count (muted), genre chip (muted), status dot (muted)
- Expanded hover state reveals: genre chip at full opacity, album count, readable tag status (e.g., "75% tagged"), last updated date
- Hover-expand animation: smooth height transition (~200ms, use Motion.curveFast)
- Album rows: name + year + track count in compact state, same hover-expand behavior as artist rows
- Sticky section headers: left-aligned floating letter (not full-width banner). Letter stays visible during scroll
- SectionIndexBar (A-Z sidebar): visible on hover/scroll only, hidden at rest
- Tag status indicator: color dots (green = all tagged, yellow = partial, red = mostly missing)
- No-results empty state: illustration + message + "Clear filters" button (use existing EmptyStateView)

### Track detail columns
- Track number + title (essential)
- Genre + Year tag values (shows filled vs missing)
- Tag status dot per track (green/yellow/red)
- No duration column (user didn't select it)

### Sorting
- Sort dropdown in toolbar: Name (default), Track Count, Tag Completion %
- Sort applies to the artist list view

### Keyboard navigation
- Basic only: Cmd+F focuses search, SwiftUI List default arrow key handling
- No custom keyboard shortcuts for browse navigation

</decisions>

<specifics>
## Specific Ideas

- Finder-style hover checkboxes for multi-select — invisible until hover, then appear at left edge of row
- HeroGauge as branded watermark in empty detail panel — muted, no text, just the gauge graphic
- "Traffic light" color dots for tag status: green (all tagged), yellow (partial), red (mostly missing)
- Left-aligned floating section letters (like macOS Finder sidebar groups), not full-width banners
- Artist rows use "reveal on hover" pattern — compact + muted at rest, expanded + vivid on hover
- Album art as large header in detail panel (Spotify/Apple Music album page style)

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 06-browse-redesign*
*Context gathered: 2026-02-23*
