---
name: format-ready
description: Check dirty files against the repo format config and optionally fix drift
---

# format-ready — Typesetter format pass

**User-profile contrib (Typesetter).** Bridge workflow: prep dirty files for a future hard format gate. Uses each git root's own tooling (`dotnet format` when a `.sln`/`.csproj` is present — EditorConfig is used when the repo has one; otherwise Prettier when configured).

## When

User invokes `/format-ready` (or asks to get dirty files format-ready).

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
& "$typesetter\Invoke-TypesetterFormatReady.ps1"
```

Optional: `-StartPath <repo>` when the shell cwd is wrong; `-Json` for structured output.

4. Show the report (roots, engine, drift vs clean). Label clearly: this is **format drift vs repo config**, not a claim that today's build fails. Keep the absolute paths from `roots[].files` for the fix step.

5. If clean: confirm and exit.

6. If drift: ask the user (one question) whether to **leave unchanged** or **fix listed files**. Do not fix until they choose fix.

7. On fix: pass the **same paths** from the verify report via `-Files`. The script intersects that list with files that are still dirty, so clean or out-of-set paths are not rewritten:

```powershell
& "$typesetter\Invoke-TypesetterFormatReady.ps1" -Fix -Files $reportFiles
```

Re-run verify with the same `-Files` list; report result; exit.

8. On leave unchanged: exit without writing.

## Do / do not

| Do | Do not |
|----|--------|
| Scope to the verify report's files | Whole-tree reformat |
| Pass `-Files` on `-Fix` from that report | Rescan dirty files between approve and fix |
| Use the scripted probe/verify/fix | Invent a second format standard |
| Stop for user choice before `-Fix` | Silent rewrite |
| Work in Agent mode when fixing | Commit, push, or open a PR unless the user asks separately |

## Empty tooling

If the probe reports `formatEngine: none` for a root with format-relevant dirty files: say no format tooling was detected; do not pretend a gate exists.
