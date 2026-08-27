# CodeAnt Triage anti-patterns — core catalog

Pack-managed index for **CodeAnt Triage** (`/codeant-triage`). Overwritten on install / reinstall / version refresh — **do not append promotes here**.

User-promoted rows live in `%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md` (seeded by init; survives reinstall). Filter user rows by ADO remote Scope (`Get-CodeAntRepoScope.ps1`); core rows below always apply.

**Shipped install root:** user pack `%USERPROFILE%\.cursor\packs\codeant-triage\` or Team Marketplace plugin `sicon-codeant-triage` (core may sit at install root or `content/`).

**Naming:** **CodeAnt (ADO)** = DevOps PR reviewer. **CodeAnt Triage** = local `/codeant-triage` workflow.

| ID | Pattern | Signals | Fix direction | Enforced by |
|----|---------|---------|---------------|-------------|
| CAP-1 | CodeAnt (ADO) scoped to narrow diff | “Missing X” but X exists on branch in earlier commit or outside analyzed diff | Triage: Already fixed / Invalid; reply on PR with commit or path | CodeAnt Triage |
| CAP-2 | Already fixed on branch | Comment stale vs HEAD; fix landed in an earlier commit on the PR branch | Triage: Already fixed; reply with commit/path; resolve on finalize | CodeAnt Triage |
| AP-3 | Missing XML doc on changed public C# member | CodeAnt (ADO) documentation rule; new/changed `public` / `public override` without `/// <summary>` | Add or update summary per member signature and behaviour | CodeAnt Triage (optional open-repo `public-xml-summaries.mdc`) |
| AP-6 | Rejecting valid `/// <inheritdoc />` | Review asks to replace `/// <inheritdoc />` (or `inheritdoc cref`) with explicit `/// <summary>` on interface/base implementation members | **Keep inheritdoc** — satisfies documentation requirement; do not duplicate base/interface docs | CodeAnt Triage (optional open-repo `public-xml-summaries.mdc`) |

## ADO PR replies (CodeAnt Triage)

When posting `Post-CodeAntPrThreadReply.ps1` text, cite CAP-/AP-/UAP- IDs and pack paths **only in chat** — not in ADO. Use plain **Issue:** / **Fix:** lines per `/codeant-triage` § ADO PR reply text.
