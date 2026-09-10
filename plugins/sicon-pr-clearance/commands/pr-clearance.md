---
name: pr-clearance
description: Drive an Azure DevOps pull request to review-quiet using Policy, Human, and configured review tools
---

# PR clearance

Team Marketplace plugin `sicon-pr-clearance`. Invoke `/pr-clearance` only (no natural-language trigger).

## Resolve scripts (plugin first)

1. **Team Marketplace plugin:** search `%USERPROFILE%\.cursor\plugins\` for `pr-clearance-lib.ps1` whose path contains `sicon-pr-clearance`. Prefer the newest by `LastWriteTime`.
2. **User pack (local dogfood only):** `%USERPROFILE%\.cursor\packs\pr-clearance\scripts\pr-clearance-lib.ps1` if `Test-Path`.
3. Else **stop** — install **Sicon PR Clearance** from the Team Marketplace, reload, retry. Name the **tool id** `pr-clearance`, not a script.

```powershell
$pluginHits = @(Get-ChildItem -LiteralPath (Join-Path $env:USERPROFILE '.cursor\plugins') -Recurse -Filter 'pr-clearance-lib.ps1' -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match 'sicon-pr-clearance' } |
    Sort-Object LastWriteTime -Descending)
if ($pluginHits.Count -gt 0) {
    $clearance = $pluginHits[0].DirectoryName
}
else {
    $packLib = Join-Path $env:USERPROFILE '.cursor\packs\pr-clearance\scripts\pr-clearance-lib.ps1'
    if (Test-Path -LiteralPath $packLib -PathType Leaf) {
        $clearance = Split-Path -Parent $packLib
    }
}
if (-not $clearance) { throw 'pr-clearance is not installed' }
. (Join-Path $clearance 'pr-clearance-lib.ps1')
. (Join-Path $clearance 'pr-clearance-policy.ps1')
$policyMd = Get-PrClearancePolicyMarkdownPath
```

Read `$policyMd`. Do not assume `packs\pr-clearance\policy\` — the plugin ships the table at `content\policy\pr-clearance-policy.md`.

## Input

- `/pr-clearance <pr>` — `<pr>` is a positive integer. No other verbs.
- Bare `/pr-clearance`: one `AskQuestion` — Azure DevOps PR number? Empty or cancel → stop. Do not infer the id from the current branch.

## For the agent

This command is the **driver**. Call **port names** from the lib (`Get-ReviewState`, `Wait-ReviewFinished`, `Request-Review`, `Clear-ReviewRequests`, `Get-ReviewFindings`, `Complete-ReviewFinding`, `Get-PrClearanceNextAction`, `Test-PrClearanceQuiet`, `Resolve-PrClearanceRepoRoot`, `Invoke-PrClearanceSpecialist`, `Group-PrClearancePassFindingsByPath`, `Get-PrClearanceSpecialistReply`) and coordinator helpers (`Get-PrClearanceDismissedReply`, `Read-PrClearanceActRegister`, `Save-PrClearanceActRegister`, `Set-PrClearanceChangedPaths`, `Set-PrClearanceFindingPathSnapshot`, `Get-PrClearanceFindingFingerprint`, `Get-PrClearancePolicyOverride`, `Get-PrClearancePolicyDecision`, `Get-PrClearancePrChangedPaths`, `Test-PrClearanceFindingInPrScope`, `Add-PrClearanceActRegisterFix`, `Add-PrClearanceActRegisterPathBatch`, `Add-PrClearanceActRegisterJoin`, `Test-PrClearanceShouldKickAfterAct`, `Get-PrClearanceRepeatedReport`). Do not hardcode a vendor command name in chat or config.

`Import-PrClearanceTools` loads bind-config **tool ids** (`review`, `findings`, `forge`, `vcs`, `specialist`) and the already-installed packs those ids name. Default ids are `codeant-triage`, `codeant-triage`, `ado-core`, `git-core`, `codeant-triage`. Required functions for `codeant-triage` include the Get-CodeAnt* names and `Invoke-CodeAntSilentTriage`. Missing `Invoke-CodeAntSilentTriage` → tell the user to install or upgrade **codeant-triage**.

Errors:

- Missing pack → tell the user to install that **tool id**.
- Tool installed but a required function is missing → tell the user to **upgrade that tool id**.
- Unknown tool id in config → stop and name the id. Do not guess a script path.

The coordinator **never implements product code**. The only implementer is the specialist.

Do not parse vendor evidence tables. Do not post a kick string. Do not call Forge thread helpers. Kick is `Request-Review` on the Review tool; that tool implements the response. Quiet is composed: `finished_this_sha` and an empty findings list (`Test-PrClearanceQuiet`). Do not call a vendor quiet helper.

### Repo root

Derive from the **PR**. Collect git roots in the open workspace. `Resolve-PrClearanceRepoRoot -PullRequestId -WorkspaceRoots`. One hit → use it. Several → `AskQuestion` among those folders only. None → stop (no clone; do not default to a tooling repo). Do not pick the focused tab.

After the root is known, pass `-WorkspaceRoot` on port calls. Vcs uses that root only.

### Engage (stop in chat, no loop)

1. PR id known.
2. `Import-PrClearanceTools` succeeds.
3. Repo root resolved; header: PR id, web URL (from the hit), branch, tip SHA (12-char prefix via `Get-GitCoreHeadSha`).
4. Current branch in that root equals the PR `sourceRefName` (strip `refs/heads/`). Mismatch → stop; user checks out that branch. Do not switch branches.
5. Working tree clean (`Test-PrClearanceWorkingTreeClean` or `Invoke-GitCore status --porcelain` empty). Dirty → stop; user commits or stashes. Do not stash.
6. `changedPaths = Get-PrClearancePrChangedPaths -RepoRoot -TargetRef` (PR `targetRefName`). If that throws, continue without `-ChangedPaths` and add a finalize reason. Do not invent an empty allowlist.
7. `Set-PrClearanceChangedPaths` on the register (once). Do not recompute `origin/target...HEAD` in later batches — a later commit must not grow the allowlist.

### Loop

Constants: wait 600s (`Wait-ReviewFinished -TimeoutSeconds 600`); max 10 Act batches.

```text
tipSha = Get-GitCoreHeadSha
register = Read-PrClearanceActRegister (repo .tmp/pr-clearance/act-register-<pr>.json)
firstInteraction = true
loop:
  findings = Get-ReviewFindings
  next = Get-PrClearanceNextAction -PullRequestId -Sha -FindingCount findings.Count -FirstInteraction:$firstInteraction
    # -FirstInteraction only on the first NextAction this invoke
    # -AfterPush only when Test-PrClearanceShouldKickAfterAct -CodeChanged
  firstInteraction = false
  finalize_quiet → Clear-ReviewRequests then Human.finalize and stop
  finalize_timeout / finalize_max_batches → Get-ReviewFindings; each Complete-ReviewFinding dismissed with Get-PrClearanceHardStopReply; Clear-ReviewRequests; then Human.finalize (quiet = false; notFixed = closed without a fix) and stop
  request_and_wait → Request-Review then Wait-ReviewFinished
  wait → Wait-ReviewFinished
  act → Act then increment batch count
```

Start with findings. First NextAction: any findings → `act` (do not kick first). Empty findings → kick once (`request_and_wait`) unless state is already `in_flight` (wait) or `finished_this_sha` (quiet). After that, empty findings is completion (`finalize_quiet`) even if review state is still `none` / leftover `in_flight`. After a **product-code** push, refresh `tipSha` and call NextAction `-AfterPush` (new tip still kicks). Do not pass `-AfterPush` when Act only dismissed or completed `fixed` with no path change. After every wait, if `timedOut` then NextAction `-LastWaitTimedOut`. Never write the register under `%USERPROFILE%\.cursor\`. Never `git add` it.

### Policy

Call `Get-PrClearancePolicyDecision -Finding -Register [-ChangedPaths]` first (frozen engage list, not a fresh git diff). Then follow `pr-clearance-policy.md`. Human only on `ask`. Specialist only on `pass` (and Human Fix). Coordinator never implements. `already` completes `fixed` with no specialist and no Vcs.

Product choice alone is not a reason to ask. Preference-only / flavour findings with no plausible security, exploitation, correctness, or bug risk are dismissed automatically. Valid findings with a bounded, low-risk fix pass to the specialist. Human is reserved for a concrete unresolved requirement, behaviour, compatibility, scope, or risk decision.

Fuse rows live in `pr-clearance-policy.ps1`, not this command. The specialist may edit a file that was not on the first-findings list (or not in the original PR) when that edit is required for a `pass` — then `Get-GitCoreDiffHunks` on `HEAD~1...HEAD` and `Add-PrClearanceActRegisterJoin`. Later comments on a joined file must hit those Act hunks. Do not follow imports or clean surrounding style on the rest of that file.

### Human

**Interim** when Policy returns `ask`, or when the specialist returns `ask`. Put a **read-only explain block** in chat, then the same turn: one `AskQuestion` (do not list options in chat). The coordinator **never implements product code** and **does not interpret how to fix**. It records the Human reply and forwards it. Choices stay `fix` / `dismiss` only — no won't-fix, skip, fix-remaining, or confirm-after-implement.

If the specialist returned `explain`, use those fields for the block (`header`, `reviewSaid`, `context`, `ruleCrossCheck`, `verdict`, `proposedChange`, `recommendation`). Otherwise use the finding plus `reason`. `recommendation` `fix`|`dismiss` marks exactly one card Recommended.

Never show only the question card or only the `ask` reason. Every human bounce includes the finding details below so the human can decide from the review evidence and specialist reasoning. Do not expose internal specialist actions, prompt steps, or uncertainty as the justification.

Emit:

| Field | Content |
|-------|---------|
| **Header** | `Finding #N of M — \`file\` ~line` (`N` = finding `Number`, `M` = count of findings in this Act list) — or `explain.header` |
| **Review said** | Quote or clear paraphrase of `Comment` (substance, not HTML), or `explain.reviewSaid`. Do not replace this with only the Policy reason. |
| **Context** | Relevant code at `Path` / `Line` — cite lines — or `explain.context`. Stay under the repo root (`Resolve-PrClearanceFindingPath`). |
| **Why this needs a human** | The `ask` reason in everyday language (Policy `ask`, or specialist `reason` / `explain.ruleCrossCheck`) |
| **Verdict** | Already fixed \| Valid \| Partial \| Invalid \| Needs verification — with why — or `explain.verdict` |
| **Proposed change** | Concrete files + behaviour if Fix is chosen (**do not apply yet**) — or `explain.proposedChange` |
| **Recommendation** | Fix now \| Dismiss — one-line rationale — or `explain.recommendation` |

After the explain block: invoke `AskQuestion` in the same turn — do not wait for a typed reply.

- `prompt`: Policy `ask` → `Finding #<Number> — Policy could not decide.` Specialist `ask` → `Finding #<Number> — specialist needs a decision.` Do not say “Policy could not decide” for a specialist `ask`.
- `fix` — `Fix (Recommended)` when recommendation is Fix now; otherwise `Fix`
- `dismiss` — `Dismiss (Recommended)` when recommendation is Dismiss; otherwise `Dismiss`

Put `(Recommended)` on exactly one option.

Host Other or a typed reply may include **how the human wants the finding interpreted** and **how they want it resolved**. Map to `choice` + `guidance`. `choice` is the decision (`fix` / `dismiss`). `guidance` is the rest of what they said — interpretation and resolution intent — **copy their words; do not rewrite** them into a coordinator plan. Bare `Fix` / `Dismiss` with no extra text → `guidance` empty. If Other is still ambiguous, one short chat question, then map. If `AskQuestion` is unavailable: one short prose question, same two choices.

After Human, attach `human = @{ choice; guidance }` on each issue (`choice` is Fix/Dismiss; `guidance` is the human's own words, or empty if they only clicked a card):

| Human `choice` | Next |
|----------------|------|
| `dismiss` | `Complete-ReviewFinding` dismissed with `Get-PrClearanceDismissedReply -Finding -Reason` (`Reason` prefers `human.guidance`, else `explain` / `reason`). **No specialist.** No Vcs for that issue. |
| `fix` | **Same Act specialist**, another call for that Path with `-PreparedResults` after apply. `Issues` = every Fix-chosen finding on that file, each with `human` (`choice` + `guidance`). Do not spawn a new worker. Do not reload the roster if already loaded. Specialist must honour `guidance` (it overrides `explain.proposedChange` when non-empty). Coordinator only commits and completes. |

If the specialist returns `ask` again on the same issue, Human once more. New `guidance` replaces the previous. Fuses (repeat / amend cap) still apply so a bounce loop cannot run forever.

**Finalize** after quiet or hard stop. Call `Clear-ReviewRequests -PullRequestId -WorkspaceRoot` first (Review port). Append `Get-PrClearanceReviewRequestClearNotes` to `reasons[]`. Warn on failure; do not skip the report. Chat the report `{ quiet, fixed[], notFixed[], reasons[], repeated[] }`, then `AskQuestion` `prompt`: `PR #<id> clearance finished.` One option: `done` — `Done`. No merge. No commit/push/create-PR options.

### Act (one batch, then loop)

**Lifetime:** one specialist per Act. Serial one Path at a time on that specialist. Dispose the specialist at Act end. Next Act starts a new one. Do not run two specialists at once. Do not keep a specialist across Acts. The coordinator never implements product code.

1. Reuse the `findings` list from this loop pass. Refresh with `Get-ReviewFindings` only after an operation that can change findings. `Read-PrClearanceActRegister` (create empty if missing).
2. `Set-PrClearanceFindingPathSnapshot` on the first non-empty findings list (in-PR paths only). Later **reviews** cannot add files by commenting. Act may join a helper file the specialist changed and Vcs committed. Save the register.
3. Policy via `Get-PrClearancePolicyDecision` plus `pr-clearance-policy.md` using the **frozen** engage list (not a fresh git diff). Human interim only for Policy `ask` (one card per turn). If every remaining finding is dismiss: complete `dismissed`, save register, no specialist, no Vcs, no `-AfterPush`. Loop.
4. Each Policy `dismiss`: `Complete-ReviewFinding -Disposition dismissed -Reply (Get-PrClearanceDismissedReply -Finding $finding -Reason $decision.reason)`. No specialist. No Vcs.
5. Each Policy `already`: no specialist and no Vcs (still complete `fixed` in step 11).
6. Collect Policy `pass` findings. `$groups = Group-PrClearancePassFindingsByPath`.
7. Start **one** specialist for this Act (bound `specialist` tool) on the first `pass` group or the first Human `fix`. That specialist follows `codeant-silent-triage.md` (same flavour as `/codeant-triage`, no noisy AskQuestion loop): edit the file, then return. Do not spawn per Path. Coordinator never implements.
8. For each group (**serial**, same specialist): the specialist returns via **one** `Invoke-PrClearanceSpecialist -Path $group.Path -Issues $group.Issues -PullRequestId -WorkspaceRoot -PreparedResults $rows` (or equivalent) with **all** issues on that Path. One call = Path + the full issues collection + prepared rows (one row per `Id`). A call **without** `-PreparedResults` is the validator stub (`ask` / `Awaiting specialist apply`) — it is not a finished Act. Expect **one** return whose `results` cover every input `Id`. Next Path only after this Path is finished (including Human bounces). First `pass` call: omit `human` or set it `$null`.
9. For each result `ask`: Human explain — use `explain.*` if present, else finding + `reason`. Cards still Fix/Dismiss. After Human, attach `human = @{ choice; guidance }` (`guidance` = the human's own words; do not rewrite). **Fix** → same Act specialist, one `Invoke-PrClearanceSpecialist` with `-PreparedResults` after apply, every Fix-chosen issue on that Path, each carrying `human` (do not reload the roster if already loaded; specialist must honour `guidance`). **Dismiss** → Complete dismissed (prefer `guidance` in the reply); do not re-call. Same-issue `ask` again → Human again; fuses still cap the loop.
10. Union `paths` from specialist returns (not the register file). If **product** paths changed: `New-GitCoreCommit -RepoRoot -Path <paths> -Message` then `Push-GitCore`. Paths may include a helper that was not in `changedPaths`. Never include the register file. Then `tipSha = Get-GitCoreHeadSha`. `Get-GitCoreDiffHunks -Range HEAD~1...HEAD` and `Add-PrClearanceActRegisterJoin` for paths not in `clearancePaths`. Skip commit when nothing changed.
11. `Add-PrClearanceActRegisterFix` for each `fixed`; `Add-PrClearanceActRegisterPathBatch` when product paths changed; `Save-PrClearanceActRegister`. Each specialist `fixed` / Policy `already`: `Complete-ReviewFinding -Disposition fixed -Reply (Get-PrClearanceSpecialistReply)` (Policy `already` with no specialist result: two-line everyday reply). A fixed public reply must combine `report.change` with `report.justification`, preserving the specialist result's finding-based reasoning without mentioning the specialist or workflow. Each specialist `dismissed`: Complete dismissed with `Get-PrClearanceSpecialistReply`; its two lines are `Issue` and `WontFix Reason`, never `Fix`. Pass NextAction `-AfterPush` only when `Test-PrClearanceShouldKickAfterAct -CodeChanged`.
12. After Vcs + Complete for this findings snapshot, **dispose** the specialist. The next Act starts a new one.

`-Reply` when there is no specialist result: two short markdown lines (what was flagged; what changed or why not). Fixed uses `Issue` + `Fix`; dismissed uses `Issue` + `WontFix Reason`. Everyday language. No vendor, pack, catalog, specialist, or workflow jargon. When a specialist result exists, use `Get-PrClearanceSpecialistReply`.

Commit message:

```text
fix: clear review findings on PR #<id>

<one sentence: what this batch changed>
```

No `Co-authored-by`. No email addresses.
