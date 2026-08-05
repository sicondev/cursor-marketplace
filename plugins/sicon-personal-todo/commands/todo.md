---
name: todo
description: Personal backlog in local Cursor memory via /todo-* slash commands
---
# todo — personal backlog router

Thin router — load **exactly one** lane doc per invocation.

## When

User invokes `/todo` with a subcommand: `list`, `explain`, `add`, `resume`, `howto`, or `init` (e.g. `/todo explain TODO-010`, `/todo howto`, `/todo init`).

Natural-language aliases routed here: *todo explain*, *todo list*, *todo add*, *todo resume*, *todo howto*, *todo init*.

## Route (in order)

1. **Subcommand** in message → lane below.
2. `/todo` with no subcommand → suggest `/todo-list` or `/todo-howto` (and `/todo-init` if first-time setup).

| Subcommand | Load |
|------------|------|
| `list` | [`todo-list.md`](todo-list.md) |
| `explain` | [`todo-explain.md`](todo-explain.md) |
| `add` | [`todo-add.md`](todo-add.md) |
| `resume` | [`todo-resume.md`](todo-resume.md) |
| `howto` | [`todo-howto.md`](todo-howto.md) |
| `init` | [`todo-init.md`](todo-init.md) |

Pass through optional `TODO-NNN` and title hints to the lane doc.

Do **not** load multiple lane docs in one run.
