---
name: lint-ready
description: Check dirty files against the repo lint or analyzer gate and optionally fix
---

# lint-ready — Typesetter lint pass

**User-profile contrib (Typesetter).** Bridge workflow: prep dirty files for a future hard lint/analyzer gate. Uses each git root's own tooling (ESLint, or `dotnet format style` when analyzer props are present).

## When

User invokes `/lint-ready` (or asks to get dirty files lint-ready).

## Scripts root

```powershell
$typesetter = Join-Path $env:USERPROFILE '.cursor\packs\typesetter\scripts'
```

## Flow

1. Run probe:

```powershell
& "$typesetter\Get-TypesetterContext.ps1" -Json
```

2. If `dirtyCount` is 0: say nothing to prep; exit.

3. Run verify (no write):

```powershell
& "$typesetter\Invoke-TypesetterLintReady.ps1"
```

Optional: `-StartPath <repo>` when the shell cwd is wrong; `-Json` for structured output.

4. Show the report. If a root is **NO-GATE** (`lintEngine: none`): say no lint/analyzer gate is configured — nothing to prep for that root. That is success for the bridge story, not a failure.

5. If issues: ask the user (one question) whether to **leave unchanged** or **fix auto-fixable problems**. Do not fix until they choose fix.

6. On fix:

```powershell
& "$typesetter\Invoke-TypesetterLintReady.ps1" -Fix
```

Re-run verify; report result; exit.

7. On leave unchanged: exit without writing.

## Do / do not

| Do | Do not |
|----|--------|
| Scope to dirty files only | Whole-repo lint as the default |
| Treat NO-GATE as an honest empty result | Invent analyzer findings when no gate exists |
| Stop for user choice before `-Fix` | Silent rewrite |
| Work in Agent mode when fixing | Commit, push, or open a PR unless the user asks separately |

## Hub vs C# today

- Repos with ESLint (e.g. Hub): real check/fix on dirty TS/JS.
- Repos without analyzer MSBuild wiring: expect NO-GATE until that config exists.
