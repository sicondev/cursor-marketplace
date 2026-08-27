---
name: codeant-triage
description: Work through CodeAnt findings on an Azure DevOps PR — fix, skip, or save as a personal anti-pattern
---

# CodeAnt Triage

**Post-PR feedback loop only** — use after **CodeAnt (ADO)** comments on an open pull request.

**Naming:** **CodeAnt (ADO)** = external DevOps PR reviewer. **CodeAnt Triage** = this local command (`/codeant-triage`). Do not conflate them.

**User catalog:** `%USERPROFILE%\.cursor\codeant-triage\` (UAPs + prefs — not in the plugin tree).

Use when the user invokes `/codeant-triage`, `/codeant-triage <PR#>`, or a trigger phrase. Prefer the slash command over `@~/.cursor/commands/…` (plugin commands live under the plugin tree).

**Recommended companion (optional):** `personal-todo` — deferred remediation backlog. **Not required.** Probe user-pack `Test-Path "$env:USERPROFILE\.cursor\commands\todo-add.md"` **or** a `todo-add.md` under `%USERPROFILE%\.cursor\plugins\` whose path contains `sicon-personal-todo`. Prefer `/todo-add`. Never load todo files on the Fix → Promote path.

## Resolve scripts (dual install — order is mandatory)

1. **User pack:** `%USERPROFILE%\.cursor\packs\codeant-triage\scripts\Get-CodeAntTriagePaths.ps1` if `Test-Path`.
2. **Team Marketplace plugin:** search `%USERPROFILE%\.cursor\plugins\` for `Get-CodeAntTriagePaths.ps1` whose path contains `sicon-codeant-triage`. Prefer the newest by `LastWriteTime`.
3. Else **stop** — install the codeant-triage user pack, or **Sicon CodeAnt Triage** from the Team Marketplace, reload, retry.

```powershell
$paths = (powershell -NoProfile -File "<resolved>\Get-CodeAntTriagePaths.ps1" -Json) | ConvertFrom-Json
$triage = $paths.scriptsRoot
```

Use `$paths.userCatalog`, `$paths.prefs`, `$paths.coreCatalog` below. If the user catalog is missing, run `Initialize-CodeAntTriageCatalog.ps1` from `$triage`.

## Input modes (either)

1. **PR number** — user gives an Azure DevOps pull request id (e.g. `/codeant-triage 28305`). Fetch findings first (below).
2. **Pasted blocks** — user pastes **CodeAnt (ADO)** **Path** / **Line** / **Comment** output directly.

**Bare `/codeant-triage` (no PR id, no paste):** **AskQuestion** — "Azure DevOps PR number?" or "Paste CodeAnt (ADO) findings?" — then continue. Do not fetch until input is known.

## Workflow overview (linear per-finding)

```text
fetch → sort findings → for each finding (default):
  explain (chat) → AskQuestion TOOL CALL (fix | won't fix | skip [| fix remaining])
  → if fix: implement → show diff → AskQuestion TOOL CALL (accept | revise | revert)
  → if won't fix: resolve reason (reuse user text / Recommendation; ask only if missing) → optional todo offer → next finding
  → iterate until leave finding
→ session rollup → finalize AskQuestion TOOL CALL

optional mid-loop escape (not silent):
  chat "fix all" / "fix remaining" OR treat option Fix remaining
  → AskQuestion confirm batch → implement Fix-targets → one batch confirm → rollup
```

**Never** replace an AskQuestion tool call with chat text like `Reply with one of: Fix | Won't fix | …`.

| Stage | Read-only? | Purpose |
|-------|------------|---------|
| **Setup** | Yes | Fetch, align branch, mandatory reads, short index |
| **Per finding** | Mixed | Explain → decide → (fix → confirm) one issue at a time (**default**) |
| **Fix-remaining escape** | Mixed | Opt-in mid-loop; **one** confirm gate before batch implement |
| **Finalize** | No | Session rollup; commit / push / ADO replies only after gate |

### Non-negotiables

1. **Default = one finding at a time** — finish treat AskQuestion and (if Fix) accept/confirm before starting the next.
2. **Detail in chat; choices only via `AskQuestion` tool call** — never typed menus, never “Reply with one of…”, never paste option labels into chat.
3. **Fix means implement in that cycle** — then confirm before moving on. Do not batch-evaluate all findings then ask once **as the default**.
4. **No silent batch fixes** — `fix all` / `fix remaining` require an **`AskQuestion` confirm** (§ Early escape), then one batch accept — never implement without that gate.
5. **No commit / push / ADO posts** until the session rollup and finalize AskQuestion.
6. **No agent attribution in commit messages** — Planned commit sketches and finalize `git commit` messages must **not** include `Co-authored-by` (any form) or any email addresses (e.g. `cursoragent@cursor.com`). Subject + body (+ optional `#NNNNN` work-item lines) only. Do not inherit Approvals PreCursor / Cursor IDE co-author trailers for this pack.

**Do not** emit a full decision-review table of all findings then offer batch options as Phase 1. Mid-loop **Fix remaining** is an escape only — not a return to batch-decide-first.

## PR number — fetch findings first

When the user supplies a PR id and no pasted blocks:

1. Run from the open product repo root (pass `-Repository` when the PR is not the current repo):

   ```powershell
   powershell -NoProfile -File "$triage\Fetch-CodeAntPrFindings.ps1" -PullRequestId <id> [-Repository <repo>]
   ```

2. **Stop without triaging** when **`activeFindingCount == 0`**.
3. **Align local branch** to the PR source branch when not already on it.
4. Continue with mandatory reads and **Setup — index**, then the **per-finding loop**.

Optional JSON (includes `threadId`, `parentCommentId` per finding):

```powershell
powershell -NoProfile -File "$triage\Fetch-CodeAntPrFindings.ps1" -PullRequestId <id> -Json
```

## Mandatory reads (every engagement)

0. **Repo scope** — resolve current remote id + display folder:

   ```powershell
   powershell -NoProfile -File "$triage\Get-CodeAntRepoScope.ps1"
   ```

   Keep `remoteId` / `displayName` for the session (filter key = `Collection/Project/Repository`; folder is display-only).

1. `$paths.coreCatalog` (always; CAP/AP are not repo-scoped)
2. `$paths.userCatalog` (`%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md`) — **filter** to rows whose **Scope** is `*` **or** equals current `remoteId` (case-insensitive). Missing Scope on a legacy row = treat as `*`. **Do not** filter on **Disposition** (blank or populated — always include Scope-matching rows). Legacy 7-column rows (no Disposition column) ⇒ treat Disposition as blank.
3. **Profile UAP rules** — `%USERPROFILE%\.cursor\rules\codeant-uap-*.mdc` where frontmatter `codeantRepo` is `*` or current `remoteId` (ignore mismatched files in triage even if Cursor attached them by globs).
4. **Open-repo rules** (optional) — `.cursor/rules/*.mdc` matching each finding's file type when present in the product repo. For AP-3 / AP-6, use the core row plus any matching open-repo rule (e.g. `public-xml-summaries.mdc`) — do not load a pack-shipped public-xml sidecar.

**Do not** require PreCursor, Mobius, product-repo anti-pattern overlays, or `personal-todo`.

## Scope

- Validate against **current branch** and **full PR diff**.
- **Implement** when the user chooses **Fix** for that finding (and revise until **Accept**), or after a confirmed **Fix remaining** escape (§ Early escape).

## Trivial vs rule-shaped findings

| Type | Examples | Behaviour |
|------|----------|-----------|
| **Trivial** | Typos in comments/docs | Shorter explain block OK; still one AskQuestion; default recommend **Fix** |
| **Rule-shaped** | XML docs, catch clauses, security, logic | Full explain + catalog / rule cross-check |

## Setup — short index (once)

After fetch and mandatory reads, emit a **header + optional inventory only** — **no** verdicts or proposed fixes:

```markdown
### CodeAnt Triage — PR [#<id>](<prUrl>)

Branch: `<sourceBranch>` | **N active findings** — working one at a time (Critical → Major → Minor)
```

Optional index (location only):

| # | Sev | Location |
|---|-----|----------|
| 1 | Critical | `Example.cs` ~40 |
| 2 | Major | `Other.cs` ~12 |

Then start finding **#1** immediately (do not AskQuestion for batch strategy).

## AskQuestion UX rules (non-negotiable)

**Hard rule:** Fixed-choice moments (**treat**, **confirm**, **finalize**, **catalog**) require the Cursor **`AskQuestion` tool** (native clickable cards). That is a **tool call** in the same turn as the explain/diff — not prose.

**Failure modes (do not do these):**

- Writing `Reply with one of:` / `Choose:` / numbered `1. Fix` / pipe lists `Fix | Won't fix | Skip` in the chat message
- Asking the user to type `Fix` / `Won't fix` / `Skip`
- Emitting option labels in markdown “to stand in for” AskQuestion

**Correct pattern:** Put the explain (or diff / rollup) in chat. **Do not list the options in chat.** End the turn by invoking **`AskQuestion`** once (at most one AskQuestion per assistant message). Wait for the tool result before continuing.

| Rule | Why |
|------|-----|
| **`AskQuestion` tool call — never a typed menu** | Only the tool yields clickable cards |
| **Do not paste option labels into chat** | Models copy them as “Reply with one of…” |
| **Explain / diff / rollup in chat only** | Cards bury detail |
| **`prompt` ≤ one short sentence** | e.g. `Finding #1 — how should we treat this?` |
| **Option labels ≤ ~12 words** | Short labels in the **tool args**, not the message body |
| **Recommended first** | Mark with `(Recommended)` on the preferred label |
| **No pack-added freeform option** | Do **not** add `Something else` / `Other` — Cursor may inject `Other…` itself |

If **`AskQuestion` is unavailable** in this session: say so in one line and ask the same choice in a single short prose question (still no multi-line option dump). There is **no** host **Other…** on this path — the typed reply is the only freeform channel. Parse disposition **and** any embedded reason from that one message (e.g. `won't fix` vs `Won't fix — will add a unit test later`); do not re-ask for a reason already present. See § **Won't fix — reason and optional todo**.

If the user picks host-provided **Other…**: ask one short free-text question in chat; map to Fix / Won't fix / Skip / revise; re-`AskQuestion` if still ambiguous. When the free text maps to Won't fix **and** already includes a reason, capture it and **do not** ask again (same short-circuit as text fallback).

## Per-finding loop

Sort findings **Critical → Major → Minor**, then by `#`. For **each** finding, complete A → B → (C if Fix) before the next.

### A — Explain (chat, read-only until user chooses Fix)

Emit a detailed block:

| Field | Content |
|-------|---------|
| **Header** | `Finding #N of M — <Sev> — \`file\` ~line` |
| **CodeAnt said** | Quote or clear paraphrase of the flag (substance, not HTML) |
| **Context** | Relevant code and/or branch diff — cite lines |
| **Rule cross-check** | CAP/AP row + **scoped** UAP / profile `codeant-uap-*.mdc` + pack policy / open-repo `.mdc` when rule-shaped (chat only). If a matched UAP has a **populated Disposition**, cite it here (chat only — not ADO). |
| **Verdict** | Already fixed \| Valid \| Partial \| Invalid \| Needs verification — with why |
| **Proposed change** | Concrete files + behaviour if Fix is chosen (**do not apply yet**) |
| **Recommendation** | Fix now \| Won't fix \| Skip — one-line rationale. When a matched UAP Disposition still fits current evidence, prefer **Won't fix** and mark the treat label `(Recommended)` — Disposition **guides**, never auto-decides. Blank Disposition never steers toward Won't fix. |

Record `threadId` / `parentCommentId` from fetch `-Json`; draft **Issue:** / **Fix:** for finalize (do not put CAP-/AP-/UAP- IDs or Disposition jargon in ADO text).

**Duplicates:** If this finding is the same hole as an earlier finding already **Accepted**, say so (e.g. covered by #1), skip re-implement unless the user asks, and still AskQuestion if ADO action might differ.

**After the explain block: go to B in the same turn** — do not wait for a typed reply.

### B — Treat (`AskQuestion` tool call)

**Stop condition:** This turn is incomplete unless you invoke **`AskQuestion`**. Do **not** write the options into the chat body.

Tool args only (ids/labels for the tool — never paste this list into chat):

| id | label |
|----|-------|
| `fix` | `Fix` or `Fix (Recommended)` |
| `dont_fix` | `Won't fix` or `Won't fix (Recommended)` |
| `defer` | `Skip` |
| `fix_remaining` | `Fix remaining` — **only when** later findings still exist after this one |

- **`prompt`:** `Finding #<N> — how should we treat this?`
- Prefer `Fix (Recommended)` when recommendation is Fix now; prefer `Won't fix (Recommended)` only when Disposition + current evidence support it.
- **Three options** when this is the last finding; **four** when more findings remain. Do not add `Something else` / `Other` (host may supply `Other…`).

| Choice | Next |
|--------|------|
| **fix** | Go to **C — Implement and confirm** |
| **dont_fix** | Go to § **Won't fix — reason and optional todo**; then next finding |
| **defer** (`Skip`) | Record; skip ADO on finalize; next finding |
| **fix_remaining** | Go to § **Early escape — Fix remaining** (must confirm first — not silent) |
| **Other…** (host) | Free-text intent in chat; map to Fix / Won't fix / Skip / Fix remaining / custom tweak, then continue. If Won't fix + reason already in the text, skip the reason re-ask (§ below). |

Chat overrides for the **current** finding: "skip this", "defer this", "won't fix", "fix it". A chat/text reply may combine disposition + reason (e.g. `Won't fix, will return to generate a unit test`) — treat as `dont_fix` **and** capture the trailing reason; do not prompt again. Chat **`fix all`** / **`fix remaining`** (any time mid-loop): enter § Early escape — still **AskQuestion-confirm**, never silent implement.

### Won't fix — reason and optional todo

Gate 1 **never** writes a UAP. After `dont_fix`:

1. **Reason (required for ADO — do not re-interview when already known):** Resolve a concise reason suitable for the ADO `**Fix:**` line, then record it for finalize. Prefer the first match; **ask only when none apply**:
   1. **User-supplied in this choice** — chat override, text-fallback reply, or host **Other…** free text that includes a reason beyond bare `won't fix` / `dont_fix` (e.g. `Won't fix — will add a unit test later`). Use that reason; **do not** ask again.
   2. **Recommendation / Disposition already on the finding** — bare `won't fix` (card click or blank typed disposition) with a one-line Recommendation rationale (or a matching populated UAP Disposition that drove the recommend). Reuse that rationale; **do not** ask again.
   3. **Otherwise** — ask one short free-text question in chat (e.g. waiting on another PR, systemic unit test later, suggestion invalid).
2. **Remediation intent (agent judgment):** Classify whether the reason implies outstanding future work the user owns.
   - No intent examples: “suggestion is invalid”, “handled in PR 123” (already done).
   - Yes intent examples: “I will add one unit test covering this pattern”, “waiting for PR 123 to merge then clean up”.
   - Intent may become a **candidate UAP Disposition** at promote time; it does **not** force promotion.
3. **Optional personal-todo (once per finding):** Only when remediation intent is **yes** **and** personal-todo is installed (user-pack `todo-add.md` **or** plugin `sicon-personal-todo`):
   - `AskQuestion`: `Create a personal todo for this deferred work?` → `yes` / `no`.
   - **no** → continue; do not load todo files.
   - **yes** → follow `/todo-add` (or the resolved `todo-add.md`) + FORMAT; create a finding-scoped todo with:
     - **CodeAnt ref:** `PR #<id> / thread <threadId>` (use `—` for thread when pasted-only / unknown)
     - **UAP:** `—` (promote may patch later)
     - Decision / next steps from the Won't-fix reason
   - Sparse-gate carve-out: triage-supplied reason, CodeAnt ref, repo, and a concrete next step from the user/reason satisfy the bar — do not re-interview for gaps already answered in this finding.
   - If personal-todo is **absent**, do **not** show the offer.
4. Record for finalize: reply + `-Status WontFix` (any Won't fix — not only Invalid). Keep session notes: reason, remediationIntent yes/no, candidateDisposition (if yes), optional `TODO-NNN`.

### C — Implement and confirm (Fix only)

1. Apply a **minimal** fix for **this finding only**.
2. Report in chat: what changed and `git diff` (or scoped diff) for the touched files.
3. **Same turn:** invoke **`AskQuestion`** (do not list options in chat).

Tool args only:

| id | label |
|----|-------|
| `accept` | `Accept (Recommended)` |
| `revise` | `Revise` |
| `revert` | `Revert / won't fix` |

- **`prompt`:** `Finding #<N> changes OK?`
- **Exactly three options** — no pack-added freeform.

| Choice | Next |
|--------|------|
| **accept** | Mark accepted; next finding |
| **revise** | User guidance → adjust code → show diff → AskQuestion again until leave finding |
| **revert** | Revert this finding's local changes (best effort); then § **Won't fix — reason and optional todo**; next finding |
| **Other…** (host) | Free-text intent; then Accept / Revise / Revert as appropriate |

If the finding was **Already fixed** on the branch, do not edit; record for ADO resolve on finalize; AskQuestion treat may still be useful (acknowledge / skip) but skip implement.

## Early escape — Fix remaining (mid-loop)

**Default stays linear.** This escape is opt-in only: treat option **`Fix remaining`**, or chat **`fix all`** / **`fix remaining`**.

### Scope

- **Include:** the **current** finding (if not yet recorded) plus **later** findings still in the queue.
- **Fix-targets (implement):** current + later where recommendation is **Fix now** (typically Valid / Partial with Fix now). Also implement duplicates covered by an earlier Fix-target if the hole is the same (one change).
- **Non-fix (record only, no code):** Invalid → won't fix (still need a short reason at rollup if missing); Already fixed → already fixed; recommendation **Skip** / **Won't fix** → skip / won't fix as recommended.
- **Never silent:** do not implement until the confirm AskQuestion returns **Proceed**.

### Steps

1. In chat (short): tally remaining — e.g. `Escape: 4 left — 3 Fix-targets, 1 Invalid (WontFix).`
2. **`AskQuestion` tool call** (do not list options in chat):

   - **`prompt`:** `Fix remaining without per-finding prompts?`
   - Options: `Proceed (Recommended)` \| `Cancel — keep linear`

3. **Cancel:** re-issue treat AskQuestion for the **current** finding (linear). Do not implement.
4. **Proceed:**
   - Briefly evaluate any later finding not yet explained (verdict + one-line proposal — chat OK, no per-item AskQuestion).
   - Implement all Fix-targets (minimal diffs).
   - Show aggregate `git diff` / summary.
   - **`AskQuestion`:** `Batch changes OK?` → `Accept (Recommended)` \| `Revise` \| `Revert batch`
5. **Accept** → mark all Fix-targets accepted; non-fix rows recorded; go to session rollup.
6. **Revise** → adjust → re-show diff → AskQuestion again.
7. **Revert batch** → revert this escape’s changes (best effort); resume linear loop at the current finding (or next undeeded).

Do **not** open with a Phase-1 batch decision table. Escape only after the loop has started (or from chat mid-loop).

## After the loop — session rollup

When every finding has a recorded choice (and Accept where Fix applied):

| # | Verdict | User choice | Accepted locally? | ADO on finalize |
|---|---------|-------------|-------------------|-----------------|
| 1 | Valid | fix | yes | reply + `-Resolve` |
| 2 | Partial | skip | — | skip |
| 3 | Invalid | won't fix | — | reply + `-Status WontFix` |
| 4 | Valid | won't fix (remediation later) | — | reply + `-Status WontFix` |

Show `git diff --stat` for the whole session (or "no code changes").

**Catalog promotion** (Valid/Partial + generalizable, after **Accept** and/or after **Won't fix**, at rollup): follow § **Catalog promotion** (Gate A → repo scope AskQuestion → UAP → Gate B). Never edit `anti-patterns.core.md` or shipped CAP-/AP- rows. Do not write product-repo overlays or PreCursor rules. Remediation intent alone does **not** make a finding promotable.

## Catalog promotion

**When:** Valid/Partial + **generalizable** finding, after **Accept** for that finding and/or after **Won't fix** for that finding, during session rollup (once per promote candidate). Product **unit test / follow-up source** is allowed when that path is chosen; never write triage tooling under the product repo.

**Three stores (profile only):**

| Store | Path |
|-------|------|
| UAP | `%USERPROFILE%\.cursor\codeant-triage\anti-patterns.user.md` (`$paths.userCatalog`) |
| Prefs | `%USERPROFILE%\.cursor\codeant-triage\promote-preferences.json` (`$paths.prefs`) |
| Profile rule | `%USERPROFILE%\.cursor\rules\codeant-uap-<n>.mdc` (user-owned; not pack-managed) |

**Repo identity:** run `Get-CodeAntRepoScope.ps1` if not already cached. Canonical match key = `remoteId` (`Collection/Project/Repository`). Display = `displayName` (folder leaf only).

**Read first:** `promote-preferences.json` (seed via Initialize if missing). Resolve **default** for Gate A: `defaultsByScope[remoteId]` then fall back to `defaultsByScope["*"]`. Applicable **actions**: those with `scope` of `*` or current `remoteId`. Legacy v1 files (`defaultActionId` + unscoped actions) are treated as scope `*`.

```powershell
powershell -NoProfile -File "$triage\Initialize-CodeAntTriageCatalog.ps1"
powershell -NoProfile -File "$triage\Get-CodeAntRepoScope.ps1"
powershell -NoProfile -File "$triage\Get-CodeAntPromotePreference.ps1" -RemoteId '<remoteId>'
powershell -NoProfile -File "$triage\Set-CodeAntPromotePreference.ps1" -AddAction -Id unit-test -Label 'Generate a unit test' -Prompt 'Generate a unit test?' -Scope '*' -SetAsDefault
```

Prefs shape (v2): `{ "version": 2, "defaultsByScope": { "<remoteId|*>": "<actionId>" }, "actions": [ { "id", "scope", "label", "kind": "follow-up", "prompt" } ] }`. Naked UAP-only **Yes** never sets a default. Pruning the catalog is the user’s job (edit the JSON).

Keep AskQuestion rules: **one card per turn**; do **not** pack-add freeform (host may supply **Other…**).

### Gate A — preference + learn

#### No default (resolved default is null)

`AskQuestion` tool call (do not list options in chat):

- **`prompt`:** `Promote this finding to your user anti-pattern catalog?`
- Options (tool args): `yes` — `Yes — promote to UAP (Recommended)` \| `no` — `No`

| Choice | Next |
|--------|------|
| **yes** | Learning proceeds → **Repo scope AskQuestion** → append UAP → **Gate B**. **Do not** set preference default. |
| **no** | Skip; stop catalog promotion for this finding (do **not** ask for a custom action). |
| **Other…** (host) | Ask one short free-text question for the approach → learning proceeds → **Repo scope AskQuestion** → persist action with that Scope via `Set-CodeAntPromotePreference.ps1 -AddAction … -Scope <scope> -SetAsDefault` → run follow-up once → write UAP → **Gate B**. |

#### Default set (resolved for current remote)

Primary `AskQuestion` using the applicable action’s `prompt`:

- **`prompt`:** e.g. `Generate a unit test?`
- Options: `yes` — `Yes (Recommended)` \| `no` — `No`

| Choice | Next |
|--------|------|
| **yes** | Perform the follow-up → learning proceeds → **Repo scope AskQuestion** → append UAP → **Gate B**. |
| **no** | Next turn `AskQuestion`: `Still promote to UAP?` → `yes` / `no`. **yes** → learning proceeds → **Repo scope AskQuestion** → UAP only → **Gate B**. **no** → skip. |
| **Other…** (host) | Free-text approach → `AskQuestion`: `Make this the new promote default?` → `yes` / `keep`. Then learning proceeds → **Repo scope AskQuestion** (one scope card for the whole promote). **yes** → add/update action with that Scope + `defaultsByScope[scope]=id` (keep previous actions). **keep** → run approach once without changing defaults. Write UAP → **Gate B**. |

**Always** write UAP when learning proceeds (primary Yes, Other that promotes, or fallback UAP Yes).

### Repo scope AskQuestion (before UAP write)

After learning proceeds, **before** appending UAP (and before persisting any new/updated preference action from **Other…** in this promote). Mention `displayName` / `remoteId` in chat only.

- **`prompt`:** `Scope for this promote?`
- Options: `this` — `This repo (Recommended)` \| `all` — `All repos`

| Choice | Scope value | Repo (display) column |
|--------|-------------|------------------------|
| **this** | current `remoteId` | `displayName` |
| **all** | `*` | `-` |

Use this Scope for: UAP row, Gate B `codeantRepo`, and any preference action default written in the same promote. **Do not** ask scope again for Gate B.

### Write UAP

Append next **`UAP-*`** row to `anti-patterns.user.md` (8 columns). If the file has a legacy 7-column header, upgrade it and pad **every existing data row** with an empty **Disposition** cell before appending. This keeps `Enforced by` in its rendered column. Readers still treat an unmodified legacy 7-column file as blank Disposition.

| ID | Scope | Repo | Pattern | Signals | Fix direction | Disposition | Enforced by |

| Column | Meaning |
|--------|---------|
| **Fix direction** | How violations should ultimately be solved |
| **Disposition** | Temporary handling guidance for matching CodeAnt findings while remediation is outstanding. **Blank** = standard UAP (no Won't-fix bias). **Populated** = one-line free text; preferred shape `Recommend WontFix — <rationale>` |

**Disposition on write:**

| Promote path | Disposition cell |
|--------------|------------------|
| Fix → Accept (or no remediation intent) | leave **blank** |
| Won't fix + remediation intent | candidate one-liner from the reason (typically `Recommend WontFix — <rationale>`); user may refine via Other… / chat before write |

Todo creation is **not** required to set Disposition.

**After append — optional todo patch:** If this finding has a session `TODO-NNN` or a personal-todo with matching **CodeAnt ref** `PR #<id> / thread <threadId>`, and personal-todo is installed: load todo-add/FORMAT **only now**, set that item’s **UAP** field to `UAP-N`. If no todo exists, skip (do not offer create at promote solely for the UAP link).

Then continue to **Gate B**.

### Gate B — profile Cursor rule (optional)

After a successful UAP append only:

1. `AskQuestion`: **`prompt`** `Also create a profile Cursor rule for this UAP?` → `yes` — `Yes (Recommended)` \| `no` — `No`.
2. **no** → done with promotion.
3. **yes** → derive **path** globs from the finding’s repo-relative path (e.g. `src/A/B/C.cs`):

| id | label | Glob |
|----|-------|------|
| `parent` | `Parent directory (Recommended)` | parent folder + `/**` → `src/A/B/**` |
| `narrow` | `This file only` | exact relative path → `src/A/B/C.cs` |
| `widen` | `Widen (grandparent)` | grandparent + `/**` → `src/A/**` |

`AskQuestion` path scope (one card; host **Other…** → custom glob in chat; reject empty). Repo Scope was already chosen above — inherit it.

4. Write or update **only** `%USERPROFILE%\.cursor\rules\codeant-uap-<n>.mdc` (same `<n>` as the UAP id). **Never** under the product repo. **Never** add these files to pack `managed`.

```yaml
# .mdc body example — do not wrap in YAML --- (Cursor command catalog treats extra --- as a second command)
description: CodeAnt Triage UAP-N — <short pattern>
globs:
  - <chosen>
alwaysApply: false
codeantRepo: <remoteId|*>
codeantRepoDisplay: <displayName|->

# UAP-N — <pattern>
# <summary + fix direction mirrored from the UAP row>
# optional: Disposition: …
```

- Embed `UAP-N` in filename and description for lookup.
- If `codeant-uap-<n>.mdc` already exists: **merge** globs only when existing `codeantRepo` matches this promote’s Scope (case-insensitive). If Scope **mismatches**, do **not** merge — warn in chat (one file per UAP id; change scope by editing the `.mdc` manually).
- On engage, ignore profile rules whose `codeantRepo` is neither `*` nor the current `remoteId`.

## Clear Disposition (remediation complete)

When remediation for a UAP is finished, **clear only the Disposition cell** — do **not** delete the UAP row or its profile rule.

**Engage when** (any):

- User says *remediation complete for UAP-N*, *clear disposition on UAP-N*, *UAP-N remediation done/finished*, or during triage *this remediation is done* (for a matched UAP).
- Optional personal-todo Done handoff offers clear (see below).

**Steps:**

1. Resolve `UAP-N` (from message, matched finding, or todo **UAP** field). If ambiguous → `AskQuestion` to pick the row.
2. Confirm when the user did not name an id clearly.
3. Edit `anti-patterns.user.md`: set that row’s Disposition to empty (keep all other columns). If the matching `codeant-uap-<n>.mdc` still embeds a Disposition line, remove that line only.
4. Never clear silently; never delete the UAP.

### Finalize gate

1. Emit the rollup table above.
2. **AskQuestion tool call** (clickable cards) — short prompt only; **do not** list options in chat:

   - **`prompt`:** `Ready to finalize PR #<id>?`
   - Options (tool args only): `resolve` (Recommended) \| `reply-only` \| `commit-only` \| `no` — no pack-added freeform

3. On **resolve** / **commit-only**: if there are local changes, commit then (for **resolve**) push → `Post-CodeAntPrThreadReply.ps1` per non-**skip** (`defer`) finding.

**Commit message (mandatory for Planned commit + `git commit`):**

```text
<type>(<scope>): <short summary>

<1–2 sentence body — what changed and why>

#NNNNN   ← optional; only when linking a work item
```

- **Never** append `Co-authored-by:` (name-only or with email).
- **Never** include email addresses anywhere in the message (including `cursoragent@cursor.com`).
- This pack honors the user's attribution exception: agent co-author trailers are out of scope for CodeAnt Triage finalize. If Cursor or another rule would add them, strip them before commit.

```powershell
powershell -NoProfile -File "$triage\Post-CodeAntPrThreadReply.ps1" -PullRequestId <id> -ThreadId <t> -ParentCommentId <c> -Reply "**Issue:** …`n**Fix:** …" [-Resolve] [-Status WontFix]
```

Use **double-quoted** `-Reply` so `` `n `` becomes a real newline.

| User choice | `-Resolve` | `-Status WontFix` |
|-------------|------------|-------------------|
| **fix** (accepted + pushed) | yes | — |
| **won't fix** (`dont_fix`) — any verdict | no | yes |
| **already fixed** | yes | — |
| **skip** (`defer`) | skip post | — |

**Scope:** `resolve` / `reply-only` / `commit-only` are **CodeAnt Triage only** — not general git verbs.

## ADO PR reply text (human-readable — mandatory)

Two lines only:

```text
**Issue:** <what CodeAnt flagged, everyday language>
**Fix:** <what we did, or why no change>
```

For Won't fix, put the captured reason on the `**Fix:**` line. Never include CAP-/AP-/UAP- IDs, pack paths, `.mdc` paths, Disposition field names, "Invalid:", "parity deferred", or catalog jargon in ADO replies.

## Invariants (disposition + todo)

1. Gate 1 never creates UAPs.
2. Promotion remains based on generalizability (Valid/Partial + generalizable).
3. Blank Disposition never steers toward Won't fix.
4. Populated Disposition guides but does not decide.
5. Clearing Disposition never deletes or disables the UAP.
6. UAP Scope scans include rows regardless of Disposition.
7. Personal-todo is never needed for later Gate 1 recommendations.
8. Fix → Promote gains no todo prompts and no todo file reads.
9. Todo files load only after explicit acceptance of a todo operation (create or post-promote patch / Done handoff).

## Common false positives

| Pattern | Check |
|---------|--------|
| Narrow CodeAnt diff | CAP-1; full branch diff |
| Already fixed on branch | CAP-2; HEAD / earlier commits |
| Missing XML on changed public | AP-3; core row + optional open-repo `public-xml-summaries.mdc` |
| Reject valid inheritdoc | AP-6; keep `/// <inheritdoc />` |

## Output format (canonical)

### Header + optional index

(See § Setup — short index.)

### Per finding

Explain block → treat AskQuestion → (if Fix) diff report → confirm AskQuestion.

### Early escape (optional)

Treat **`Fix remaining`** or chat `fix all` → confirm AskQuestion → batch implement → batch accept AskQuestion → rollup.


(See § After the loop.)

| # | Path | User choice | Local change | Thread | ADO action |
|---|------|-------------|--------------|--------|------------|

**Planned commit:** `<message sketch>` — subject + body (+ optional `#NNNNN` only). **No** `Co-authored-by`, **no** email addresses.
