---
name: todo-howto
description: Personal backlog in local Cursor memory via /todo-* slash commands
---
# todo-howto — personal backlog usage guide

Read-only. User-scoped memory — not org/repo tooling. **Do not read** `todos.md` or transcripts.

## When

User invokes `/todo-howto`, `/todo howto`, or asks how personal todos / `todo-*` commands work.

## Do

Reply with the guide below **verbatim in structure** (paths and commands must match). Do not improvise a different workflow.

---

## Personal todo — how to

### Commands

| Command | When to use |
|---------|-------------|
| `/todo-howto` | This guide |
| `/todo-init` | First run — seed `memory/` templates (never overwrites existing files) |
| `/todo-list` | See backlog at a glance (offers `/todo-init` if `todos.md` is missing) |
| `/todo-explain` (+ optional `TODO-NNN`) | Understand an item before committing (Ask, read-only) |
| `/todo-add` … | Capture or refine an item (agent may push back if sparse) |
| `/todo-resume` (+ optional `TODO-NNN`) | Briefing: decision + one next step to start work |
| `/todo list` / `explain` / `add` / `resume` / `howto` / `init` | Same via [`todo.md`](todo.md) router |

### Recommended flow

1. **First time:** `/todo-init` (Agent) — or `/todo-list` will offer init if `todos.md` is missing
2. **New chat, Ask mode** → `/todo-list`
3. Need depth? → `/todo-explain TODO-NNN` or `/todo explain NNN`
4. Ready to work? → `/todo-resume` (fresh chat if the thread is long)
5. Switch to **Agent** when implementing; honour **Blocked by**

### Where data lives

| What | Path |
|------|------|
| Backlog | `%USERPROFILE%\.cursor\memory\todos.md` |
| Item format | `%USERPROFILE%\.cursor\memory\todos\FORMAT.md` |
| Chat arcs | `%USERPROFILE%\.cursor\memory\todos\transcripts\` |
| Session flow | `%USERPROFILE%\.cursor\memory\memory.md` § Personal todos |

Backlog content is **user-owned**. Pack/plugin updates do **not** overwrite `todos.md`.

### Install

**Team Marketplace:** install **Sicon Personal Todo**, reload Cursor, then `/todo-init`.

**Local dogfood (ai-devtools user pack):**

```powershell
.\bootstrap\Install-UserPack.ps1 -Pack personal-todo
```

Then `/todo-init` (or run the packs script directly):

```powershell
& "$env:USERPROFILE\.cursor\packs\personal-todo\scripts\Initialize-PersonalTodoMemory.ps1"
```

First run only: init seeds memory templates when files are missing.

### Ordering in `todos.md`

- **Active:** non-blocked by id, then blocked by id
- **Done / Parked:** one line per item, by id

---

End with: *"List now? `/todo-list` — explain an item? `/todo-explain TODO-NNN`."*
