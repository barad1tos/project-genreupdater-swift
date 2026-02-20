# Lessons Learned: SwiftUI/Swift Agent Integration

## Summary
| Metric | Value |
|--------|-------|
| Total time | ~2 sessions (~3 hours combined) |
| Optimal time | ~1 session (~1 hour) |
| Waste ratio | ~3x |
| Key insight | When porting external content, copy-then-adapt beats understand-then-rewrite — verification diff after creation is mandatory |

## What Happened
Integrated AvdLee's SwiftUI-Agent-Skill (14 reference files + SKILL.md) as a custom Claude Code agent pair (swiftui-expert + swift-expert). Multiple placement/naming mistakes and content loss during "adaptation" required a full second session to compare, identify gaps, and replace with faithful upstream content.

## Critical Mistakes

1. **Condensed reference files instead of copying verbatim** (~50% content lost)
   - All 14 files reduced from 4,473 to ~2,100 lines
   - Lost: Good/Bad comparisons, "Why" explanations, edge cases, complete code examples
   - Consequence: Agent would generate incomplete patterns, miss anti-patterns
   - Fix: Always copy upstream verbatim first, then add project-specific content on top

2. **Trimmed swiftui-expert.md without tracking what was removed** (20 of 57 checklist items, missing sections)
   - Lost: Swift Best Practices section, 5 checklist sections, Quick Reference tables, Workflow Decision Tree
   - Consequence: Reviews would miss sheets, scrollview, text formatting, layout, liquid glass checks
   - Fix: After creating agent from external source, run a systematic diff before declaring done

3. **Placed agents in `~/.claude/agents/` (global) assuming it works** (2 correction rounds wasted)
   - Discovery: Global agents don't override built-ins and don't register new types
   - Only project-local `.claude/agents/` works for both override and new registration
   - Fix: Test agent dispatch immediately after creation, don't assume placement works

4. **Renamed to `swift-pro` (non-existent type)** (1 round wasted)
   - Custom agent names from `.claude/agents/` only work if they either match a built-in name (override) or are discovered at session start from project-local
   - Fix: Don't invent new agent type names without testing they're discoverable

5. **Didn't compare against original source after creation** (entire second session)
   - "Adapted" from understanding instead of faithful port + additions
   - No verification step to catch content drift
   - Fix: Always diff original → created version as final step

## Patterns Identified

| Pattern | Recognition Signal | Correct Response |
|---------|-------------------|------------------|
| Content Drift During Porting | Creating agent/skill from external source by "understanding and rewriting" | Copy verbatim first, then selectively add/adapt. Always diff against source after. |
| Untested Infrastructure Assumption | "I'll put files here and it should work" without verification | Test the mechanism immediately with a minimal probe before building on it. |
| Progressive Content Loss | Each "simplification" removes valuable edge cases and comparisons | Reference files are read on-demand — full content costs nothing when not loaded. |
| Agent Placement Discovery | Need to place custom agents in Claude Code | Only project-local `.claude/agents/` works. Global `~/.claude/agents/` is inert. Session restart required for discovery. |

## Actionable Rules

```
WHEN porting content from an external skill/agent/repo
THEN copy all content files verbatim first, then add project-specific adaptations on top
BECAUSE "adaptation from understanding" loses 30-50% of content (examples, edge cases, comparisons)
```

```
WHEN creating a custom Claude Code agent
THEN place it in project-local `.claude/agents/`, never in global `~/.claude/agents/`
BECAUSE only project-local agents are discovered — global ones are ignored for both override and new types
```

```
WHEN naming a custom agent file
THEN either match a built-in name (to override it) or create a new name (registered at session start)
BECAUSE agent type discovery happens at session start from project-local `.claude/agents/` only
```

```
WHEN finished creating agent/skill from external source
THEN systematically compare every section and file against the original (use a subagent for large sets)
BECAUSE content drift is invisible without explicit verification — you won't know what's missing
```

```
WHEN creating reference files for an agent
THEN use full upstream content, not condensed versions
BECAUSE agents read references selectively — token savings come from selective loading, not content trimming
```

```
WHEN placing agents/files in a new location mechanism
THEN test with a minimal probe (spawn agent, ask identity question) BEFORE building the full solution
BECAUSE untested infrastructure assumptions cascade into multiple wasted correction rounds
```

## Checklist for Agent Integration from External Source

- [ ] Copy all reference/content files verbatim (not condensed)
- [ ] Create agent .md with full original content + adaptations
- [ ] Place in project-local `.claude/agents/` (not global)
- [ ] Restart session for agent discovery
- [ ] Test agent identity (spawn, ask about capabilities/cross-references)
- [ ] Diff agent file against original source — verify all sections present
- [ ] Diff reference files against upstream — verify byte-level match
- [ ] Copy to global `~/.claude/agents/` as backup (non-functional but preserved)
- [ ] Verify cross-references between agents work both directions

## Additions to Project Docs

### CLAUDE.md — add to Workflow Rules:
- Agent files go in project-local `.claude/agents/` — global `~/.claude/agents/` does not work
- After porting external content, always diff against source to verify completeness

### Episodic Memory — key facts to persist:
- `~/.claude/agents/` is inert — does not override built-ins, does not register new agent types
- `.claude/agents/` (project-local) works for both built-in override and new type registration
- Agent type discovery happens at session start — mid-session file creation requires restart
- AvdLee also has Swift-Concurrency-Agent-Skill and Swift-Testing-Agent-Skill repos (potential future integration)
