# Phase 2: Theme Switching - Context

**Gathered:** 2026-02-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Users can switch between dark and light themes via Settings; the preference persists across launches. All surfaces — main window, Settings window, AppKit sheets, date pickers — honor the selected theme. When set to System, the app tracks OS appearance changes in real time.

</domain>

<decisions>
## Implementation Decisions

### Picker placement
- New **Appearance** tab in Settings (4th tab, after Advanced)
- Tab icon: `paintbrush` or similar SF Symbol
- Appearance tab also includes a placeholder section for sidebar style (populated in Phase 4)

### Picker style
- Segmented picker with SF Symbol icons only — no text labels
- Three segments: `moon.fill` (Dark) / `circle.lefthalf.filled` (System) / `sun.max.fill` (Light)
- Compact, recognizable without text

### Color preview
- Small color swatch row beneath the picker showing bg + fg + accent colors for the selected theme
- Updates live as the user switches segments

### Default theme
- System mode at first launch — follows OS appearance out of the box

### System mode indicator
- No explicit "currently using Dark/Light" label — the user sees the app colors directly

### Transition behavior
- Animated cross-fade (~0.3s) for all theme changes — both manual switches in Settings and OS-driven changes
- Applies to all windows simultaneously (main window + Settings window)

### Scope of change
- Theme switch applies to the entire app immediately — sidebar, content area, Settings window, sheets, date pickers all change

### Claude's Discretion
- SF Symbol choices for tab icon and segment icons (exact names)
- Cross-fade animation implementation approach (preferredColorScheme + withAnimation, or NSAppearance transition)
- Color preview swatch layout and sizing
- Appearance tab layout for sidebar style placeholder section

</decisions>

<specifics>
## Specific Ideas

- Picker should feel native to macOS — segmented control is the standard pattern for three mutually exclusive options
- Color preview is a small touch that gives immediate visual confirmation without needing to leave Settings
- Appearance tab is forward-looking: sidebar customization (Phase 4) slots in naturally

</specifics>

<deferred>
## Deferred Ideas

- Sidebar style toggle — deferred to Phase 4 (Navigation Shell); Appearance tab will have a placeholder section ready
- Menu bar / toolbar access to theme switching — not in scope for this phase; could be added as a v2 enhancement

</deferred>

---

*Phase: 02-theme-switching*
*Context gathered: 2026-02-22*
