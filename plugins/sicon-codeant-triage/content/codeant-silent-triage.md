<!-- contrib-managed: codeant-triage@0.9.1 — source: ai-devtools/contrib/codeant-triage/ — prefer PR there; local edits may be overwritten on sync -->

# CodeAnt silent triage — agent contract

Invoke only as **silent triage** for `/pr-clearance` (or tests). Same flavour as `/codeant-triage`, no noisy loop. **Not a user slash command.**

**Shipped path:** `codeant-silent-triage.md` at the install root (user pack) or `content/codeant-silent-triage.md` (plugin). Resolve via `Get-CodeAntTriagePaths.ps1` when available.

## When clearance calls you

Clearance hands off one file at a time. You triage every CodeAnt issue on that path in one silent pass and return a validated DTO — no chat menus, no per-issue AskQuestion rounds.

## Input

| Field | Meaning |
|-------|---------|
| `Path` | One repo-relative file path for this handoff |
| `issues[]` | The **full** set of CodeAnt findings on that `Path` for this handoff (each with `Id`, `Number`, `Path`, line/comment fields as provided) |
| `PullRequestId` | ADO pull request id |
| `WorkspaceRoot` | Product repo root |

All items in `issues[]` must share the same normalized `Path` as the handoff `Path`.

## Output

One function return: `results` with **one row per input `Id`**, plus `paths` (touched files).

Walk issues internally **one issue at a time**; do not return until every issue has a row. Clearance may call again on the **same** Act session for the next `Path` or for Human `fix`. Keep the UAP/core/profile roster if already loaded; do not treat each `Path` as a cold start.

## UAP / profile context

May load in-scope UAPs / profile rules the same way `/codeant-triage` does. **Disposition** guides, never auto-decides.

## Hard bans

**Do not** AskQuestion, finalize, promote, commit, push, or post/complete ADO threads.

No session rollup menus. No treat/confirm loops. No `Post-CodeAntPrThreadReply.ps1`. No catalog promote. No `git commit` / `git push`.

**Do not run repository test, build, lint, validation, or formatting scripts.** The clearance coordinator owns verification outside this specialist handoff. You may read tests as evidence when needed, but do not execute them or modify tests unless the finding itself targets a test.

## Human steering (`human` on an issue)

If an issue has `human`:

| Field | Role |
|-------|------|
| `choice` | The decision (`fix`, dismiss intent, etc.) |
| `guidance` | How the human wants it interpreted and resolved |

Honour `guidance` when non-empty; do not bounce `ask` for the same indecision on `choice = fix`.

## Per-issue disposition

For each issue set `disposition` to one of:

| Value | Meaning |
|-------|---------|
| `fixed` | Change applied (or already fixed) |
| `dismissed` | Won't fix / false positive with rationale |
| `ask` | Needs human — clearance will surface `explain` |

Use this decision order:

1. If the current code already satisfies the finding, return `fixed` with `already = $true`.
2. If the finding is valid and the change is bounded and low-risk, apply it and return `fixed`; triviality is a reason to proceed, not to bounce.
3. If it is preference-only or product flavour and leaving the code unchanged creates no plausible security, exploitation, correctness, or bug risk, return `dismissed` with that concrete rationale.
4. Return `ask` only for conflicting requirements, unclear intended behaviour, material compatibility/scope risk, or evidence that cannot distinguish a safe dismissal from a defect. “Product choice” alone is not enough.

### On `fixed`

**Must** set:

| Field | Content |
|-------|---------|
| `report.issue` | What the review flagged (everyday language) |
| `report.change` | What you changed |
| `report.justification` | Why the change satisfies the finding |

The justification must come from your evaluation of the finding and current code. Describe the resulting safety or correctness; do not mention the specialist, subagent, pack, or workflow in user-facing text.

Set `already = $true` when the code already matched the desired state before you edited.

### On `ask`

**Must** set every applicable `explain` field used by clearance Human:

| Field | Content |
|-------|---------|
| `header` | Short title for the card |
| `reviewSaid` | What CodeAnt / the thread said |
| `context` | Relevant code / diff context |
| `ruleCrossCheck` | Optional — how local rules or patterns apply |
| `verdict` | Your read: hit, partial, false positive, already fixed, … |
| `proposedChange` | Concrete fix if recommending action |
| `recommendation` | `fix` or `dismiss` when present |

Give enough detail for the human to decide without inspecting your internal work: preserve what the review said, relevant code context, the unresolved risk or requirement, your verdict, the exact bounded change, and a reasoned recommendation.

### On `dismissed`

Set `reason` with a clear won't-fix / false-positive rationale that states why no security, exploitation, correctness, or bug risk remains. `report.issue` should preserve what was flagged so the public response can use `Issue` plus `WontFix Reason`.

## Language rules

Everyday language in `reason` and `report`. **No UAP/CAP ids** — no `UAP-*`, `CAP-*`, `AP-*`, Disposition labels, or pack paths in user-facing strings.

## Workflow

```text
load roster once if not already loaded (UAP / core / profile — same scope rules as /codeant-triage)
for each issue on Path (one issue at a time, internally):
  read issue (+ human choice/guidance if present)
  evaluate against branch, file, scoped catalog / profile rules
  apply fix OR set dismissed OR set ask with explain
build $rows — one result object per issue Id
Invoke-CodeAntSilentTriage -Path <Path> -Issues <issues[]> -PullRequestId <id> -WorkspaceRoot <root> -PreparedResults $rows
return that object to clearance
```

## `paths`

Include this file plus any product files you edited in `paths` (the validator merges `-Path` with any `report.paths` you attach).

## Validation helper

After the agent has rows:

```powershell
. (Join-Path $scriptsRoot 'codeant-triage-lib.ps1')
Invoke-CodeAntSilentTriage -Path $Path -Issues $Issues -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot -PreparedResults $rows
```

Return that object to clearance unchanged (shape-normalized).
