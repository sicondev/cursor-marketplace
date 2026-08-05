## Personal todos

Backlog: **[`todos.md`](todos.md)** — each item has **Decision**, **Transcript summary**, **Next steps** inline.

| Piece | Location |
|-------|----------|
| Rolled-up conversation arc | [`todos/transcripts/TODO-<id>-<slug>.md`](todos/transcripts/README.md) |
| Item format (when adding) | [`todos/FORMAT.md`](todos/FORMAT.md) |

**Commands (global):** `/todo-howto` · `/todo-init` · `/todo-list` · `/todo-explain` · `/todo-add` · `/todo-resume` (optional `TODO-NNN`) · `/todo` router  
**Rule (on demand):** `~/.cursor/rules/todo-triggers.mdc`

**First run:** `/todo-init` seeds `memory/` when missing (`/todo-list` offers init if `todos.md` is absent).  
**Adding items:** `/todo-add` — agent **pushes back** if capture is too sparse; see [`todos/FORMAT.md`](todos/FORMAT.md) § Quality bar.

## Session resume (recommended flow)

1. **First time:** `/todo-init` if `todos.md` is missing (or accept the offer from `/todo-list`).
2. **New chat**, **Ask mode** → `/todo-list` or *"show my personal todo list"*
3. Need more context before committing? `/todo-explain` or a title hint — richer narrative, still read-only.
4. Pick an item to work on: `/todo-resume`, *resume that one*, or a title hint. Use `/todo-resume TODO-001` once you know the id from the list.
5. **Fresh chat** if the current thread is already long or unrelated — agent reads todo + transcript from disk only; not old chats unless you @ them.
6. Switch to **Agent** when ready to implement; honour **Blocked by**.
