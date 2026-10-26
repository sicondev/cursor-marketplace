#Requires -Version 5.1
<#
.SYNOPSIS
  Isolated CodeAnt review-state Get* checks (fixtures; no ADO required).
.EXAMPLE
  & "$PSScriptRoot\Test-CodeAntReviewState.ps1"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'codeant-triage-lib.ps1')

$fixtures = Join-Path $scriptDir 'fixtures\review-state'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}

function Read-ReviewStateFixture {
    param([string]$Name)
    $path = Join-Path $fixtures $Name
    return (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

$tipThis = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
$tipOther = 'cccccccccccccccccccccccccccccccccccccccc'
$prId = 1

$required = @(
    'Get-CodeAntReviewState'
    'Get-CodeAntReviewFindings'
    'Request-CodeAntReview'
    'Complete-CodeAntReviewFinding'
    'Clear-CodeAntReviewRequests'
)
foreach ($name in $required) {
    Assert-True ($null -ne (Get-Command -Name $name -ErrorAction SilentlyContinue)) "$name is defined"
}

Assert-True ($null -eq (Get-Command -Name Get-ReviewState -ErrorAction SilentlyContinue)) 'Get-ReviewState is not exported from triage'
Assert-True ($null -eq (Get-Command -Name Test-ReviewQuiet -ErrorAction SilentlyContinue)) 'Test-ReviewQuiet is not exported from triage'
Assert-True ($null -eq (Get-Command -Name Wait-ReviewFinished -ErrorAction SilentlyContinue)) 'Wait-ReviewFinished is not exported from triage'

$finishedThis = Read-ReviewStateFixture -Name 'finished-this-sha.json'
$stateThis = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipThis -Threads $finishedThis
Assert-True ($stateThis.state -eq 'finished_this_sha') 'finished-this-sha state'
Assert-True ($stateThis.tipSha -eq $tipThis) 'finished-this-sha echoes tip'
Assert-True (Test-CodeAntReviewShaPrefixMatch -Left $stateThis.reviewedSha -Right $tipThis) 'finished-this-sha reviewedSha matches tip'
Assert-True ($null -ne $stateThis.startedUtc) 'finished-this-sha startedUtc'
Assert-True ($null -ne $stateThis.finishedUtc) 'finished-this-sha finishedUtc'

$upperTip = $tipThis.ToUpperInvariant()
$stateCase = Get-CodeAntReviewState -PullRequestId $prId -Sha $upperTip -Threads $finishedThis
Assert-True ($stateCase.state -eq 'finished_this_sha') 'SHA prefix match is case-insensitive'

$findings = @(Get-CodeAntReviewFindings -PullRequestId $prId -Threads $finishedThis)
Assert-True ($findings.Count -eq 1) 'finished-this-sha has one active finding'
if ($findings.Count -eq 1) {
    Assert-True ($findings[0].Id -eq '202') 'finding Id is thread id'
    Assert-True ($findings[0].Number -eq 1) 'finding Number is 1-based'
    Assert-True ($findings[0].Path -eq '/src/App.cs') 'finding Path'
    Assert-True ($findings[0].Line -eq '12:18') 'finding Line range'
    Assert-True ($findings[0].Comment -eq 'Avoid empty catch.') 'finding Comment'
}

$stale = Read-ReviewStateFixture -Name 'finished-stale-sha.json'
$stateStale = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipOther -Threads $stale
Assert-True ($stateStale.state -eq 'finished_stale_sha') 'finished-stale-sha state'
Assert-True (-not (Test-CodeAntReviewShaPrefixMatch -Left $stateStale.reviewedSha -Right $tipOther)) 'stale reviewedSha is not the tip'

$staleKick = Read-ReviewStateFixture -Name 'stale-with-old-kick.json'
$stateStaleKick = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipOther -Threads $staleKick
Assert-True ($stateStaleKick.state -eq 'finished_stale_sha') 'old kick on a prior commit stays stale, not in_flight'
$reKick = Read-ReviewStateFixture -Name 'finished-this-sha-with-kick.json'
$stateReKick = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipThis -Threads $reKick
Assert-True ($stateReKick.state -eq 'in_flight') 'a kick after this tip finished is in_flight, not finished_this_sha'

$priorStart = Read-ReviewStateFixture -Name 'stale-with-prior-start.json'
$statePriorStart = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipOther -Threads $priorStart
Assert-True ($statePriorStart.state -eq 'finished_stale_sha') 'started boilerplate from a finished other commit is stale, not in_flight'

$laterKick = Read-ReviewStateFixture -Name 'stale-with-later-kick.json'
$afterKick = [datetime]::Parse('2026-09-07T16:45:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
$beforeKick = [datetime]::Parse('2026-09-07T16:35:00Z', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
$stateKickBeforeTip = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipOther -Threads $laterKick -ShaCommittedUtc $afterKick
Assert-True ($stateKickBeforeTip.state -eq 'finished_stale_sha') 'kick posted before this tip existed is stale, not in_flight'
$stateKickForTip = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipOther -Threads $laterKick -ShaCommittedUtc $beforeKick
Assert-True ($stateKickForTip.state -eq 'in_flight') 'kick posted after this tip existed is in_flight'

$already = Test-CodeAntReviewReplyAlreadyPosted -Threads $staleKick -ThreadId 104 -Reply '@codeant-ai: review'
Assert-True $already 'existing kick text is treated as already posted'
$missing = Test-CodeAntReviewReplyAlreadyPosted -Threads $staleKick -ThreadId 104 -Reply 'new reply'
Assert-True (-not $missing) 'new reply is not already posted'

$started = Read-ReviewStateFixture -Name 'started-only.json'
$stateStarted = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipThis -Threads $started
Assert-True ($stateStarted.state -eq 'in_flight') 'started-only is in_flight'
Assert-True (@(Get-CodeAntReviewFindings -PullRequestId $prId -Threads $started).Count -eq 0) 'started-only has no findings'

$none = Read-ReviewStateFixture -Name 'no-table.json'
$stateNone = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipThis -Threads $none
Assert-True ($stateNone.state -eq 'none') 'no-table is none'
Assert-True ($null -eq $stateNone.reviewedSha) 'no-table has no reviewedSha'

try {
    $emptyFindings = Get-CodeAntFileFindingsFromThreads -Threads @()
    $emptyCounts = Get-CodeAntFindingCounts -Findings $emptyFindings
    Assert-True ($emptyCounts.active -eq 0) 'empty findings active=0'
    Assert-True ($emptyCounts.fixed -eq 0) 'empty findings fixed=0'
    Assert-True ($emptyCounts.total -eq 0) 'empty findings total=0'
}
catch {
    [void]$failures.Add("empty findings must not throw: $($_.Exception.Message)")
}

try {
    $emptyThreadCounts = Get-CodeAntFindingCounts -Threads @()
    Assert-True ($emptyThreadCounts.active -eq 0) 'empty threads active=0'
    Assert-True ($emptyThreadCounts.total -eq 0) 'empty threads total=0'
}
catch {
    [void]$failures.Add("empty threads must not throw: $($_.Exception.Message)")
}

Assert-True ((Get-CodeAntReviewRequestContent) -eq '@codeant-ai: review') 'kick text is @codeant-ai: review'
Assert-True ((Resolve-CodeAntReviewCompleteThreadStatus -Disposition fixed) -eq 'Fixed') 'fixed maps to Fixed'
Assert-True ((Resolve-CodeAntReviewCompleteThreadStatus -Disposition dismissed) -eq 'WontFix') 'dismissed maps to WontFix'

$dateHint = [datetime]::SpecifyKind([datetime]'2026-09-08T10:00:00', [DateTimeKind]::Utc)
$fullDate = ConvertFrom-CodeAntReviewStatusDateText -Text 'Sep 8, 2026 · 10:00'
$timeOnly = ConvertFrom-CodeAntReviewStatusDateText -Text '10:02' -DateHint $dateHint
Assert-True ($fullDate -eq $dateHint) 'full review timestamp parses exactly under Windows PowerShell 5.1'
Assert-True ($timeOnly -eq $dateHint.AddMinutes(2)) 'time-only review timestamp uses the supplied date'

# Live ADO text carries a real U+00B7 middle dot (JSON-decoded), unlike this
# file's ANSI-decoded literals - regression for the PR 31460 stuck in_flight:
# the row date must win over a comment fallback on a different day.
$liveDot = [string][char]0xB7
$liveFull = ConvertFrom-CodeAntReviewStatusDateText -Text "Oct 22, 2026 $liveDot 17:36"
Assert-True ($liveFull -eq [datetime]::SpecifyKind([datetime]'2026-10-22T17:36:00', [DateTimeKind]::Utc)) 'live U+00B7 timestamp parses to its own date under Windows PowerShell 5.1'
$liveTable = "## Review Status`n`n| Status | Commit | Started (UTC) | Finished (UTC) |`n| --- | --- | --- | --- |`n| Reviewed your PR | ``2bb4266`` | Oct 22, 2026 $liveDot 17:36 | 17:43 |"
$liveRows = @(Get-CodeAntReviewStatusTableRowsFromContent -Content $liveTable -FallbackUtc ([datetime]::SpecifyKind([datetime]'2026-10-21T16:08:46', [DateTimeKind]::Utc)))
Assert-True ($liveRows.Count -eq 1) 'live status table yields one row'
if ($liveRows.Count -eq 1) {
    Assert-True ($liveRows[0].StartedUtc -eq [datetime]::SpecifyKind([datetime]'2026-10-22T17:36:00', [DateTimeKind]::Utc)) 'live row start keeps the row date, not the comment date'
    Assert-True ($liveRows[0].FinishedUtc -eq [datetime]::SpecifyKind([datetime]'2026-10-22T17:43:00', [DateTimeKind]::Utc)) 'live row finish time anchors to the row start date'
}

$earlierSameDay = ConvertFrom-CodeAntReviewStatusDateText -Text '09:58' -DateHint $dateHint
Assert-True ($earlierSameDay -eq $dateHint.AddMinutes(-2)) 'an earlier same-day time stays on the hint date'
$wrappedFinish = ConvertFrom-CodeAntReviewStatusDateText -Text '09:58' -DateHint $dateHint -AllowNextDay
Assert-True ($wrappedFinish -eq $dateHint.AddDays(1).AddMinutes(-2)) 'a finish before its start rolls past midnight'

$overnightTable = @'
## Review Status

| Status | Commit | Started (UTC) | Finished (UTC) |
| --- | --- | --- | --- |
| Completed | [`abcdef1`] | 23:50 | 00:05 |
'@
$overnightRows = @(Get-CodeAntReviewStatusTableRowsFromContent -Content $overnightTable -FallbackUtc $dateHint)
Assert-True ($overnightRows.Count -eq 1) 'overnight status table yields one row'
if ($overnightRows.Count -eq 1) {
    Assert-True ($overnightRows[0].StartedUtc -eq $dateHint.Date.AddHours(23).AddMinutes(50)) 'table start time keeps the comment date'
    Assert-True ($overnightRows[0].FinishedUtc -eq $dateHint.Date.AddDays(1).AddMinutes(5)) 'table finish time rolls to the next day'
}

Remove-Variable -Name CodeAntReviewShaCommittedUtcCache -Scope Script -ErrorAction SilentlyContinue
$threwUnsetCache = $false
try {
    $null = Get-CodeAntReviewShaCommittedUtc -Sha $tipThis -WorkspaceRoot $scriptDir
}
catch {
    $threwUnsetCache = $true
    [void]$failures.Add("uninitialized cache must not throw: $($_.Exception.Message)")
}
Assert-True (-not $threwUnsetCache) 'uninitialized cache does not throw under strict mode'

$script:CodeAntReviewShaCommittedUtcCache = @{}
1..40 | ForEach-Object { $script:CodeAntReviewShaCommittedUtcCache["k$_"] = $_ }
$repoRoot = (Get-Item -LiteralPath $scriptDir).Parent.Parent.Parent.Parent.FullName
$null = Get-CodeAntReviewShaCommittedUtc -Sha $tipThis -WorkspaceRoot $repoRoot
Assert-True ($script:CodeAntReviewShaCommittedUtcCache.Count -le 32) 'SHA commit-time cache stays bounded'

$wrote = Invoke-CodeAntReviewWriteComment -Write { 'ok' } -PostedOnThread { $false }
Assert-True ($wrote -eq 'ok') 'successful write returns the post'
$afterTimeout = Invoke-CodeAntReviewWriteComment -Write { throw 'timeout' } -PostedOnThread { $true }
Assert-True ($null -eq $afterTimeout) 'timeout after the server accepted the reply is treated as already posted'
$threwWrite = $false
try {
    Invoke-CodeAntReviewWriteComment -Write { throw 'boom' } -PostedOnThread { $false } | Out-Null
}
catch {
    $threwWrite = $true
}
Assert-True $threwWrite 'failed write is rethrown when the thread still lacks the reply'

$rejectedSha = Get-CodeAntReviewShaCommittedUtc -Sha '--pretty=evil' -WorkspaceRoot $repoRoot
Assert-True ($null -eq $rejectedSha) 'non-hex SHA is rejected before git is invoked'
$dashedSha = Get-CodeAntReviewShaCommittedUtc -Sha '-1' -WorkspaceRoot $repoRoot
Assert-True ($null -eq $dashedSha) 'dashed SHA is rejected before git is invoked'
$headSha = ([string](& git -C $repoRoot rev-parse HEAD)).Trim()
$headUtc = Get-CodeAntReviewShaCommittedUtc -Sha $headSha -WorkspaceRoot $repoRoot
Assert-True ($null -ne $headUtc) 'a real commit SHA still returns a commit time'

$otherRunning = @'
{
  "value": [
    {
      "id": 201,
      "status": "active",
      "comments": [
        {
          "id": 1,
          "author": { "displayName": "Code Ant" },
          "content": "## CodeAnt AI — Review Status\n\n| Status | Commit | Started (UTC) | Finished (UTC) |\n| --- | --- | --- | --- |\n| Reviewing | `dddddddd` | Sep 8, 2026 · 12:00 |  |\n",
          "publishedDate": "2026-09-08T12:00:00Z"
        }
      ]
    }
  ]
}
'@ | ConvertFrom-Json
$stateOtherRunning = Get-CodeAntReviewState -PullRequestId $prId -Sha $tipThis -Threads $otherRunning
Assert-True ($stateOtherRunning.state -eq 'none') 'running row for another commit is not in_flight for this tip'

$nonTrigger = @(
    [pscustomobject]@{
        id       = 1
        status   = 'active'
        comments = @([pscustomobject]@{ id = 1; content = 'file comment' })
    }
)
$clearedNone = Clear-CodeAntReviewRequests -PullRequestId $prId -Threads $nonTrigger
Assert-True ($clearedNone.ResolvedCount -eq 0) 'non-trigger threads are not cleared'
Assert-True (@($clearedNone.Warnings).Count -eq 0) 'non-trigger clear has no warnings'
$clearedEmpty = Clear-CodeAntReviewRequests -PullRequestId $prId -Threads @()
Assert-True ($clearedEmpty.ResolvedCount -eq 0) 'explicit empty threads snapshot does not fetch'

# --- Meta thread clear (Closed) vs kick (Fixed) ---
$script:CodeAntStatusCalls = New-Object 'System.Collections.Generic.List[object]'
function Set-CodeAntAdoThreadStatus {
    param(
        [int]$PullRequestId,
        [int]$ThreadId,
        [string]$Status = 'Fixed',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = '',
        [string]$WorkspaceRoot = ''
    )
    $script:CodeAntStatusCalls.Add([pscustomobject]@{
            ThreadId = $ThreadId
            Status   = $Status
        })
}

$codeAntAuthor = [pscustomobject]@{ displayName = 'Code Ant' }
$humanAuthor = [pscustomobject]@{ displayName = 'Alice' }
$metaTicket = [pscustomobject]@{
    id       = 301
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = "## Ticket Scope Review`n| Area | Result |`n| --- | --- |`n| Scope | OK |"
        })
}
$metaTicketEmoji = [pscustomobject]@{
    id       = 313
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            # Live posts prefix a ticket emoji before "Ticket Scope Review" (thread 177846).
            # Built from code points so the fixture survives Windows PowerShell 5.1 ANSI decoding.
            content = ("## " + [char]::ConvertFromUtf32(0x1F3AB) + " Ticket Scope Review`n| Area | Result |`n| --- | --- |`n| Scope | OK |")
        })
}
$metaStatus = [pscustomobject]@{
    id       = 302
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = ("## CodeAnt AI - Review Status" + [Environment]::NewLine + "| Status | Commit |" + [Environment]::NewLine + "| --- | --- |" + [Environment]::NewLine + "| Done | ``aaaaaaaa`` |")
        })
}
$metaStatusEmoji = [pscustomobject]@{
    id       = 310
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            # Live posts prefix an emoji token before "CodeAnt AI — Review Status".
            content = ("## " + [char]::ConvertFromUtf32(0x1F916) + " CodeAnt AI " + [char]0x2014 + " Review Status`n| Status | Commit |")
        })
}
$metaGate = [pscustomobject]@{
    id       = 303
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = "## CodeAnt Quality Gate Results`n| Gate | Result |"
        })
}
$metaGateEmoji = [pscustomobject]@{
    id       = 311
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = "# :checkered_flag: CodeAnt Quality Gate Results`n| Gate | Result |"
        })
}
$metaNitpicks = [pscustomobject]@{
    id       = 312
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = "## CodeAnt Nitpicks`n<details><summary>1 code suggestion</summary></details>"
        })
}
$kickThread = [pscustomobject]@{
    id       = 304
    status   = 'active'
    comments = @([pscustomobject]@{ id = 1; content = '@codeant-ai: review' })
}
$fileThread = [pscustomobject]@{
    id            = 305
    status        = 'active'
    threadContext = [pscustomobject]@{ filePath = '/src/App.cs' }
    comments      = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = '## Ticket Scope Review should not match file threads'
        })
}
$humanThread = [pscustomobject]@{
    id       = 306
    status   = 'active'
    comments = @([pscustomobject]@{ id = 1; author = $humanAuthor; content = 'LGTM after the scope pass' })
}
$humanMentionGate = [pscustomobject]@{
    id       = 307
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $humanAuthor
            content = 'Did we pass the Quality Gate yet?'
        })
}
$metaPrRisk = [pscustomobject]@{
    id       = 308
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = "**CodeAnt PR Risk: Medium Risk**`n- Needs attention before merging."
        })
}
$humanMentionPrRisk = [pscustomobject]@{
    id       = 309
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $humanAuthor
            content = 'Is the PR Risk score still medium?'
        })
}

Assert-True (Test-IsCodeAntMetaThread -Thread $metaTicket) 'Ticket Scope Review is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaTicketEmoji) 'emoji Ticket Scope Review is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaStatus) 'Review Status table is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaStatusEmoji) 'emoji Review Status is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaGate) 'Quality Gate is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaGateEmoji) 'emoji Quality Gate is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaNitpicks) 'Nitpicks is meta'
$metaNitpicksBadge = [pscustomobject]@{
    id       = 314
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = ("## <a href=`"https://codeant.ai/`" title=`"CodeAnt AI`"><img src=`"https://example.invalid/badge.svg`" alt=`"CodeAnt`" /></a>&nbsp; CodeAnt Nitpicks`n`n#### 1. Pack dogfood requires both packs.`n`nComment mismatch " + [char]0x00B7 + " [``contrib/devops-leading-brief/pack.json:8``](https://example.invalid/pack.json)")
        })
}
Assert-True (Test-IsCodeAntMetaThread -Thread $metaNitpicksBadge) 'badge Nitpicks heading is meta'
$badgeNitpicks = @(Get-CodeAntNitpickFindingsFromThreads -Threads @($metaNitpicksBadge) -ActiveOnly)
Assert-True ($badgeNitpicks.Count -eq 1) 'badge Nitpicks heading yields the suggestion'
if ($badgeNitpicks.Count -eq 1) {
    Assert-True ($badgeNitpicks[0].Path -eq '/contrib/devops-leading-brief/pack.json') 'badge nitpick Path'
    Assert-True ($badgeNitpicks[0].Line -eq '8') 'badge nitpick Line'
    Assert-True ($badgeNitpicks[0].Category -eq 'Comment mismatch') 'badge nitpick Category'
    Assert-True ($badgeNitpicks[0].Source -eq 'nitpick') 'badge nitpick Source'
}
Assert-True (Test-IsCodeAntMetaThread -Thread $metaPrRisk) 'PR Risk is meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $kickThread)) 'kick is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $fileThread)) 'file thread is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $humanThread)) 'human prose is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $humanMentionGate)) 'human Quality Gate mention is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $humanMentionPrRisk)) 'human PR Risk mention is not meta'

$script:CodeAntStatusCalls.Clear()
$metaCleared = Clear-CodeAntMetaThreads -PullRequestId $prId -Threads @(
    $metaTicket, $metaTicketEmoji, $metaStatus, $metaStatusEmoji, $metaGate, $metaGateEmoji, $metaNitpicks, $metaPrRisk,
    $kickThread, $fileThread, $humanThread, $humanMentionGate, $humanMentionPrRisk
)
Assert-True ($metaCleared.ResolvedCount -eq 8) 'meta clear resolves eight meta threads'
Assert-True ((@($metaCleared.ThreadIds | Sort-Object) -join ',') -eq '301,302,303,308,310,311,312,313') 'meta clear thread ids'
foreach ($call in $script:CodeAntStatusCalls.ToArray()) {
    Assert-True ($call.Status -eq 'Closed') "meta clear uses Closed (thread $($call.ThreadId))"
}

$script:CodeAntStatusCalls.Clear()
$kickCleared = Clear-CodeAntRetriggerThreads -PullRequestId $prId -Threads @($kickThread, $metaTicket)
Assert-True ($kickCleared.ResolvedCount -eq 1) 'retrigger clear still only clears kicks'
Assert-True ($script:CodeAntStatusCalls.Count -eq 1) 'retrigger clear one status call'
Assert-True ($script:CodeAntStatusCalls[0].ThreadId -eq 304) 'kick thread id'
Assert-True ($script:CodeAntStatusCalls[0].Status -eq 'Fixed') 'kick clear still Fixed'

$script:CodeAntStatusCalls.Clear()
$merged = Clear-CodeAntReviewRequests -PullRequestId $prId -Threads @(
    $kickThread, $metaTicket, $fileThread, $humanThread
)
Assert-True ($merged.ResolvedCount -eq 2) 'review-requests clear resolves kick + meta'
Assert-True ((@($merged.ThreadIds | Sort-Object) -join ',') -eq '301,304') 'merged thread ids'
$byId = @{}
foreach ($c in $script:CodeAntStatusCalls.ToArray()) { $byId[[int]$c.ThreadId] = [string]$c.Status }
Assert-True ($byId[304] -eq 'Fixed') 'merged kick → Fixed'
Assert-True ($byId[301] -eq 'Closed') 'merged meta → Closed'

# --- Quality Gate + Nitpicks meta parsing (fixture from live PR 31460) ---
$qgFixture = Read-ReviewStateFixture -Name 'quality-gate-nitpicks-pr31460.json'
$gate31460 = Get-CodeAntQualityGateFromThreads -Threads $qgFixture
Assert-True ($null -ne $gate31460) 'PR31460 quality gate is parsed'
if ($null -ne $gate31460) {
    Assert-True ($gate31460.status -eq 'failed') 'PR31460 gate status failed'
    Assert-True ($gate31460.metaThreadId -eq 178822) 'PR31460 gate metaThreadId'
    Assert-True ($gate31460.parentCommentId -eq 1) 'PR31460 gate parentCommentId'
    Assert-True ($gate31460.commit -eq 'cbc1427d') 'PR31460 gate commit'
    Assert-True ($gate31460.resultsUrl -match 'commit_id=cbc1427d') 'PR31460 gate resultsUrl'
    Assert-True (@($gate31460.gates).Count -eq 4) 'PR31460 gate has four gate rows'
    $secretsGate = @($gate31460.gates | Where-Object { $_.name -eq 'Secrets' })[0]
    Assert-True ($secretsGate.status -eq 'failed') 'PR31460 Secrets gate failed'
    Assert-True ($secretsGate.findingCount -eq 1) 'PR31460 Secrets gate findingCount 1'
    $sastGate = @($gate31460.gates | Where-Object { $_.name -eq 'SAST' })[0]
    Assert-True ($sastGate.status -eq 'passed') 'PR31460 SAST gate passed'
}

$rawSecurity = @(Get-CodeAntSecurityFindingsFromThreads -Threads $qgFixture)
Assert-True ($rawSecurity.Count -eq 1) 'PR31460 has one raw security finding'
if ($rawSecurity.Count -eq 1) {
    Assert-True ($rawSecurity[0].source -eq 'qualityGate') 'raw security source'
    Assert-True ($rawSecurity[0].gate -eq 'Secrets') 'raw security gate'
    Assert-True ($rawSecurity[0].path -eq 'contrib/codeant-triage/content/scripts/Get-CodeAntPromotePreference.ps1') 'raw security path'
    Assert-True ($rawSecurity[0].line -eq 151) 'raw security line'
    Assert-True ($rawSecurity[0].type -eq 'Cryptographic Key Material') 'raw security type'
    Assert-True ($rawSecurity[0].confidence -eq 'HIGH') 'raw security confidence'
    Assert-True ($rawSecurity[0].status -eq 'open') 'raw security status open'
    Assert-True ($rawSecurity[0].metaThreadId -eq 178822) 'raw security metaThreadId'
}

$nitpicks31460 = @(Get-CodeAntNitpickFindingsFromThreads -Threads $qgFixture -ActiveOnly)
Assert-True ($nitpicks31460.Count -eq 2) 'PR31460 has two nitpick findings'
if ($nitpicks31460.Count -eq 2) {
    Assert-True ($nitpicks31460[0].Id -eq '178827-1') 'nitpick 1 Id'
    Assert-True ($nitpicks31460[0].Path -eq '/contrib/codeant-triage/adapters/cursor/commands/codeant-triage.md') 'nitpick 1 Path'
    Assert-True ($nitpicks31460[0].Line -eq '197') 'nitpick 1 Line'
    Assert-True ($nitpicks31460[0].Category -eq 'Api mismatch') 'nitpick 1 Category'
    Assert-True ($nitpicks31460[0].Source -eq 'nitpick') 'nitpick 1 Source'
    Assert-True ($nitpicks31460[0].MetaThreadId -eq 178827) 'nitpick 1 MetaThreadId'
    Assert-True ($nitpicks31460[1].Line -eq '55') 'nitpick 2 Line'
    Assert-True ($nitpicks31460[1].Comment -match 'prose fallback conflicts') 'nitpick 2 Comment is the suggestion title'
}

# Dismissed meta findings must not resurface: a human WontFix summary in the
# shared (still active) meta thread excludes the locations it lists.
$dismissedFixture = Read-ReviewStateFixture -Name 'quality-gate-nitpicks-pr31460.json'
foreach ($t in @(Get-CodeAntReviewThreadList -Threads $dismissedFixture)) {
    if ([int]$t.id -eq 178827) {
        $t.comments = @($t.comments) + @([pscustomobject]@{
                id      = 99
                author  = $humanAuthor
                content = "**Issue:** entry-gate requirements omit the ambiguous-UAP selection`n**WontFix Reason:** covered elsewhere - contrib/codeant-triage/adapters/cursor/commands/codeant-triage.md ~197"
            })
    }
    if ([int]$t.id -eq 178822) {
        $t.comments = @($t.comments) + @([pscustomobject]@{
                id      = 99
                author  = $humanAuthor
                content = "**Issue:** hardcoded credential in a test helper`n**WontFix Reason:** deliberate test data - contrib/codeant-triage/content/scripts/Get-CodeAntPromotePreference.ps1 ~151"
            })
    }
}
$afterDismissNitpicks = @(Get-CodeAntNitpickFindingsFromThreads -Threads $dismissedFixture -ActiveOnly)
Assert-True ($afterDismissNitpicks.Count -eq 1) 'dismissed nitpick does not resurface from an active meta thread'
if ($afterDismissNitpicks.Count -eq 1) {
    Assert-True ($afterDismissNitpicks[0].Line -eq '55') 'remaining nitpick is the one not dismissed'
}
$afterDismissSecurity = @(Get-CodeAntSecurityFindingsFromThreads -Threads $dismissedFixture)
Assert-True ($afterDismissSecurity.Count -eq 0) 'dismissed security finding does not resurface from an active gate thread'
$codeAntSelfDismiss = Read-ReviewStateFixture -Name 'quality-gate-nitpicks-pr31460.json'
foreach ($t in @(Get-CodeAntReviewThreadList -Threads $codeAntSelfDismiss)) {
    if ([int]$t.id -eq 178827) {
        $t.comments = @($t.comments) + @([pscustomobject]@{
                id      = 98
                author  = $codeAntAuthor
                content = "**WontFix Reason:** contrib/codeant-triage/adapters/cursor/commands/codeant-triage.md ~197"
            })
    }
}
Assert-True (@(Get-CodeAntNitpickFindingsFromThreads -Threads $codeAntSelfDismiss -ActiveOnly).Count -eq 2) 'CodeAnt-authored text never counts as dismissal evidence'

$unified31460 = @(Get-CodeAntReviewFindings -PullRequestId $prId -Threads $qgFixture)
Assert-True ($unified31460.Count -eq 3) 'PR31460 unified findings = 2 nitpicks + 1 security'
if ($unified31460.Count -eq 3) {
    Assert-True ((@($unified31460 | ForEach-Object { $_.Number }) -join ',') -eq '1,2,3') 'unified findings renumbered 1..3'
    $sec = $unified31460[2]
    Assert-True ($sec.Source -eq 'qualityGate') 'canonical security Source'
    Assert-True ($sec.Path -eq '/contrib/codeant-triage/content/scripts/Get-CodeAntPromotePreference.ps1') 'canonical security Path has leading slash'
    Assert-True ($sec.Line -eq '151') 'canonical security Line is string'
    Assert-True ($sec.Comment -match 'Cryptographic Key Material at line 151') 'canonical security Comment carries type and line'
    Assert-True ($sec.Comment -match 'HIGH confidence') 'canonical security Comment carries confidence'
    Assert-True ($null -eq $sec.ThreadId) 'canonical security has no own ThreadId'
    Assert-True ($sec.MetaThreadId -eq 178822) 'canonical security MetaThreadId'
}
Assert-True (@(Get-CodeAntReviewFindings -PullRequestId $prId -Threads $qgFixture -FileOnly).Count -eq 0) 'PR31460 FileOnly excludes nitpicks and security'

# Explain scaffold: pre-filled slots for the one-turn Treat gate.
$nitpickScaffold = Get-CodeAntFindingScaffold -Finding $nitpicks31460[0] -Heading 'Finding #1 of 2'
Assert-True ($nitpickScaffold -match 'Finding #1 of 2') 'scaffold carries the heading'
Assert-True ($nitpickScaffold -match 'codeant-triage\.md') 'scaffold carries the finding location'
Assert-True ($nitpickScaffold -match 'This fallback asks for a prose choice') 'scaffold pre-fills CodeAnt said'
Assert-True ($nitpickScaffold -match '\*\*Verdict\*\*\s+<complete:') 'scaffold leaves a Verdict slot to complete'
Assert-True ($nitpickScaffold -match '\*\*Recommendation\*\*\s+<complete:') 'scaffold leaves a Recommendation slot to complete'
Assert-True ($nitpickScaffold -notmatch '\*\*(Header|CodeAnt said|Context|Rule cross-check|Verdict|Proposed change|Recommendation):\*\*') 'scaffold uses blocked sections, never inline label: body'
Assert-True ($nitpickScaffold -match '\*\*Header\*\*\r?\nFinding #1 of 2') 'scaffold Header label sits on its own line above its body'
Assert-True ($nitpickScaffold -match '\r?\n\r?\n\*\*Context\*\*') 'scaffold separates sections with a blank line'
$rawScaffold = Get-CodeAntFindingScaffold -Finding $rawSecurity[0] -Heading 'Security finding #S1 of 1'
Assert-True ($rawScaffold -match 'Cryptographic Key Material at line 151') 'raw security scaffold pre-fills type and line (no Comment property needed)'
$securityScaffold = Get-CodeAntFindingScaffold -Finding $unified31460[2] -Heading 'Security finding #S1 of 1'
Assert-True ($securityScaffold -match 'Cryptographic Key Material at line 151') 'security scaffold pre-fills type and line'
Assert-True ($securityScaffold -match 'Get-CodeAntPromotePreference\.ps1') 'security scaffold carries the path'

# Passed gate: no security findings, nothing unified.
$passedGateThread = [pscustomobject]@{
    id       = 901
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = "# :checkered_flag: CodeAnt Quality Gate Results`n`n## :white_check_mark: Overall Status: PASSED`n`n| Quality Gate | Status | Details |`n|---|---|---|`n| **Secrets** | :white_check_mark: PASSED | No secrets |`n`n[View Full Results](https://app.codeant.ai/quality-gates/results?repo=x&commit_id=abc&service=azure-devops)"
        })
}
$passedGate = Get-CodeAntQualityGateFromThreads -Threads @($passedGateThread)
Assert-True ($null -ne $passedGate -and $passedGate.status -eq 'passed') 'passed gate parses as passed'
Assert-True (@(Get-CodeAntSecurityFindingsFromThreads -Threads @($passedGateThread)).Count -eq 0) 'passed gate has no security findings'
Assert-True (@(Get-CodeAntReviewFindings -PullRequestId $prId -Threads @($passedGateThread)).Count -eq 0) 'passed gate contributes no unified findings'

# Failed gate with unparseable detail: gate-level fallback, never dropped.
$fallbackGateThread = [pscustomobject]@{
    id       = 902
    status   = 'active'
    comments = @([pscustomobject]@{
            id      = 1
            author  = $codeAntAuthor
            content = "# :checkered_flag: CodeAnt Quality Gate Results`n`n## :x: Overall Status: FAILED`n`n[View Full Results](https://app.codeant.ai/quality-gates/results?repo=x&commit_id=def&service=azure-devops)"
        })
}
$fallbackRaw = @(Get-CodeAntSecurityFindingsFromThreads -Threads @($fallbackGateThread))
Assert-True ($fallbackRaw.Count -eq 1) 'failed gate without detail still yields one finding'
if ($fallbackRaw.Count -eq 1) {
    Assert-True ([string]::IsNullOrWhiteSpace([string]$fallbackRaw[0].path)) 'fallback finding has empty path'
    Assert-True ($fallbackRaw[0].resultsUrl -match 'commit_id=def') 'fallback finding carries resultsUrl'
}
$fallbackUnified = @(Get-CodeAntReviewFindings -PullRequestId $prId -Threads @($fallbackGateThread))
Assert-True ($fallbackUnified.Count -eq 1) 'fallback yields one unified finding'
if ($fallbackUnified.Count -eq 1) {
    Assert-True ($fallbackUnified[0].Path -eq '') 'fallback canonical Path is empty (specialist locates it)'
    Assert-True ($fallbackUnified[0].Comment -match 'no file/line detail') 'fallback canonical Comment says no detail posted'
    $fallbackScaffold = Get-CodeAntFindingScaffold -Finding $fallbackUnified[0] -Heading 'Security finding #S1 of 1'
    Assert-True ($fallbackScaffold -match 'location not posted') 'pathless scaffold says location not posted, do not invent'
}

# Closed gate thread no longer contributes findings.
$qgCommentOnly = @($qgFixture.value | Where-Object { $_.id -eq 178822 })[0].comments[0]
$closedGateThread = [pscustomobject]@{ id = 178822; status = 'closed'; comments = @($qgCommentOnly) }
Assert-True ($null -eq (Get-CodeAntQualityGateFromThreads -Threads @($closedGateThread))) 'closed gate thread is not parsed as active'
Assert-True (@(Get-CodeAntSecurityFindingsFromThreads -Threads @($closedGateThread)).Count -eq 0) 'closed gate thread yields no security findings'

# Meta completion: guard, fixed = no ADO, dismissed = one summary + Closed.
$guardThrew = $false
try {
    Complete-CodeAntReviewFinding -Finding $unified31460[2] -Disposition fixed -Reply 'x' -PullRequestId $prId | Out-Null
}
catch {
    $guardThrew = ([string]$_.Exception.Message -match 'Complete-CodeAntReviewMetaFindings')
}
Assert-True $guardThrew 'per-finding Complete rejects meta-sourced findings'

$metaFixed = Complete-CodeAntReviewMetaFindings -Findings @($unified31460[2]) -Disposition fixed -PullRequestId $prId
Assert-True ($metaFixed.Status -eq 'AwaitingReReview') 'meta fixed waits for re-review proof'
Assert-True ($metaFixed.MetaThreadId -eq 178822) 'meta fixed MetaThreadId'

$script:MetaPostCalls = New-Object 'System.Collections.Generic.List[object]'
$script:MetaStatusCalls = New-Object 'System.Collections.Generic.List[object]'
function Get-CodeAntReviewThreadById {
    param([int]$PullRequestId, $ThreadId, [string]$WorkspaceRoot = '', [string]$Collection = '', [string]$Project = '', [string]$Repository = '', [string]$ServerUrl = '')
    return [pscustomobject]@{
        id       = [int]$ThreadId
        status   = 'active'
        comments = @([pscustomobject]@{ id = 1; author = [pscustomobject]@{ displayName = 'Code Ant' }; content = 'meta body' })
    }
}
function Import-CodeAntAdoCore { return $true }
function Add-AdoCorePullRequestThreadComment {
    param([int]$PullRequestId, [int]$ThreadId, [int]$ParentCommentId, [string]$Content, [string]$WorkspaceRoot = '', [string]$Collection = '', [string]$Project = '', [string]$Repository = '', [string]$ServerUrl = '')
    $script:MetaPostCalls.Add([pscustomobject]@{ ThreadId = $ThreadId; ParentCommentId = $ParentCommentId; Content = $Content })
    return [pscustomobject]@{ CommentId = 99 }
}
function Set-AdoCorePullRequestThreadStatus {
    param([int]$PullRequestId, [int]$ThreadId, [string]$Status, [string]$WorkspaceRoot = '', [string]$Collection = '', [string]$Project = '', [string]$Repository = '', [string]$ServerUrl = '')
    $script:MetaStatusCalls.Add([pscustomobject]@{ ThreadId = $ThreadId; Status = $Status })
}
$metaDismissed = Complete-CodeAntReviewMetaFindings -Findings @($nitpicks31460) -Disposition dismissed -Reply 'summary reply' -PullRequestId $prId
Assert-True ($metaDismissed.Status -eq 'Closed') 'meta dismissed closes the meta thread'
Assert-True ($metaDismissed.FindingCount -eq 2) 'meta dismissed covers both nitpicks'
Assert-True ($script:MetaPostCalls.Count -eq 1) 'meta dismissed posts exactly one summary reply'
Assert-True ($script:MetaStatusCalls.Count -eq 1 -and $script:MetaStatusCalls[0].Status -eq 'Closed') 'meta dismissed sets Closed once'

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    Write-Error ('Test-CodeAntReviewState FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join $sep))
    exit 1
}

Write-Output 'OK: codeant-review-state'
exit 0
