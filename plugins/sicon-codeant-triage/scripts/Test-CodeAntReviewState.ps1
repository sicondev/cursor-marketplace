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
Assert-True (Test-IsCodeAntMetaThread -Thread $metaStatus) 'Review Status table is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaStatusEmoji) 'emoji Review Status is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaGate) 'Quality Gate is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaGateEmoji) 'emoji Quality Gate is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaNitpicks) 'Nitpicks is meta'
Assert-True (Test-IsCodeAntMetaThread -Thread $metaPrRisk) 'PR Risk is meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $kickThread)) 'kick is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $fileThread)) 'file thread is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $humanThread)) 'human prose is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $humanMentionGate)) 'human Quality Gate mention is not meta'
Assert-True (-not (Test-IsCodeAntMetaThread -Thread $humanMentionPrRisk)) 'human PR Risk mention is not meta'

$script:CodeAntStatusCalls.Clear()
$metaCleared = Clear-CodeAntMetaThreads -PullRequestId $prId -Threads @(
    $metaTicket, $metaStatus, $metaStatusEmoji, $metaGate, $metaGateEmoji, $metaNitpicks, $metaPrRisk,
    $kickThread, $fileThread, $humanThread, $humanMentionGate, $humanMentionPrRisk
)
Assert-True ($metaCleared.ResolvedCount -eq 7) 'meta clear resolves seven meta threads'
Assert-True ((@($metaCleared.ThreadIds | Sort-Object) -join ',') -eq '301,302,303,308,310,311,312') 'meta clear thread ids'
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

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    Write-Error ('Test-CodeAntReviewState FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join $sep))
    exit 1
}

Write-Output 'OK: codeant-review-state'
exit 0
