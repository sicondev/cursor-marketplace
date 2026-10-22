<!-- contrib-managed: codeant-triage@0.6.0 — source: ai-devtools/contrib/codeant-triage/ — prefer PR there; local edits may be overwritten on sync -->

# UAP scan — shared fix loop

**Shipped path:** `uapscan-fix-loop.md` at the install root (user pack) or `content/uapscan-fix-loop.md` (plugin). Resolve via `Get-CodeAntTriagePaths.ps1` (`uapscanFixLoop`).

Used by `/codeant-triage-uapscan` and `/codeant-triage-uapscan-deepscan` when the session enters the fix path. **Mandatory read** before treat/confirm AskQuestions.

Findings are **UAP violations** (local catalog / profile rules) — not CodeAnt (ADO) PR comments. No `threadId`, no ADO replies, no catalog promote. **Disposition** on UAP rows is ignored for recommend/treat here (PR-triage Gate 1 only); still load Scope-matching UAPs regardless of Disposition.

## Hard bans (this loop)

1. **No finalize** — never AskQuestion for `resolve` / `reply-only` / `commit-only`.
2. **No commit / push** — do not run `git commit` or `git push` from these sessions.
3. **No ADO posts** — do not run `Post-CodeAntPrThreadReply.ps1`.
4. **No catalog promote** — do not append UAP rows or create `codeant-uap-*.mdc` from this loop.
5. **Abort anytime** — treat/confirm/escape AskQuestions include **Stop session**; chat `abort` / `stop` ends the session with a short rollup of work so far.

## Workflow overview

```text
for each finding (default):
  explain (chat) → AskQuestion TOOL CALL (fix | don't fix | defer [| fix remaining] | abort)
  → if fix: implement → show diff → AskQuestion TOOL CALL (accept | revise | revert | abort)
  → iterate until leave finding
→ session rollup (table + git diff --stat) — STOP (no finalize)
```

**Never** replace an AskQuestion tool call with chat text like `Reply with one of: Fix | Don't fix | …`.

## AskQuestion UX rules (non-negotiable)

**Hard rule:** Fixed-choice moments (**treat**, **confirm**, **escape**, **abort gates**) require the Cursor **`AskQuestion` tool** — a **tool call** in the same turn as the explain/diff — not prose.

**Failure modes (do not do these):**

- Writing `Reply with one of:` / `Choose:` / numbered `1. Fix` / pipe lists in the chat message
- Asking the user to type option labels
- Emitting option labels in markdown “to stand in for” AskQuestion

**Correct pattern:** Put the full explain (or diff / rollup) in chat. **Do not list the options in chat.** End the turn by invoking **`AskQuestion`** once (at most one AskQuestion per assistant message). Wait for the tool result before continuing.

**No naked AskQuestion (hard gate):** At an **entry gate** (Treat per finding, Fix-remaining confirm) the card is only valid immediately after its context block in the same turn — Treat: the § A explain block for this finding (Header, UAP/rule, Context, Verdict, Proposed change, Recommendation; no field omitted); escape: the tally. The discovery index is **not** a context block, and neither is an earlier finding's or earlier turn's block; a missing/stale block is emitted/re-emitted first, same turn. At a **continuation gate** (Confirm after Fix, Revise re-ask, batch accept) do **not** re-emit § A — context carries over from the answered Treat card across the implementation turn — but the card must be immediately preceded by a Confirm block (finding recap, files/behaviour changed, diff summary/stat, checks); edit/check tool output alone is not that block. A card without its applicable block is a failed turn, not a shortcut.

| Rule | Why |
|------|-----|
| **`AskQuestion` tool call — never a typed menu** | Only the tool yields clickable cards |
| **Do not paste option labels into chat** | Models copy them as “Reply with one of…” |
| **Explain / diff / rollup in chat only, immediately before the card** | Cards bury detail; a card without its block gives the user nothing to decide from |
| **`prompt` ≤ one short sentence** | e.g. `Finding #1 — how should we treat this?` |
| **Option labels ≤ ~12 words** | Short labels in the **tool args**, not the message body |
| **Recommended first** | Mark with `(Recommended)` on the preferred label — justified by the preceding block's Verdict/Recommendation |
| **No pack-added freeform option** | Do **not** add `Something else` / `Other` — Cursor may inject `Other…` itself |

If **`AskQuestion` is unavailable** in this session: say so in one line, emit the same context block first, then ask the same choice in a single short prose question after it (still no multi-line option dump). That prose question is the complete gate for that moment — it stands in for the `AskQuestion` invocation in every stop condition below (Treat, Confirm, escape, abort gates), so the gate can complete without the tool. There is **no** host **Other…** on this path — the typed reply is the only freeform channel. Parse disposition **and** any embedded reason from that one reply (e.g. `don't fix` vs `Don't fix — will handle it separately`); do not re-ask for a reason already present.

If the user picks host-provided **Other…**: ask one short free-text question in chat; map to Fix / Don't fix / Defer / revise / abort; re-`AskQuestion` if still ambiguous.

## Per-finding loop

Sort findings by file path, then by `#` (or severity if the discovery command assigned one). For **each** finding, complete A → B → (C if Fix) before the next.

### A — Explain (chat, read-only until user chooses Fix)

| Field | Content |
|-------|---------|
| **Header** | `Finding #N of M — \`UAP-*\` — \`file\` ~line` |
| **UAP / rule** | Pattern + signals from scoped catalog row and/or `codeant-uap-*.mdc` (chat only) |
| **Context** | Relevant code — cite lines |
| **Verdict** | Hit \| Partial \| False positive \| Already fixed — with why |
| **Proposed change** | Concrete files + behaviour if Fix is chosen (**do not apply yet**) |
| **Recommendation** | Fix now \| Don't fix \| Defer — one-line rationale |

**Duplicates:** If this finding is the same hole as an earlier finding already **Accepted**, say so, skip re-implement unless the user asks, and still AskQuestion.

**After the explain block: go to B in the same turn** — do not wait for a typed reply.

### B — Treat (`AskQuestion` tool call)

**Stop condition (two parts, both required):** This turn is incomplete unless (1) the § A explain block for **this** finding was emitted in chat in this turn, **and** (2) you then invoke **`AskQuestion`** — or, if `AskQuestion` is unavailable, ask the single short prose question after that block per § AskQuestion UX rules above, which completes this gate in its place. The card (or prose question) without (1) violates § No naked AskQuestion. Do **not** write the options into the chat body.

Tool args only (ids/labels for the tool — never paste this list into chat):

| id | label |
|----|-------|
| `fix` | `Fix` or `Fix (Recommended)` |
| `dont_fix` | `Don't fix` |
| `defer` | `Defer` |
| `fix_remaining` | `Fix remaining` — **only when** later findings still exist after this one |
| `abort` | `Stop session` |

- **`prompt`:** `Finding #<N> — how should we treat this?`
- Prefer `Fix (Recommended)` when recommendation is Fix now.
- Do not add `Something else` / `Other` (host may supply `Other…`).

| Choice | Next |
|--------|------|
| **fix** | Go to **C — Implement and confirm** |
| **dont_fix** | Record; next finding |
| **defer** | Record; next finding |
| **fix_remaining** | Go to § **Early escape — Fix remaining** (must confirm first — not silent) |
| **abort** | Session rollup of work so far → **stop** (no finalize) |
| **Other…** (host) | Free-text intent; map to Fix / Don't fix / Defer / Fix remaining / abort, then continue |

Chat overrides for the **current** finding: "defer this", "fix it". Chat **`fix all`** / **`fix remaining`**: enter § Early escape. Chat **`abort`** / **`stop`**: rollup and stop.

### C — Implement and confirm (Fix only)

1. Apply a **minimal** fix for **this finding only**.
2. After all edit/check tool calls, emit the **Confirm block** in chat (continuation gate per § No naked AskQuestion — no § A re-emit; edit-tool cards / `git diff` tool output alone do not count): finding recap (one line), files changed + behaviour, diff summary/stat (key hunks), checks run + result (or “not run”).
3. **Immediately after that block:** invoke **`AskQuestion`** (do not list options in chat). Never go directly from an edit/check tool result to the confirm card.

Tool args only:

| id | label |
|----|-------|
| `accept` | `Accept (Recommended)` |
| `revise` | `Revise` |
| `revert` | `Revert / don't fix` |
| `abort` | `Stop session` |

- **`prompt`:** `Finding #<N> changes OK?` — only immediately after the § C Confirm block (continuation gate, § No naked AskQuestion)

| Choice | Next |
|--------|------|
| **accept** | Mark accepted; next finding |
| **revise** | User guidance → adjust code → new Confirm block (delta since last diff shown + checks) → AskQuestion again until leave finding |
| **revert** | Revert this finding's local changes (best effort); record don't fix; next finding |
| **abort** | Keep or revert current finding per user chat if unclear; session rollup → **stop** |
| **Other…** (host) | Free-text intent; then Accept / Revise / Revert / abort as appropriate |

If the finding was **Already fixed**, do not edit; AskQuestion treat may still acknowledge / defer; skip implement.

## Early escape — Fix remaining (mid-loop)

**Default stays linear.** Escape is opt-in: treat option **`Fix remaining`**, or chat **`fix all`** / **`fix remaining`**.

### Scope

- **Include:** the **current** finding (if not yet recorded) plus **later** findings still in the queue.
- **Fix-targets (implement):** current + later where recommendation is **Fix now**.
- **Non-fix (record only):** False positive / Already fixed / Defer / Don't fix as recommended.
- **Never silent:** do not implement until the confirm AskQuestion returns **Proceed**.

### Steps

1. In chat (short): tally remaining — counts plus **one concise line per in-scope finding** (current + later): `#N — location — verdict — recommendation` (evaluate any later finding not yet explained here, before the confirm card, so the user sees every target and its rationale before authorising) — e.g. `Escape: 4 left — 3 Fix-targets, 1 skip.` followed by `#2 — src/App.cs ~40 — Hit — Fix now`, `#3 — …`.
2. **`AskQuestion` tool call** (do not list options in chat):

   - **`prompt`:** `Fix remaining without per-finding prompts?` — only immediately after the step-1 enumerated tally in the same turn (§ No naked AskQuestion)
   - Options: `Proceed (Recommended)` \| `Cancel — keep linear` \| `Stop session`

3. **Cancel:** re-issue treat AskQuestion for the **current** finding. Do not implement.
4. **Stop session:** rollup → stop.
5. **Proceed:**
   - Implement all Fix-targets enumerated in step 1 (minimal diffs).
   - Show the aggregate Confirm block (targets implemented, files changed, aggregate diff summary/stat, checks).
   - **`AskQuestion`:** `Batch changes OK?` → `Accept (Recommended)` \| `Revise` \| `Revert batch` \| `Stop session` — only immediately after the aggregate Confirm block (continuation gate, § No naked AskQuestion)
6. **Accept** → mark Fix-targets accepted; non-fix recorded; go to session rollup.
7. **Revise** → adjust → new aggregate Confirm block → AskQuestion again.
8. **Revert batch** → revert this escape’s changes (best effort); resume linear loop.
9. **Stop session** → rollup → stop.

## After the loop — session rollup (end)

When every finding has a recorded choice (and Accept where Fix applied), **or** after abort:

| # | UAP | Path | Verdict | User choice | Accepted locally? |
|---|-----|------|---------|-------------|-------------------|
| 1 | UAP-1 | `path` | Hit | fix | yes |

Show `git diff --stat` for the whole session (or "no code changes").

**Then stop.** Do not open a finalize gate. Remind the user they can commit separately if they want — this command will not commit.
