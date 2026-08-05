---
name: todo-explain
description: Personal backlog in local Cursor memory via /todo-* slash commands
---
# todo-explain — expand a backlog item (Ask only)

Read-only. User-scoped memory — not org/repo tooling. **Do not implement.**

## When

User invokes `/todo-explain`, `/todo explain` (via [`todo.md`](todo.md)), or asks to explain / unpack a personal todo without starting work.

**Do not trigger on** bare code comments like `// TODO: fix` — only personal-backlog intent (slash command, *explain todo*, *what does TODO-NNN mean*, title hint).

## Resolve target (in order)

Same as [`todo-resume.md`](todo-resume.md) § Resolve target:

1. Explicit `TODO-NNN` in command or message (e.g. `TODO-001`).
2. Title or slug substring match against **Active** items in `todos.md` (e.g. *flyby*, *v1 feed*). Include **Parked** if the user names a parked epic.
3. Same-chat context after a list: *that one*, *that todo*, *the blocked one* → item just shown in this chat, or the only Active item if unambiguous.
4. `/todo-explain` with no arg and **exactly one** Active item → use it.
5. Otherwise → ask which (repeat ids + titles); do not guess.

## Do

1. Read `%USERPROFILE%\.cursor\memory\todos.md` — locate the resolved item. Read **Planning context** when present and G-tier / scope boundaries matter.
2. Read the linked **Transcript** path from the item table when present.
3. Reply with structured narrative (not the one-line table from `/todo-list`):
   - **What it is** — one sentence
   - **Why it exists** — from Transcript summary + transcript
   - **Scope lane** — Personal / Contrib-user / Org (when applicable)
   - **Sequencing** — blocked by, blocks, parallel tracks
   - **Decision** — bullets from the item; do not invent
   - **Open questions** — only if stub/sparse or ambiguity remains
   - **Known vs inferred** — label anything not grounded in Decision or Transcript
4. If item is **Done**, explain outcome only. If **Parked**, explain promote-when and scope sketch.
5. End with: *"Ready to work? `/todo-resume TODO-NNN` for a briefing."* — do not offer Agent mode unless the user asks.

## Do not

- Edit `todos.md` or transcripts
- Implement, commit, or spawn implementation work
- Collapse into `/todo-resume` (single next step only) unless the user asks for that explicitly

Do **not** use prior chats unless user @-links them.
