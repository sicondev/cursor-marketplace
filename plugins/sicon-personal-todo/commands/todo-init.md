---
name: todo-init
description: Personal backlog in local Cursor memory via /todo-* slash commands
---
# todo-init — seed personal todo memory (first run)

Mutating. User-scoped memory — not org/repo tooling. Seeds `%USERPROFILE%\.cursor\memory\` templates **only when missing** (never overwrites).

## When

User invokes `/todo-init`, `/todo init`, or asks to **seed** / **initialize** / **set up** personal todo memory / backlog.

## Mode

Needs shell (Agent). If Ask: say seeding writes under `memory/`, suggest Agent or running the init script path yourself — do not invent backlog items.

## Resolve init script (dual install — order is mandatory)

1. **User pack (dogfood):**  
   `%USERPROFILE%\.cursor\packs\personal-todo\scripts\Initialize-PersonalTodoMemory.ps1`  
   if `Test-Path` → use it.
2. **Team Marketplace plugin:** search under `%USERPROFILE%\.cursor\plugins\` for `Initialize-PersonalTodoMemory.ps1` whose path contains `sicon-personal-todo` (cache, marketplaces, or local). Prefer the newest by `LastWriteTime`.
3. Else **stop** — neither layout found. Dogfood: install the personal-todo user pack then retry. Marketplace: install **Sicon Personal Todo** from the Team Marketplace, reload Cursor, retry.

Do **not** invent a third template source. Do **not** copy templates by hand unless the user asked.

## Do

```powershell
powershell -NoProfile -File "<resolved>\Initialize-PersonalTodoMemory.ps1"
```

Optional: add `-WhatIf` only when the user asked for a dry run.

## Reply

Report script lines (`Seeded:` / `Skip (exists):` / `Done.`). If `memory.md` was skipped, mention merging § Personal todos from the fragment path the script printed when that section is missing.

Then offer: *`/todo-list`*.

Do **not** add backlog items here — that is `/todo-add`.
