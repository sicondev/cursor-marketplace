---
name: todo-add
description: Personal backlog in local Cursor memory via /todo-* slash commands
---
# todo-add — add or refine a personal backlog item

User-scoped memory — not org/repo tooling.

## When

User invokes `/todo-add`, `/todo add` (via [`todo.md`](todo.md)), asks to **add**, **capture**, **refine**, or **update** a personal todo, or extends the backlog (e.g. *add a todo for attribution*, *refine personal todo*).

**Do not trigger on** bare code comments like `// TODO: fix`.

## Sparse gate (mandatory — before any write)

Read [`%USERPROFILE%\.cursor\memory\todos\FORMAT.md`](../memory/todos/FORMAT.md) § Quality bar and § Sparse signals.

**If the request or proposed capture is sparse → push back. Do not edit `todos.md` or create a transcript yet.**

1. State briefly what is missing (1–3 bullets — tie to sparse signals).
2. Ask **1–2 questions** only — the highest-leverage gaps first. Use `AskQuestion` when choices are clear; otherwise ask in prose.
3. After answers, re-check the bar. Repeat until minimum bar met **or** user explicitly opts out (see below).

**Opt-out (rare):** User says *park it anyway*, *stub for now*, or *capture what we have* → write with **Status** `parked` or note `*(stub — sparse capture)*` in Transcript summary; still assign next id and link transcript.

**CodeAnt Triage carve-out:** When the user already accepted a CodeAnt Triage “create personal todo” offer for a Won't-fix finding, treat triage-supplied **reason**, **CodeAnt ref** (`PR #<id> / thread <threadId>`), **repo**, and a concrete next step from that reason as satisfying the quality bar — do not re-interview for gaps already answered in that finding. Still write Decision / Transcript summary / Next steps from that context.

## Question bank (pick 1–2 per turn — do not dump all)

| Gap | Ask |
|-----|-----|
| Why | What problem does this todo solve? Why now vs later? |
| Scope | What is **in** and **explicitly out** of scope? |
| Sequence | What blocks this? What does this block? |
| Decision | What did you already decide vs what is still open? |
| Surface | Repo / path / pack area — where will work land? |
| Next step | What is the **first** concrete action (not "figure out later")? |
| Transcript | Which prior chat turn or decision should the transcript preserve? |

## Resolve target (refine)

- **New item** → next `TODO-NNN` (max existing id + 1).
- **Refine existing** → user names `TODO-NNN`, title hint, or same-chat context after `/todo-list`.

## Do (only after sparse gate passes)

1. Read `todos.md` and [`FORMAT.md`](../memory/todos/FORMAT.md).
2. Write or update the item in `todos.md` (Active, Done, or Parked as appropriate) at the position required by FORMAT § Section ordering. Include optional **CodeAnt ref** / **UAP** rows when CodeAnt-sourced (see FORMAT). Before compacting a CodeAnt-sourced item into a Done line, capture its real `UAP-N` and preserve it in that line.
3. Create or append the linked transcript under `todos/transcripts/` — at least one **User** turn with what they confirmed, not agent invention alone.
4. If dependency chain changed, update cross-refs on related items and `memory.md` § Personal todos when needed.
5. Reply with id, title, status, Blocked by, first next step — offer `/todo-resume` when Active.
6. If this update moved Status to **done** and the item had a real **UAP** (`UAP-N`) before compaction, run § **CodeAnt Disposition handoff** once in the same turn, before the completion reply.

## CodeAnt Disposition handoff (optional)

Only when all of:

- Item **UAP** is `UAP-N` (not `—` / missing).
- Status just became **done** (this refine/complete turn).
- `%USERPROFILE%\.cursor\packs\codeant-triage\anti-patterns.user.md` exists (`Test-Path`).

Then **once** (do not repeat if user already declined this session for this id):

1. `AskQuestion`: `Clear Disposition on <UAP-N> now that this todo is done?` → `yes` / `no`.
2. **yes** → edit that UAP row’s Disposition cell to empty only; if `codeant-uap-<n>.mdc` embeds a Disposition line, remove that line only. Do **not** delete the UAP or rule.
3. **no** → leave Disposition unchanged.
4. Never clear silently. Users can clear Disposition without personal-todo via CodeAnt Triage clear-disposition triggers.

## Do not

- Invent decisions the user did not confirm.
- Fill gaps with generic placeholders (`TBD`, `deferred`, `see plan`) to pass the gate.
- Skip the transcript for new Active items.
- Load or edit CodeAnt UAP catalogs except for the explicit Disposition handoff above (or when CodeAnt Triage asked for a create/patch).
