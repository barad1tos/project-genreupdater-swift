# Lessons Learned: Phase 3 Closure & Ship Pipeline

## Summary
| Metric | Value |
|--------|-------|
| Total time | ~30 min (8 commits + /ship) |
| Optimal time | ~20 min (6 commits + /ship) |
| Waste ratio | ~1.5x |
| Key insight | Plans that include git operations should be validated against .gitignore BEFORE execution — the plan committed gitignored files without checking |

## What Happened
Executed a 6-commit plan to sync project documentation, close Phase 3, and activate Phase 4. Plan included committing `.claude/agents/` (17 files, 5K lines) to git. User caught this post-commit — agents are local config, not project deliverables. Required 2 extra commits (untrack + docs fix) and an 8th commit during /ship triage. Sourcery bot polling wasted 60s on a private repo without subscription.

## Critical Mistakes

1. **Committed .claude/agents/ without questioning gitignore intent** (~5 min)
   - The plan said "commit agent files" and I executed without checking whether `.gitignore`'s `!.claude/` override was intended to cover agents or just hooks
   - The `.gitignore` had `!.claude/` to track hooks (CI gates), not agents (local config)
   - User caught it: "Вся папка Claude хіба не в глобальному гітігнорі?"
   - Fix: Before committing files from a gitignored-then-overridden path, verify the INTENT of the override

2. **Plan review didn't flag the git tracking issue** (~0 min but cascading)
   - The executing-plans skill says "Review critically — identify any questions or concerns about the plan"
   - I noted zero concerns, but should have questioned: "Should local agent config be committed?"
   - Fix: During plan review, explicitly check whether new files being tracked belong in the repo

3. **Polled Sourcery bot twice despite knowing it can't review private repos** (~60s)
   - First poll returned "Your private repo does not have access to Sourcery"
   - Instead of immediately switching to local-only mode, waited 30s and polled again
   - Fix: If a bot explicitly says "no access", skip further polling for that bot

## Patterns Identified

| Pattern | Recognition Signal | Correct Response |
|---------|-------------------|------------------|
| Gitignore Override Mismatch | `.gitignore` has `!path/` but path contains both tracked and untracked content | Check whether the override covers ALL subdirs or needs selective re-ignoring |
| Plan Trust Without Verification | Plan says "commit these files" for files in override paths | Cross-check: is each file appropriate for git? Local config vs project deliverable? |
| Dead Bot Polling | Bot review says "no access" or "upgrade required" | Immediately skip remaining polls for that bot, proceed with local-only |
| Pre-commit Hook as Safety Net | SwiftFormat/SwiftLint catches issues on commit | Trust hooks but don't rely on them — run formatters BEFORE staging to avoid commit-retry cycles |

## Actionable Rules

```
WHEN a plan includes committing files from a
     gitignore-overridden path (!.path/)
THEN verify each subdir's tracking intent
     before executing
BECAUSE override may be for specific subdirs
     (hooks), not all content (agents)
```

```
WHEN an AI review bot responds with "no access"
     or "upgrade required"
THEN immediately switch to local-only triage
BECAUSE further polling wastes 30-60s per
     attempt with zero information gain
```

```
WHEN executing a multi-commit plan
THEN run swiftformat on affected files BEFORE
     staging, not relying on pre-commit hook
BECAUSE hook failures require re-stage +
     re-marker + re-commit (~30s per retry)
```

```
WHEN reviewing a plan critically (Step 1)
THEN check git-specific steps against actual
     .gitignore, branch state, and remote
BECAUSE plans are written in a prior context
     that may not match current repo state
```

## Checklist: Multi-Commit Ship Session

- [ ] Read `.gitignore` before committing new/untracked files
- [ ] For override paths (`!`), verify each subdir's intent (CI vs local)
- [ ] Run `swiftformat` on changed files before staging
- [ ] Run `swiftlint --strict` on changed files before staging
- [ ] Check if AI review bots have access to repo (private = likely no)
- [ ] After all commits, verify `git status` is clean before push
- [ ] Cross-check doc sources agree (PRD/TDD/tasks/CLAUDE.md) before finalizing PR

## Additions to Project Docs

### CLAUDE.md — already updated this session:
- `.claude/agents/` noted as gitignored (local-only, manual setup)
- `.gitignore` now has selective re-ignoring: `!.claude/` + `.claude/agents/`

### Episodic memory — key facts to persist:
- `.claude/agents/` is gitignored — never commit agent files
- `.claude/hooks/` IS tracked — these are CI quality gates
- Sourcery-AI bot has no access to private repos without paid plan
- `swiftformat` before staging avoids pre-commit hook retry cycles
