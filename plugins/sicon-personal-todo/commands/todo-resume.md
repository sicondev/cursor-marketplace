---
name: todo-resume
description: Personal backlog in local Cursor memory via /todo-* slash commands
---
# todo-resume — open a todo as session context

Read-only briefing unless user switches to Agent and asks to implement.

## When

User invokes `/todo-resume`, `/todo resume` (via [`todo.md`](todo.md)), or asks to resume / use a personal todo as opening context.

**Do not trigger on** bare code comments like `// TODO: fix` — only personal-backlog intent (slash command, *resume todo*, *resume that one*, `TODO-NNN`, title hint).

## Long thread in current chat?

If this conversation already contains substantial unrelated work: **stop** — recommend **New Chat**, give the § Fresh-chat opener below. Do not merge old thread context into the todo session.

## Resolve target (in order)

1. Explicit `TODO-NNN` in command or message (e.g. `TODO-001`).
2. Title or slug substring match against **Active** items in `todos.md` (e.g. *flyby*, *user-local contribs*).
3. Same-chat context after a list: *that one*, *that todo*, *the first*, *resume it* → item just shown in this chat, or the only Active item if unambiguous.
4. `/todo-resume` with no arg and **exactly one** Active item → use it.
5. Otherwise → ask which (repeat ids + titles); do not guess.

## Do

1. Read `%USERPROFILE%\.cursor\memory\todos.md` — locate the resolved item (**Done** if user named a completed id).
2. Read the linked **Transcript** path from the item table.
3. Reply with **Decision** (brief), **Blocked by** (if any), **one** current next step.
4. If **Decision** or **Next steps** look thin vs [`FORMAT.md`](../memory/todos/FORMAT.md) § Quality bar, say so and offer `/todo-add` to refine — do not invent missing decisions.
5. Ask whether to stay in Ask (plan) or switch to Agent (implement) **only when the user is ready to work** — not from explain/list paths.

Do **not** use prior chats unless user @-links them.

## Fresh-chat opener

Copy when recommending New Chat (fill id when known, or omit if only one active):

```text
/todo-resume

Read my personal todo and linked transcript from ~/.cursor/memory/.
Respect Blocked by. Restate Decision and the single current next step only.
Do not use other chats unless I @ them.
```

Or after picking from a list: `/todo-resume TODO-001`
