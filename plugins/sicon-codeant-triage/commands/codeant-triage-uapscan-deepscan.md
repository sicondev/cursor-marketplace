---
name: codeant-triage-uapscan-deepscan
description: CodeAnt Triage: /codeant-triage PR comment loop (Fix / Won't fix / Skip + UAP Disposition); /codeant-triage-uapscan and /codeant-triage-uapscan-deepscan UAP scans (no finalize); profile-only; recom...
---
# CodeAnt Triage — UAP deep scan (workspace)

**Slash only** — use when the user invokes `/codeant-triage-uapscan-deepscan` or `/codeant-triage-uapscan-deepscan <paths>`. **No** natural-language auto-engage. **No** finalize / commit / ADO reply from this command.

**User catalog:** `%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md`

**Naming:** **UAP** = user anti-pattern rows in `anti-patterns.user.md` (+ optional profile `codeant-uap-*.mdc`). This is **not** CodeAnt (ADO) PR triage (`/codeant-triage`). Prefer a **narrowed** path for dogfood; full-workspace scans can be large — always allow abort.

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
scope → load in-scope UAPs → UAP-outer emit over workspace ∩ user-narrow ∩ noise-exclude →
AskQuestion (fix now | report only | abort) → shared fix loop OR report → rollup (no finalize)
```

## Input modes

1. **Blank** `/codeant-triage-uapscan-deepscan` — candidate roots = workspace root (then noise-exclude).
2. **Narrowed** `/codeant-triage-uapscan-deepscan <path>…` — candidate roots = those pointers only (still noise-exclude under them).

## Noise exclude (always)

Skip any path that is under or equal to these directory names, or matches these file patterns (any depth):

**Directories:** `node_modules`, `dist`, `build`, `out`, `bin`, `obj`, `.git`, `.vs`, `.idea`, `.next`, `coverage`, `.turbo`

**Files:** `*.min.js`, `*.min.css`, `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`

Never scan inside excluded trees even if the user narrows into a parent that contains them.

## Setup (every engagement)

### 0 — Repo scope

```powershell
powershell -NoProfile -File "$triage\Get-CodeAntRepoScope.ps1"
```

Keep `remoteId` / `displayName` for the session.

### 1 — Load in-scope UAPs only

1. `$paths.userCatalog` (`%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md`) — rows whose **Scope** is `*` **or** equals current `remoteId`. Missing Scope = `*`. **Do not** filter on **Disposition** (include blank and populated). Disposition does **not** change uapscan recommend/treat logic (PR-triage Gate 1 only).
2. Profile rules `%USERPROFILE%\.cursor\rules\codeant-uap-*.mdc` where `codeantRepo` is `*` or current `remoteId`.

**Stop** if there are no in-scope UAPs (say so).

Core CAP/AP rows are **out of scope** for emit.

### 2 — UAP-outer discovery

For **each** in-scope UAP:

1. Determine search roots: workspace or user-narrowed paths, minus noise exclude.
2. If a matching `codeant-uap-<n>.mdc` exists, further restrict to files matching its `globs` (still ∩ narrow ∩ noise exclude).
3. If **no** profile rule, search all files under roots within repo Scope (still noise-exclude) — do not load this UAP against files in a mismatched remote workspace.
4. Emit candidate findings: path, UAP id, ~line, signal / short why.

**Progress / abort:** On long scans, periodically summarize progress in chat and honor chat `abort` / `stop`. Optionally **`AskQuestion`**: `Continue scanning?` → `Continue (Recommended)` \| `Stop session` (do not list options in chat).

Collect all findings, then emit a discovery index:

```markdown
### UAP deep scan

Remote: `<remoteId>` | Roots: `<…>` | **N findings** across **U** UAPs
```

| # | UAP | Location |
|---|-----|----------|
| 1 | UAP-1 | `path` ~line |

**Stop** with a short message when zero findings (no fix-vs-report AskQuestion required).

### 3 — After discovery AskQuestion

**Same turn** as the index (when N > 0): invoke **`AskQuestion`** — do **not** list options in chat.

| id | label |
|----|-------|
| `fix_now` | `Fix now (Recommended)` |
| `report_only` | `Report only` |
| `abort` | `Stop session` |

- **`prompt`:** `Deep scan complete — next step?`

| Choice | Next |
|--------|------|
| **fix_now** | Mandatory read `$paths.uapscanFixLoop` → shared fix loop |
| **report_only** | Expand inventory in chat (path, UAP, why) → **stop** (no implement, no finalize) |
| **abort** | Short stop message → **stop** |

## Fix loop and end

When fixing: follow **uapscan-fix-loop.md** entirely.

**Hard bans:** no finalize AskQuestion, no `git commit` / `git push`, no `Post-CodeAntPrThreadReply.ps1`, no catalog promote Gate A/B.

## Abort

Honor chat `abort` / `stop` during discovery and every shared-loop gate. Critical for long deepscans.
