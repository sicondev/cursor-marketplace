---
name: nineyards
description: Commit, push, and create or update a pull request through one message-gated /nineyards workflow
---
# /nineyards — commit, push, PR in one command

**User-profile contrib.** Prefers Team Marketplace **Sicon ADO Core** at runtime; falls back to the user-pack ado-core install.

**Scripts root** — Dual Resolve `sicon-nineyards` → `scripts/`: plugin direct → newest `plugins/marketplaces|cache` (bounded) → packs dogfood only if no plugin; never prefer pack.

```powershell
$nineyards = $null
$pluginsRoot = Join-Path $env:USERPROFILE '.cursor\plugins'
$directScript = Join-Path $pluginsRoot 'sicon-nineyards\scripts\Get-NineyardsRepoCapabilities.ps1'
if (Test-Path -LiteralPath $directScript -PathType Leaf) {
    $nineyards = Split-Path -Parent $directScript
} else {
    $hits = foreach ($subdir in @('marketplaces', 'cache')) {
        $root = Join-Path $pluginsRoot $subdir
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -Filter 'Get-NineyardsRepoCapabilities.ps1' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'sicon-nineyards' }
    }
    if (@($hits).Count -gt 0) {
        $nineyards = (@($hits) | Sort-Object LastWriteTime -Descending | Select-Object -First 1).DirectoryName
    }
}
if (-not $nineyards) {
    $nineyards = Join-Path $env:USERPROFILE '.cursor\packs\nineyards\scripts'
}
```

## Contract

`/nineyards` always means **commit → push → PR coverage** (after the message gate clears):

| PR state | Action |
|----------|--------|
| Open PR exists for source branch | Commit → `git push` (updates existing PR; ADO invalidates votes automatically) |
| No open PR | Commit → push → **create** PR into resolved target branch |

Optional WI: link when supplied — **never ask** if omitted.

**`/nineyards` starts ship prep** — resolve repo/branch/target, draft messages, **stop at the message gate**. Commit / push / PR create only after the user proceeds (`go`, `lgtm`, `ship it`, `commit that`, or `/nineyards` again with same intent). Prior-turn “say the word” still inherits context but still hits the message gate. After the gate clears, do **not** ask a second vague “shall I commit?”.

## Trigger phrases

- `/nineyards`
- `the whole nine yards`, `nine yards`, `commit push pr`, `commit push and pr`

## Phase 0 — Prior-turn context (bare or WI-only)

When input is `/nineyards` with no other tokens (or only WI id(s)), scan the **immediately prior assistant message** for:

| Signal | Inherit |
|--------|---------|
| `` on `branch` ``, `branch `branch`` | `sourceBranch` |
| `into dev`, `into 260/dev`, `PR to main` | `targetBranch` (explicit) |
| `approvals`, `hub`, `ai-devtools`, path | `repo` hint |
| Draft commit message | `commitMessage` (feeds the gate — still shown) |
| `say the word`, `when you're ready` | Deferred ship prep — still stop at message gate |

Command args override prior-turn context.

## Phase 1 — Parse free text

Strip `/nineyards` then extract (order-independent):

| Signal | Examples | Effect |
|--------|----------|--------|
| Work item | `19224`, `#19224`, `WI 19224` | `workItemIds`; never prompt if absent |
| Source branch | `on tooling-structure`, `branch feature/foo` | Switch, commit, push here |
| Target branch | `into dev`, `into 260/dev`, `target 221/dev` | Explicit PR target — overrides parent detection |
| Repo | `approvals`, `hub`, `react-sicon-hub`, `platform`, `ai-devtools` | Multi-root repo pick |
| PR title | `"..."` or leftover text after tokens | Ship PR title (may diverge from commit — show in gate) |
| Draft | `draft` | Draft PR where supported |
| Kick CodeAnt | `kick codeant`, `request review` | `kickCodeAnt` — post `@codeant-ai: review` after **new** PR create (opt-in; default is skip) |
| Skip CodeAnt | `skip codeant`, `no codeant` | Legacy no-op — still skips (same as default) |
**Repo resolution:** explicit hint → dirty tree in context → single dirty repo → AskQuestion only if multiple dirty repos and no hint.

## Phase 1a — Per-repo capability probe

**Always probe the resolved repo only** — never assume workspace-wide tooling.

```powershell
powershell -NoProfile -File $nineyards/Get-NineyardsRepoCapabilities.ps1 -RepoRoot '<repo>' -Json
```

| Field | Meaning |
|-------|---------|
| `remoteType` | `ado`, `github`, `other` |
| `capabilityLabel` | e.g. `plain-ado` or `github` |

Report `capabilityLabel` in the summary.

## Phase 1b — Resolve PR target (parent on origin)

When no explicit `into …`:

```powershell
powershell -NoProfile -File $nineyards/Get-NineyardsTargetBranch.ps1 `
  -RepoRoot '<repo>' -SourceBranch '<branch>' [-ExplicitTarget '<target>'] -Json
```

Resolution order: existing open PR → `@{upstream}` → nearest merge-base among `origin/*` candidates → throw (pass `-ExplicitTarget`) when none or ambiguous.

Always report `targetBranch` + `resolution` (`existing-pr`, `upstream`, `nearest-merge-base`, `explicit`).

## Phase 1c — Message gate (before commit / push / PR create)

After 1a/1b, run `git status` / `git diff` (read-only) so drafts are accurate. **Do not** `git add`, commit, push, or create a PR until this gate clears.

### Draft messages

1. **`commitMessage`** — from args, prior-turn inherit, or status/diff; append `#NNNNN` per WI (one per line).
2. **`prTitle` / `prBody`:**
   - Default: **match commit** (title = first line; body = rest or empty).
   - Diverge only with a stated reason (e.g. user passed a distinct quoted PR title; new PR needs a broader title than this commit; multi-commit PR).

### Show and stop

Concise prose (not AskQuestion):

```text
## Message gate
Repo: … | branch: … → target: … (resolution)

Commit message:
<proposed>

PR: matches commit
— or —
PR title / body (diverges because …):
<proposed>

CodeAnt: skipped by default (auto-review usual; say kick codeant to post)
— or —
CodeAnt: will post @codeant-ai: review after create (kick codeant)
— or —
CodeAnt: skipped (existing PR)

Reply with edits, or say **go** to ship.
```
### Skip rules

| Situation | Gate |
|-----------|------|
| Dirty working tree | Always gate on commit; if creating a new PR and PR text matches commit → one line `PR: matches commit`; if diverging → show PR block + reason |
| Clean tree + unpushed commits + **existing open PR** | **Skip** message gate → push-only (Phase 3) |
| Clean tree + unpushed commits + **no open PR** | Gate on **PR title/body only** (no commit draft) |

### Next user turn

| Reply | Action |
|-------|--------|
| Refine (edits to commit and/or PR text) | Apply → **re-show** gate — do not ship |
| Proceed (`go`, `lgtm`, `ship it`, `commit that`, `/nineyards` again with same intent) | Lock messages → Phase 2; pass `-KickCodeAnt` to ship **only** when the user set `kickCodeAnt` at the gate (`kick codeant` / `request review`) — default is **no** CodeAnt kick on **new** PR create |

## Phase 2 — Commit

Use the **gate-approved** `commitMessage`. Do not re-draft after proceed unless the working tree changed since the gate.

Follow all repository-local commit and review rules active in the resolved repository. Nineyards does not discover or invoke product-specific commit gates.

Then `git add` relevant files and `git commit` with the gate-approved message.

If working tree clean but unpushed commits exist → skip commit, go to Phase 3 (message gate already handled in Phase 1c).

## Phase 3 — Push + PR

Detect open PR first (`Get-NineyardsOpenPullRequest` via ship script).

Pass **gate-approved** `prTitle` (and `prBody` when applicable) when creating a new PR.

### A) ADO

Pass gate-approved values as bound PowerShell variables / a splat — do **not** interpolate user- or gate-derived strings into a single-quoted command template:

```powershell
$shipArgs = @{
  WorkspaceRoot = $repo
  TargetBranch  = $resolvedTarget
  Title         = $gateApprovedTitle
  SourceBranch  = $sourceBranch
  Json          = $true
}
if ($gateApprovedBody) { $shipArgs.Description = $gateApprovedBody }
if ($workItemId) { $shipArgs.WorkItemId = $workItemId }
if ($kickCodeAnt) { $shipArgs.KickCodeAnt = $true }
powershell -NoProfile -File (Join-Path $nineyards 'Invoke-NineyardsShip.ps1') @shipArgs
```

Creates PR with `workItemRefs` when WI supplied on create; existing PR → push only.

On **`created-new` only** when `-KickCodeAnt` / gate `kick codeant` / `request review`: posts `@codeant-ai: review` via ado-core `New-AdoCorePullRequestThread`. Default is **no** kick (CodeAnt usually auto-starts). Failure to post is a **warning** — PR create still succeeds. JSON field `codeAntTrigger`: `posted` | `skipped-default` | `skipped-flag` | `warn` | `skipped-existing-pr`. Leftover Active trigger threads are cleared later by `/codeant-triage` finalize (`resolve` / `reply-only`), not by nineyards.

Fallback: push + create-PR web URL per `devtools/org/git/ado-pr.md` in repo (if present) or org pack path.

### B) GitHub

Use the parameterized ship script so user-derived values are passed as arguments rather than embedded in a shell command:

```powershell
powershell -NoProfile -File $nineyards/Invoke-NineyardsGitHubShip.ps1 `
  -WorkspaceRoot '<repo>' -TargetBranch '<resolved>' -Title '<gate-approved-title>' `
  [-Description '<gate-approved-body>'] [-SourceBranch '<branch>'] [-Draft] -Json
```

The script validates branch names, pushes via `Push-GitCore -SetUpstream`, updates an existing open PR, or creates a new one with structured `gh` arguments.

## Phase 4 — WI linking (when WI supplied)

1. `#id` in commit message (Phase 2)
2. If PR was **updated** (not created with `workItemRefs`):

```powershell
powershell -NoProfile -File $nineyards/Link-NineyardsWorkItem.ps1 `
  -WorkspaceRoot '<repo>' -PullRequestId <id> -WorkItemId 19224 -Json
```

Default is PR-only. Do not pass `-LinkCommits` unless the user asks for full commit traceability.

3. Report link warnings. If no WI: **do not ask**.

## Response format

**At message gate (stop):** the Phase 1c block only — no ship summary yet.

**After ship:**

- Repo + `capabilityLabel` + source branch
- Commit hash (if new)
- PR url + id + **updated existing** vs **created new**
- CodeAnt trigger: posted / skipped / warn (ADO plain path; create-only)
- Target branch + resolution method
- WI: linked / skipped / warning
- Blockers only if stopped

## Anti-patterns

- Asking for WI when omitted
- Shipping (commit / push / PR create) before message gate clearance
- Inventing a divergent PR message without showing it and the reason in the gate
- Asking a second vague “shall I commit?” after the user already said **go**
- Posting `@codeant-ai: review` on **existing** PR push (create-only)
- Homebrew ADO REST for the CodeAnt kick (use ado-core / ship script)
- Assuming product-local PR tools from another workspace root
- `gh pr create` on ADO remotes

## Examples

```text
/nineyards
# → message gate with commit (+ PR matches or diverges) → user: go → ship

/nineyards 19224
/nineyards into 260/dev
/nineyards hub "fix Companies nav permission"
# Agent: "...Say the word if you want this committed and pushed on tooling-structure."
/nineyards
# → still shows message gate; user: go → ship

# After gate shown:
make the commit say "docs: clarify nineyards gate"
# → re-show gate with edit → user: go → ship
```

Pack readme: `%USERPROFILE%\.cursor\packs\nineyards\README.md`
