# Sicon Infer DevOps Kit

Infer DevOps Kit — Picks DevOps card implement lane (Inline / Devops Leading Brief / Superpowers); continue/go ahead runs that next step.

## Usage

```
/IDK <work-item-id>
```

Bare `/IDK` asks for the card number. Reply is `Recommendation:` + one short sentence + `→ continue`. Card signal comes from `Get-IdkCardSignal.ps1` (thin ado-core); azgit only if that fails.

After recommend, say **continue** / **go ahead** (or `inline` / `dlb` / `superpowers`) to run that next step — Inline implement, DLB brief, or Superpowers.

## Decision rules (summary)

Approaches only: **Inline** | **Devops Leading Brief** | **Superpowers**. Never stack Devops Leading Brief with Superpowers.

1. Superpowers — only when you ask in the same invoke (user pin); never stack with Devops Leading Brief
2. High resolve complexity → Devops Leading Brief
3. Splash / Prove / security expected → Devops Leading Brief
4. Low complexity → Inline
5. Unclear → Devops Leading Brief

## Reliability

Supported contract: `/IDK` recommend + same-thread proceed. Card fetch quality and whether you follow the recommendation remain agent- and environment-dependent.
