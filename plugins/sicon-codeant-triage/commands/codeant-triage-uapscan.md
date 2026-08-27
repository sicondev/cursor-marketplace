---
name: codeant-triage-uapscan
description: Scan your uncommitted files for personal anti-patterns (does not commit or reply on the PR)
---

# CodeAnt Triage — UAP scan (dirty files)

**Slash only** — use when the user invokes `/codeant-triage-uapscan` or `/codeant-triage-uapscan <paths>`. **No** natural-language auto-engage. **No** finalize / commit / ADO reply from this command.

**User catalog:** `%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md`

**Naming:** **UAP** = user anti-pattern rows in `anti-patterns.user.md` (+ optional profile `codeant-uap-*.mdc`). This is **not** CodeAnt (ADO) PR triage (`/codeant-triage`).

## Resolve scripts (dual install — order is mandatory)

1. **User pack:** `%USERPROFILE%\.cursor\packs\codeant-triage\scripts\Get-CodeAntTriagePaths.ps1` if `Test-Path`.
2. **Team Marketplace plugin:** search `%USERPROFILE%\.cursor\plugins\` for `Get-CodeAntTriagePaths.ps1` whose path contains `sicon-codeant-triage`. Prefer the newest by `LastWriteTime`.
3. Else **stop** — install the user pack or **Sicon CodeAnt Triage** from the Team Marketplace.

```powershell
$paths = (powershell -NoProfile -File "<resolved>\Get-CodeAntTriagePaths.ps1" -Json) | ConvertFrom-Json
$triage = $paths.scriptsRoot
```

## Workflow overview

```text
scope → git dirty set → (optional narrow intersect) → group files by applicable UAP set →
file-outer: load UAPs once per group → find violations → shared fix loop → rollup (no finalize)
```

## Input modes

1. **Blank** `/codeant-triage-uapscan` — scan **all** git-dirty files (modified / added / untracked). Do **not** assume open or unsaved editor buffers.
2. **Narrowed** `/codeant-triage-uapscan <path>…` — further **restrict** the dirty set to paths under the given repo-relative (or absolute) pointers. Do **not** scan dirty files outside the narrow. Do **not** expand to clean files.

## Setup (every engagement)

### 0 — Repo scope

```powershell
powershell -NoProfile -File "$triage\Get-CodeAntRepoScope.ps1"
```

Keep `remoteId` / `displayName` for the session.

### 1 — Dirty set

From the open product repo root, collect git-dirty paths:

```powershell
git status --porcelain
```

Include modified, added, and untracked files (status codes `M`, `A`, `?`, renames' new path, etc.). Skip deleted-only entries with no remaining file. Resolve to repo-relative paths.

**Narrow:** if the user supplied path pointers, keep only dirty paths that are equal to or under those pointers.

**Stop** with a short message when the (possibly narrowed) dirty set is empty.

### 2 — Applicable UAPs (scoped load)

Load catalogs — **filter before use**:

1. `$paths.userCatalog` (`%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md`) — rows whose **Scope** is `*` **or** equals current `remoteId` (case-insensitive). Missing Scope on a legacy row = `*`. **Do not** filter on **Disposition** (include blank and populated). Disposition does **not** change uapscan recommend/treat logic (PR-triage Gate 1 only).
2. Profile rules `%USERPROFILE%\.cursor\rules\codeant-uap-*.mdc` where frontmatter `codeantRepo` is `*` or current `remoteId`.

**Per-file applicability:**

| Condition | Apply UAP? |
|-----------|------------|
| Scope / `codeantRepo` mismatches current remote | **No** (never load ai-devtools-scoped UAPs for an out-of-scope Hub file, etc.) |
| Matching `codeant-uap-<n>.mdc` exists | **Yes** only if the file matches that rule's `globs` |
| Catalog row with **no** profile rule | **Yes** for all files within matching repo Scope |

**Do not** load the full catalog blindly for every file. Group dirty files by **identical applicable-UAP id set**; load/read that UAP set **once per group**.

Core CAP/AP rows (`anti-patterns.core.md`) are **out of scope** for emit/match here (PR-comment shaped). Optional open-repo `.cursor/rules/*.mdc` may inform fix quality after a hit; they do not expand the UAP set.

### 3 — File-outer discovery

For each dirty file (grouped as above):

1. Using only that group's applicable UAPs, scan the file for hits (signals / pattern / profile-rule guidance).
2. Collect findings: path, UAP id, ~line, short why.

Emit a **short index** (no full verdicts yet):

```markdown
### UAP scan — dirty files

Remote: `<remoteId>` | **N findings** across **F** dirty files — working one at a time
```

| # | UAP | Location |
|---|-----|----------|
| 1 | UAP-1 | `path` ~line |

**Stop** when zero findings (say so; do not open the fix loop).

Otherwise: **mandatory read** `$paths.uapscanFixLoop` (`uapscan-fix-loop.md` in the install tree), then enter the shared fix loop starting at finding #1.

## Fix loop and end

Follow **uapscan-fix-loop.md** entirely: explain → treat AskQuestion → (fix) confirm; abort anytime; session rollup only.

**Hard bans:** no finalize AskQuestion, no `git commit` / `git push`, no `Post-CodeAntPrThreadReply.ps1`, no catalog promote Gate A/B.

## Abort

Honor chat `abort` / `stop` and AskQuestion **Stop session** at any gate (see shared loop). Critical for long dirty sets.
