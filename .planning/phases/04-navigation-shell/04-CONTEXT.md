# Phase 4 Context: Navigation Shell

> Decisions gathered through discussion — guides research and planning agents.

## 1. Sidebar Look & Feel

### Background
- **Adaptive**: light background in light mode, dark in dark mode (NOT always-dark)
- Uses Ayu theme colors (`Ayu.bgPrimary` / `Ayu.bgSecondary` depending on mode)

### Compact / Expanded Toggle
- **Both modes supported**, switchable via toggle button
- Toggle position: **top of sidebar**
- Toggle icon: **`sidebar.left`** SF Symbol (this is a UI chrome icon, not app content — SF Symbols fine here)
- Persisted via **`@AppStorage`** across launches
- **Expanded mode**: icon + text label for each item
- **Compact mode**: icons only with tooltip on hover
- Compact background: **transparent** (not tinted)
- Compact section headers: replaced with **thin divider line** (no text)

### Width & Resize
- Expanded width: **160–260pt**, resizable
- `navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)`

### Animation
- Compact ↔ expanded transition: **smooth width resize** with text fade in/out

### Section Headers
- Two sections: **LIBRARY** (Dashboard, Browse, Reports) / **TOOLS** (Update)
- Headers visible in expanded mode, replaced by divider in compact mode
- Uppercase, small font, `Ayu.fgSecondary`

### SF Symbols
- **Outlined** style (not filled) — lighter, minimalist
- Note: sidebar navigation icons use SF Symbols (UI chrome). App content uses Lucide (see §4).

### Footer
- **Settings gear icon** at bottom of sidebar
- Visible in **both** compact and expanded modes
- Action: opens system Settings window (same as Cmd+,)

### Hover
- Non-active items show **subtle bgTertiary background** on hover
- Animated with `Motion.curveFast`

### Branding
- **No app name/logo** at top of sidebar — clean

## 2. Active Item Highlight

### Indicator Shape
- **Pill background** (rounded rectangle behind the item text/icon)
- Like Apple Music sidebar style

### Colors
- Pill fill: **`Ayu.accent.opacity(0.15)`**
- Pill border: **1pt `Ayu.accent`** stroke (fill + thin border combo)
- Active text color: **`Ayu.accent`** (changes from default fgPrimary)
- Active icon color: **`Ayu.accent`** (both icon and text become accent)
- Font weight: **unchanged** (no bold on active — only color changes)

### Compact Mode Active
- **Pill around the icon** (circle or rounded square with accent fill behind icon)

### Animation
- **`matchedGeometryEffect`** with `Motion.curveSmooth` (~0.35s)
- Pill slides between items when switching screens

## 3. Column Layout Behaviour

### Two-Column vs Three-Column
- **Dashboard, Update, Reports**: two-column layout (sidebar + content, NO detail panel)
- **Browse**: three-column when a track is selected; two-column when no track selected

### Browse Empty Detail
- When no track selected: **hide detail column** with animation (`.doubleColumn`)
- Detail slides in when a track is selected
- **Deferred to Phase 5/6**: show an ambient HeroGauge visualization in the empty detail area

### Track Selection Persistence
- **Preserve selection** when navigating away from Browse
- Returning to Browse restores the selected track and detail panel

### Content/Detail Proportions (Browse)
- Default: **40:60** (detail wider — focus on track info)
- Resize: **NavigationSplitView native** drag-to-resize
- Min content width: **320pt** (prevents artist list collapse)

### Narrow Window Behaviour
- When window approaches minimum (900pt) with Browse + detail open:
  **Detail auto-collapses** (falls back to two-column)

### Content Area (Non-Browse)
- **Centered with max-width** (~800pt) + consistent padding
- Not stretched to full width — prevents overly wide content on large screens
- Consistent padding applied to ALL content views (Dashboard, Update, Reports)

### Content Transition
- **Cross-fade** (`.contentTransition(.opacity)`) between screens — already implemented

## 4. Sidebar Items & Ordering

### Sections and Order
```
LIBRARY
  1. Dashboard     (Cmd+1)
  2. Browse        (Cmd+2)
  3. Reports       (Cmd+3)

TOOLS
  4. Update        (Cmd+4)

─── (footer) ───
  ⚙ Settings gear
```

### Icons
- **Lucide icons** (ISC license) for all sidebar navigation items
- Chosen for distinct visual identity — modern, analytical, vibrant (CleanMyMac-inspired)
- Integration: import as SVG assets or Swift package
- Specific icons to be selected during planning phase (research Lucide set)

### Badges
- **Off by default**
- Toggle option to enable/disable sidebar badges (e.g., track count on Browse)
- Badge toggle persisted via `@AppStorage`

### Keyboard Navigation
- `Cmd+1` = Dashboard
- `Cmd+2` = Browse
- `Cmd+3` = Reports
- `Cmd+4` = Update
- Follows visual order in sidebar

## Deferred Ideas

Items surfaced during discussion but out of Phase 4 scope:

1. **Ambient HeroGauge in Browse empty detail** — show a subdued version of the Dashboard gauge when no track is selected in Browse. Requires HeroGauge + real data (Phase 5/6).
2. **Custom icon design** — if Lucide doesn't match the desired aesthetic, consider commissioning a custom icon set. Separate design task.
