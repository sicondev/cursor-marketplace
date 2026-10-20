# Sicon Infer DevOps Kit

Infer DevOps Kit — Picks DevOps card implement lane (Inline / Devops Leading Brief / Superpowers); asks whether to proceed before running that next step.

## Usage

```
/IDK <work-item-id>
```

Bare `/IDK` asks for the card number. Reply is `Recommendation:` + one short sentence + a `Proceed with <lane>?` question. Card signal comes from `Get-IdkCardSignal.ps1` (thin ado-core); azgit only if that fails.

Answer that question with **continue** / **go ahead** (or `inline` / `dlb` / `superpowers`) to run that next step — Inline implement, DLB brief, or Superpowers. If the recommendation is DLB **(fallback)** — no rule clearly fired — it says so and names the specific info that would firm it up (e.g. repos touched, whether Prove is expected); supply any of it for a firmer call, or just continue with the recommendation as-is.

## Decision rules (summary)

Approaches only: **Inline** | **Devops Leading Brief** | **Superpowers**. Never stack Devops Leading Brief with Superpowers.

1. Superpowers — only when you ask in the same invoke (user pin); never stack with Devops Leading Brief
2. High resolve complexity (positive evidence: multi-repo, unbounded + product decision) → Devops Leading Brief
3. Splash / Prove / security expected (shown in the signal, not merely unclear) → Devops Leading Brief
4. Low complexity → Inline — title-sufficient bounded work counts, even with thin/empty AC
5. Unclear → Devops Leading Brief **(fallback)** — disclosed as low confidence, naming the specific info that would firm it up; continue with recommendation always offered

## Reliability

Supported contract: `/IDK` recommend + same-thread proceed. Card fetch quality and whether you follow the recommendation remain agent- and environment-dependent.
