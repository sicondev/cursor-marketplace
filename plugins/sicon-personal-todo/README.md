# Sicon Personal Todo

Personal backlog in local Cursor memory via `/todo-*` slash commands.

Install from the Sicon Team Marketplace, then reload Cursor.

## First run

Seed memory templates (only creates missing files):

```text
/todo-init
```

If you open `/todo-list` before seeding, it will offer `/todo-init` when `todos.md` is missing — it will not create files itself.

## Usage

| Command | Purpose |
|---------|---------|
| `/todo-howto` | Usage guide |
| `/todo-init` | Seed local Cursor memory templates |
| `/todo-list` | List Active / Done / Parked |
| `/todo-explain` | Read-only unpack of one item |
| `/todo-add` | Add or refine (sparse gate) |
| `/todo-resume` | Briefing to start work |
| `/todo` | Router (`list`, `explain`, `add`, `resume`, `howto`, `init`) |

Your backlog files stay on your machine — plugin updates do not overwrite them.
