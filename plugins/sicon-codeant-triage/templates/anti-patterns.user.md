# CodeAnt Triage anti-patterns — user catalog

Profile-local promotes for **CodeAnt Triage** (`/codeant-triage`). Seeded once via `Initialize-CodeAntTriageCatalog.ps1` (`Copy-IfMissing`); **not** Force-copied by install.

**Do not edit** `anti-patterns.core.md` (pack/plugin-managed at the install root or `content/`).

**User data root:** `%USERPROFILE%\.cursor\codeant-triage\`

**ID policy:** user-promoted rows use **`UAP-*`** (e.g. `UAP-1`, `UAP-2`). Do not reuse shipped `CAP-*` / `AP-*` IDs from core.

**Scope:** Canonical ADO remote id `Collection/Project/Repository` (from `Get-CodeAntRepoScope.ps1`), or `*` for all repos. **Repo** is the local folder leaf for display only (use `-` when Scope is `*`). Missing Scope on legacy rows is treated as `*` when filtering. Scope is a **load filter**, not a write destination for product repos.

**Disposition:** Temporary handling guidance for matching **CodeAnt (ADO)** findings while remediation is outstanding. Does **not** own backlog sequencing (optional `personal-todo` does).

| Disposition | Semantics |
|-------------|-----------|
| **Blank** (or missing column on legacy 7-column rows) | Standard UAP — pattern recognition + fix guidance only; **never** bias Gate 1 toward Won't fix |
| **Populated** | One-line free text; preferred shape `Recommend WontFix — <rationale>`. UAP stays matchable; later triage may recommend Won't fix and cite this text. Recommendation is not automatic — re-evaluate the current finding. |

Never filter Scope-matching rows out of a catalog load because Disposition is blank or populated. Clearing remediation = empty the Disposition cell only (do not delete the row).

| ID | Scope | Repo | Pattern | Signals | Fix direction | Disposition | Enforced by |
|----|-------|------|---------|---------|---------------|-------------|-------------|

## Adding rows

**CodeAnt Triage** proposes new rows after Valid/Partial **generalizable** findings from **CodeAnt (ADO)** (after Fix Accept and/or after Won't fix). User confirms scope (This repo / All repos) before editing.

Append only to this file (`%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md`). Do not write product-repo overlays.

Format: next `UAP-*` ID | Scope (`*` or remote id) | Repo (display or `-`) | Pattern | Signals | Fix direction | Disposition (blank or `Recommend WontFix — …`) | Enforced by (CodeAnt Triage)

**Legacy:** A file with the pre-Disposition 7-column header is valid — treat missing Disposition as blank. Before upgrading that header, pad every existing data row with an empty Disposition cell so **Enforced by** remains in its rendered column. New writes use the 8-column header above.
