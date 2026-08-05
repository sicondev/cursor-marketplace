---
name: good-prompt
description: Coach implementation briefs via /good-prompt — gap-fill until handoff to Plan
---
# good-prompt

User contrib pack `good-prompt` — invoke `/good-prompt` only (no NL triggers).

Optional text after command = draft task; do not ask for task if present.
Bare `/good-prompt` → one-line ack, then one question for draft task.

Run in **Ask mode** (read-only). Do not edit files, commit, push, or run mutating commands.

Purpose: coach an **implementation brief** — not `/fact-find`, not Plan, not execute.
Pipeline position: `Ask → good-prompt → Plan → Agent`. Output is the brief Plan receives.

## Do / do not

| Do | Do not |
|----|--------|
| Coach multi-turn until medium bar | Produce Plan, task list, or implementation steps |
| One gap per turn (highest leverage first) | Multiple questions per turn (except gate override) |
| Track confirmed fields across turns | Invent constraints, anchors, or outcomes |
| Emit paste-ready brief on handoff | `SwitchMode`, spawn subagents, start Plan/Agent in-thread |
| Default **Next: Plan** | Treat good-prompt as Plan replacement |
| **Next: Ask** when done-when is answer-in-chat | Block handoff forever — user may override |
| Medium gate with named gaps on handoff | Hard-require repo test tooling or full PR pack for handoff |
| PR evidence pack when Plan/Agent + repo change implied | Newman/Vitest prescriptions or broad repo exploration |
| Targeted read-only repo reads only to close a named gap | Wide semantic search |

## Gap priority (one per turn)

| Order | Field | Ask when missing |
|-------|-------|------------------|
| 1 | Task | Single change/investigation — one verb, one sentence |
| 2 | Repo / workspace | Which root in multi-root workspace? |
| 3 | Anchors | Files, lines, symbols, or "same pattern as X"? |
| 4 | Constraints | Mode, rules, style, no-commit, max scope? |
| 5 | Out of scope | What must not happen? |
| 6 | Dependencies / handoffs | Prerequisites, other agents/sessions, gap analysis? |
| 7 | Done when | Observable — diff, test, doc, or answer in chat? |
| 8 | PR evidence pack | Next Plan/Agent + PR implied; missing verify or policy gate |
| 9 | Next | Plan (default), Ask, or Agent (small + anchored — rare)? |

Use `AskQuestion` when choices are clear.
After each answer: compact partial draft brief — full reprint only if user asks.

## Minimum bar (handoff)

All three required:
1. Task — unambiguous verb + scope
2. At least one constraint
3. At least one observable done-when

Not required for handoff: all fields filled; anchors, out-of-scope, dependencies, PR pack may be thin.

## PR evidence pack (Level 1)

When Next is Plan or Agent and done-when implies repo change / PR — coach what will be **shown**, not which repo tool. One gap per turn.

Layers (coach; not all required for handoff):
1. **Machine** — one runnable verify line user names (test, build, lint, script)
2. **Human (policy)** — approval/policy gate in user's words (no prescribed group names)
3. **In PR description** — task, verify steps, WI `#NNNNN`, scope in/out

Coach questions (pick one): command output for PR; one machine check before PR; human approval gate on branch.

Skip when Next is Ask or done-when is answer-in-chat.

Default push path: PR under your identity via your org workflow (e.g. `/nineyards` at Sicon) unless user says otherwise; note when submitter ≠ approver.

Do not prescribe Newman, Vitest, Postman, or repo verify encyclopedia — Plan/Agent load repo rules. Level 2 extension files (TODO-015) optional later.

## Medium gate

On handoff signals (`good enough`, `give me the prompt`, `ready for Plan`, …) with named gaps remaining:

1. State mismatch if user asked to hand off with open gaps.
2. List named issues (specific): no anchor; done-when not observable; multi-root repo unspecified; PR without verify command; repo change without machine check; PR without policy gate; thin PR pack.
3. AskQuestion or prose: **Fix gaps** | **Proceed anyway** (`*(gaps noted)*` on thin fields).

Opt-out: `proceed anyway`, `ship it`, `good enough` after named gaps → emit brief; do not re-ask.

## Handoff output

Two parts:

```markdown
### Implementation brief — ready

**Gaps (if override):** …
**Next:** Plan | Ask | Agent
```

```markdown
## Task
…

## Repo / workspace
…

## Anchors
…

## Constraints
…

## Out of scope
…

## Dependencies / handoffs
…

## Done when
…

## PR evidence pack
### Machine
…
### Human (policy)
…
### In PR description
…

## Next
Plan | Ask (answer only) | Agent (anchored, small scope)
```

Omit empty sections or use `—`. Never `TBD`. PR pack section: include when Next Plan/Agent + repo change/PR; omit for Ask-only. Override: `*(gaps noted)*` on thin sub-headings.

## Repo awareness

Default: coach from user text only.

| Situation | One gap |
|-----------|---------|
| Multi-root | Which workspace folder? |
| Vague done-when | What to run, read, or check? |
| Repo change + Plan/Agent | One machine verify + one human gate (user's words) |
| Named subagents/skills | Flag missing handoff/gap-check only if user raised it |

Trigger reads: handoff or user-named paths only — read minimum to close gap (anchor file, route doc, skill README).

Not fully code-aware — flag topology omissions only.

## Handoff routing

| Done-when | Next |
|-----------|------|
| Artifact in repo | Plan — tell user: new chat, Plan mode, paste brief |
| Answer in chat | Ask — paste brief; skip PR pack coaching |
| Small anchored edit, user insists | Agent — rare; paste brief in new Agent chat |

Do not `SwitchMode` here. Do not invoke other org commands or skills unless user separately asks (e.g. `/fact-find`, `/todo-add`).

If user asks to plan or implement in-thread: emit brief first (or finish coaching), then Plan (new chat) or Agent if execution clear.

## Anti-patterns

- Implementation steps, file edit lists, Plan-style sequencing
- NL triggers in v1
- Inventing anchors, rules, outcomes
- `TBD` placeholders
- Broad repo exploration
- "Want me to implement/plan this?" mid-coaching
- Skipping Plan for implementation work
- Hard-block without proceed-anyway
- Per-repo artifact encyclopedia in one turn
- Requiring PR pack for Ask-only briefs
- Pleasing filler; rewriting user prompt without confirmation
- Other workflows unless user invokes separately
