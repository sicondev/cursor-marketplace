---
name: todo-list
description: Personal backlog in local Cursor memory via /todo-* slash commands
---
# todo-list — list personal backlog

Read-only. User-scoped memory — not org/repo tooling.

## When

User invokes `/todo-list` or asks to see their personal todo list.

## Do

1. Try to read `%USERPROFILE%\.cursor\memory\todos.md`.
2. **If the file is missing** (path not found): stop the list flow. Say the backlog is not seeded yet and offer **`/todo-init`** (or `/todo init`). Do **not** create files, do **not** run the init script from this lane, do **not** invent items. End the turn.
3. If the file **exists** (including empty Active/Done/Parked sections): report **Active** items in file order (non-blocked by id, then blocked by id) in a short table: id, title, status, Blocked by, first next step.
4. Mention **Done** / **Parked** only if non-empty — one line per item each (id/title + brief outcome or promote-when).
5. Offer: *"How to? `/todo-howto` — explain with `/todo-explain` or a title hint — resume with `/todo-resume` — add/refine with `/todo-add` — fresh Ask chat if this thread is already long."*  
   Do **not** offer `/todo-init` when `todos.md` already exists.

Do **not** read transcript files for a list-only request.
