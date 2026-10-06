---
name: infer-devops-kit
description: >-
  Infer DevOps Kit — pick Inline, Devops Leading Brief, or Superpowers for an
  Azure DevOps card from resolve complexity and splash/Prove need; on continue
  after recommend, run that next step
disable-model-invocation: true
---

# Infer DevOps Kit (IDK)

Two phases: **recommend** (default), then optional **proceed** on same-thread go-ahead.

## Approaches (exactly three)

| Approach | Meaning |
|----------|---------|
| **Inline** | Chat implement. No Devops Leading Brief, no Superpowers. |
| **Devops Leading Brief** | Brief + splash/Prove/security wrap → implement. |
| **Superpowers** | Superpowers on. No Devops Leading Brief. |

Never matrix lane codes. **Never** recommend Devops Leading Brief + Superpowers together.

## Decision rules (in order) — recommend

1. Superpowers — only if explicitly asked in this invoke (user pin); never efficiency default. Never stack with Devops Leading Brief.
2. High resolve complexity → **Devops Leading Brief** (minimal → splash fence).
3. Splash / Prove / security expected → **Devops Leading Brief**.
4. Low complexity → **Inline**.
5. Catchall — prior rules do **not** clearly fire → **Devops Leading Brief**.

## Thin picker (required ADO path) — recommend

Bare minimum to classify. Prefer **one** shell round. **ado-core is required** (via the classifier script); keep it out of chat context.

1. **Dual Resolve** `sicon-infer-devops-kit` → `scripts/Get-IdkCardSignal.ps1`: plugin direct → newest `plugins/marketplaces|cache` (bounded) → packs dogfood only if no plugin; never prefer pack.  
   Dogfood fallback: `%USERPROFILE%\.cursor\packs\infer-devops-kit\scripts\Get-IdkCardSignal.ps1`
2. Run via shell `-File` only. The script Dual-Resolves ado-core and calls thin helpers (no Expand). Do **not** open the classifier script or the ado-core library into chat context:

```powershell
powershell -NoProfile -File "<resolved>\Get-IdkCardSignal.ps1" -WorkItemId <id> [-WorkspaceRoot <product-repo>]
```

3. Classify from the **compact JSON only** (`title`, `acEmpty`, `descChars`/`acChars`, `snippet`, `signals`).
4. **Fallback** — only if the script / ado-core fails: thin **azgit** `get_work_item` (fields only). Prefer a short mental projection; do not prefer azgit when the script succeeded.
5. **Banned for recommend:** `Get-AdoCoreWorkItem -Expand all`; expand-all / Halo fan-out.

Stop when a rule fires. Do not re-fetch fuller ADO for recommend.

## Reply — recommend (token-minimal)

```
Recommendation: Inline | Devops Leading Brief | Superpowers
<one short sentence why>
→ continue
```

No headstart block, no field dump, no Next checklist. Remember **card id** + **Recommendation** for this thread.

## Proceed — same-thread go-ahead

**When** (all required):

1. This thread already has an IDK **Recommendation:** for a card id.
2. User message is a clear go-ahead (no new `/IDK <other-id>`):  
   `continue`, `go ahead`, `yes`, `do it`, `proceed`, `then`, `ok`, `yep`,  
   or path-shaped: `inline`, `dlb` / `lb` / `devops leading brief`, `superpowers`  
   (optional trailing words like `then` / `with that`).
3. Last agent turn was the IDK recommend (or an Orient answer that still pointed at that recommendation) — **not** an unrelated ask.

**Do not** treat bare `yes` / `continue` as proceed when answering a different question.

**Do not** re-run classify on proceed unless the user supplies a **new** `/IDK <id>`.

### Dispatch (from the prior Recommendation)

| Prior Recommendation | Action |
|----------------------|--------|
| **Inline** | Implement that card **inline** in this chat (minimal / splash; no DLB, no Superpowers). |
| **Devops Leading Brief** | Dual Resolve + **Read** `devops-leading-brief/SKILL.md` in full → run **brief** for the **same** card id. IDK ends; DLB owns the turn. |
| **Superpowers** | Engage Superpowers for that card (no DLB). |

If the user names a path that **differs** from the recommendation (e.g. recommend DLB but they say `inline`), **honor the user’s pin** for that proceed.

## Hard rules

- Recommend phase: no plan, code, commit, PR, or brief file.
- Proceed phase: only the dispatched next step above.
- Fail closed if Dual Resolve cannot find this skill or `Get-IdkCardSignal.ps1` (recommend).
- No card id on first invoke → ask once for the number.
- Proceed with no prior Recommendation in thread → ask once: run `/IDK <id>` first.
