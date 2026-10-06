---
name: IDK
description: >-
  Infer DevOps Kit — recommend Inline, Devops Leading Brief, or Superpowers
  for an Azure DevOps card; continue/go ahead runs that next step
---

# /IDK — Infer DevOps Kit

**Recommend** one approach (tiny reply). After that, **continue** / **go ahead** runs the recommended next step.

**Skill (Dual Resolve):** Read `infer-devops-kit/SKILL.md` in full — Dual Resolve `sicon-infer-devops-kit` → `skills/infer-devops-kit/SKILL.md` (plugin direct → newest `plugins/marketplaces|cache` bounded → user-pack skills dogfood only if no plugin; never prefer pack). Fail closed if neither exists.

## Usage

| Input | Action |
|-------|--------|
| `/IDK <id>` | Shell `Get-IdkCardSignal.ps1` → rules → `Recommendation:` + why + `→ continue`; stop |
| `/IDK` (no id) | Ask for card number once |
| After recommend: `continue` / `go ahead` / `yes` / `do it` / `dlb` / `inline` / … | **Proceed** — dispatch prior Recommendation (Inline implement / DLB brief / Superpowers) |

## Hard rules

- Recommend: no plan, code, brief file, ship, or headstart dump.
- Thin ADO via `Get-IdkCardSignal.ps1` (ado-core, no Expand). **azgit** fields-only only if ado-core / script fails.
- Exactly one of: Inline | Devops Leading Brief | Superpowers. Never stack.
- Proceed only same-thread after an IDK Recommendation; do not re-classify unless `/IDK <new-id>`.
