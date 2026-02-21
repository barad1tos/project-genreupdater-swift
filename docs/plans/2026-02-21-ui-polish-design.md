# UI Polish Design — Dynamic Titles, Transitions, Performance

**Date:** 2026-02-21
**Approach:** A+ (Minimal refactoring + debounce search)
**Scope:** ~5 files in App/Views/, no architectural changes

## Context

App runs with 38K tracks. Key issues identified during first launch:
1. Static title "Genre Updater" — doesn't reflect current section
2. Genre Update ↔ Year Update switching has no visual distinction
3. Content transitions are abrupt (no animation)
4. By Artist / By Album views lag due to eager grouping of 38K tracks
5. Track counter in toolbar looks misplaced

## Design

### 1. Dynamic Titles + Visual Feedback

Add `.navigationTitle()` to content area, reactive to `selectedCategory`:
- Library → "Library"
- By Artist → "By Artist"
- By Album → "By Album"
- Genre Update → "Genre Update"
- Year Update → "Year Update"
- Batch → "Batch Processing"
- Reports → "Reports"

For Genre/Year Update: add a header banner above the track list with icon
and short description to visually distinguish the two modes.

Move track count to `.navigationSubtitle()` with `formatted()` for proper
thousands separator.

### 2. Smooth Transitions

- `.animation(.easeInOut(duration: 0.2), value: selectedCategory)` on content
- `.transition(.opacity)` for each content view in switch
- `.contentTransition(.interpolate)` for sidebar selection

### 3. Performance (38K tracks)

- **Debounced search**: replace direct `searchText` binding with 300ms debounce
  to avoid filtering 38K tracks on every keystroke
- **Lazy grouping**: compute artist/album groups once, cache in `@State`,
  recompute only when `filteredTracks` changes
- **LazyVStack**: replace DisclosureGroup-based grouped views with LazyVStack
  for proper virtualization
- **Incremental rendering**: show first 100 groups, load more on scroll

### 4. Layout Polish

- Remove ToolbarItem for track counter (redundant with navigationSubtitle)
- Format count with `formatted()` for locale-aware thousands separator

## Files to Change

| File | Changes |
|------|---------|
| `App/Views/MainView.swift` | navigationTitle, navigationSubtitle, transitions, debounce |
| `App/Views/MainView.swift` | Grouped views refactor (LazyVStack + caching) |
| `App/Views/UpdateView.swift` | Header banner for Genre/Year distinction |
| `App/Views/SettingsView.swift` | No changes needed |

## Out of Scope

- Dark/light theme (follows system)
- Custom sidebar styling
- Full navigation rewrite
