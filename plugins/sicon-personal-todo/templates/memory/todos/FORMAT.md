# Personal todo item format

Use when adding a new item to [`../todos.md`](../todos.md). Agents: follow [`~/.cursor/commands/todo-add.md`](../../../commands/todo-add.md) — **push back if sparse** before writing.

Create a matching rolled-up transcript in [`transcripts/TODO-<id>-<slug>.md`](transcripts/README.md).

## Section ordering (`todos.md`)

| Section | Order | Format |
|---------|-------|--------|
| **Active** | Non-blocked first (by id), then **blocked** (by id) | Full item template below |
| **Done** | By id | **One line** per item: id, title, done date, transcript link, short outcome; retain `UAP-N` for CodeAnt-sourced items |
| **Parked** | By id / epic title | **One line** per epic (detail stays in transcript until promoted) |

When adding or moving items, insert at the correct position — do not append out of order.

## Quality bar (minimum before write)

An Active item is **ready to capture** only when all of the following hold:

| Section | Minimum |
|---------|---------|
| **Status table** | Status, Blocked by (or `—` if ready), Repo / area, Transcript link, Remind phrase |
| **Decision** | ≥2 bullets — each states something **agreed**, not a restatement of the title |
| **Transcript summary** | 1–2 sentences: *why this exists* and *why sequenced here* |
| **Next steps** | ≥1 **concrete** first action (verb + artifact/path); no sole placeholder |
| **Transcript file** | ≥1 **User** turn with confirmed intent; Capture moment explains why the todo exists |

**Parked** epics may be lighter but still need: promote-when (or trigger), scope sketch, and link to motivation (transcript or prior todo).

## Sparse signals (push back — ask questions)

Treat as **sparse** if any apply:

- User message is a one-liner with no confirmed decisions.
- **Decision** would be copied from the user's sentence with no added specificity.
- **Blocked by** is missing, vague (*future work*), or circular.
- **Repo / area** is unknown or generic (*the repo*, *tooling*).
- **Next steps** are only placeholders (*draft ADR later*, *deferred*, *TBD*).
- Transcript would be **agent-invented** with no user turns from this or a named prior chat.
- **Transcript summary** does not explain sequencing (*why after X, before Y*).
- Refine request adds a dependency but not **what changes** in Decision or next step.

When sparse: **do not write** — follow `todo-add.md` § Sparse gate.

## Item template

```markdown
### TODO-NNN: Title

| Field | Value |
|-------|-------|
| **Status** | blocked \| ready \| in-progress \| done |
| **Blocked by** | … |
| **Repo / area** | … |
| **Transcript** | [todos/transcripts/TODO-NNN-slug.md](todos/transcripts/TODO-NNN-slug.md) |
| **Remind phrase** | "…" |
| **CodeAnt ref** | PR #<id> / thread <threadId> — *optional; omit when N/A* |
| **UAP** | UAP-N or `—` — *optional; omit when N/A* |

**Decision**

What was agreed (bullets or short paragraph).

**Transcript summary**

Short rollup — full conversation arc is in the linked Transcript file.

**Next steps**

1. …
```

### Optional CodeAnt Triage fields

Omit **CodeAnt ref** and **UAP** unless the item came from CodeAnt Triage Won't-fix deferred remediation (or was later linked).

| Field | Use |
|-------|-----|
| **CodeAnt ref** | `PR #<id> / thread <threadId>` — correlates a todo with a finding before `UAP-N` exists |
| **UAP** | `—` until promote patches `UAP-N`; then the catalog id for Disposition clear handoff |

When Status moves to **done** and **UAP** is a real `UAP-N`, capture it before compacting the item, retain it in the Done line, then follow [`todo-add.md`](../../../commands/todo-add.md) § CodeAnt Disposition handoff in that same completion turn (offer once; never clear silently).
