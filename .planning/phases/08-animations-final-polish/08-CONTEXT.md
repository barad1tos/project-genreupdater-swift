# Phase 8: Animations and Final Polish - Context

**Gathered:** 2026-02-24
**Status:** Ready for planning

<domain>
## Phase Boundary

Make the app feel alive and responsive — smooth screen transitions, animated Dashboard metrics, consistent hover/press feedback across all interactive elements. No new features; purely motion and interaction polish.

</domain>

<decisions>
## Implementation Decisions

### Screen Transitions
- Sidebar switching uses **matched geometry** for title/icon + **crossfade with subtle upward drift (4-8pt)** for body content
- Duration: **0.35s** (Apple-standard medium)
- First load is **instant** — transitions only on subsequent sidebar switches
- **Sidebar active indicator** animates smoothly between items (capsule/accent bar morph)
- Deep navigation (Browse → Artist → Album) uses **crossfade in-place** with **breadcrumb trail** for back navigation (Browse › Artists › Pink Floyd)
- Theme switching (Dark ↔ Light): **smooth crossfade** of all colors (~0.3s)
- Sheets/modals: **standard macOS sheet** animation (native slide down)
- Easing: use **existing Motion tokens** (curveCrossfade for fades, curveFast for matched geometry)

### Metric Animations
- Dashboard numbers: **`.contentTransition(.numericText())`** when data arrives from MusicKit
- Stagger cascade: **first load only** (existing 50ms stagger), subsequent visits instant
- HeroGauge: **smooth arc fill** from 0 to target value with easeOut
- Quick Actions cards: **scale 0.9 → 1.0 bounce** on appearance (within first-load stagger)
- ProgressRing: **smooth arc animation** on each track completion during batch update
- Swift Charts (Reports): **bars grow from bottom** with stagger on first render
- Charts interactive: **hover tooltip** showing exact value + bar highlight
- Change log new entries: **instant** — data over effects

### Hover & Press Feedback
- Hover: **unified pattern** across all screens (accent bar + bgTertiary) — same in Browse, Update, Reports
- Hover speed: **instant** — no fade delay on appear/disappear
- Press: **scale 0.97** for all interactive elements (buttons, cards, rows) — unified, no per-type variation
- Sidebar items: **light background** on hover for inactive items
- FilterChip toggle: **smooth bg transition** (accent fill ↔ outline)
- ConfidenceBadge: **scale pop-in** animation on appearance
- Undo buttons (hover-only): **instant** appear on hover, no transition
- List insert/remove: **smooth insertion/deletion** with neighboring items shifting

### Motion Philosophy
- Character: **playful and organic** — like Things/Notion, with springs and organic easing
- Max duration: **0.8s** for wow-moments (HeroGauge fill), most interactions < 0.4s
- **"Fast Animations" toggle** in Settings: ON = all durations halved (50% speed multiplier)
- Reduce Motion (system): **crossfade-only mode** — opacity transitions preserved, no scale/slide/spring
- Loading indicators: **standard ProgressView** (native macOS)
- Error states: **shake + fade** — light shake on error, message fades in
- No confetti, no celebration micro-interactions — functional animations only

### Claude's Discretion
- Exact spring parameters (damping, stiffness) for organic feel
- Breadcrumb trail component design and placement
- Tooltip styling for chart hover
- Shake animation parameters (offset, repetitions)
- Motion token additions if existing tokens don't cover new use cases

</decisions>

<specifics>
## Specific Ideas

- "Живий і грайливий" (playful and organic) — like Things/Notion motion language
- Breadcrumb navigation for deep drill-downs (Browse › Artists › Pink Floyd)
- Settings toggle for users who prefer faster animations (50% duration reduction)
- HeroGauge arc fill as the signature "wow moment" — up to 0.8s allowed

</specifics>

<deferred>
## Deferred Ideas

- Breadcrumb trail UI component — if it doesn't exist yet, creating the full breadcrumb navigation component may warrant its own task or phase integration. The animation aspect (crossfade in-place) is in scope; the breadcrumb UI itself may extend beyond polish.

</deferred>

---

*Phase: 08-animations-final-polish*
*Context gathered: 2026-02-24*
