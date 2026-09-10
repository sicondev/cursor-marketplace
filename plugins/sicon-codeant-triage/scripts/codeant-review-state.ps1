#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:CodeAntReviewShaMinPrefixLength = 7
$script:CodeAntReviewShaCommittedUtcCache = @{}
$script:CodeAntReviewShaCommittedUtcCacheLimit = 32

function Test-CodeAntReviewShaPrefixMatch {
    param(
        [string]$Left,
        [string]$Right
    )

    if ([string]::IsNullOrWhiteSpace($Left) -or [string]::IsNullOrWhiteSpace($Right)) {
        return $false
    }
    $a = ([string]$Left).Trim().ToLowerInvariant()
    $b = ([string]$Right).Trim().ToLowerInvariant()
    if ($a -notmatch '^[0-9a-f]+$' -or $b -notmatch '^[0-9a-f]+$') {
        return $false
    }
    $shortLen = [Math]::Min($a.Length, $b.Length)
    if ($shortLen -lt $script:CodeAntReviewShaMinPrefixLength) {
        return $false
    }
    return $a.Substring(0, $shortLen) -eq $b.Substring(0, $shortLen)
}

function Get-CodeAntReviewRequestContent {
    return $script:CodeAntRetriggerCommentDefault
}

function Invoke-CodeAntReviewWriteComment {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Write,

        [Parameter(Mandatory = $true)]
        [scriptblock]$PostedOnThread
    )

    try {
        return & $Write
    }
    catch {
        if (& $PostedOnThread) {
            return $null
        }
        throw
    }
}

function Test-CodeAntReviewReplyAlreadyPosted {
    param(
        $Threads,
        $ThreadId,
        [string]$Reply
    )

    $expected = ([string]$Reply).Trim()
    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }
    foreach ($thread in @(Get-CodeAntReviewThreadList -Threads $Threads)) {
        $id = Get-PsObjectPropertyValue -Object $thread -Name 'id' -Default $null
        if ("$id" -ne "$ThreadId") { continue }
        foreach ($comment in (Get-AdoThreadComments -Thread $thread)) {
            if ((Get-AdoCommentContentText -Comment $comment).Trim() -eq $expected) { return $true }
        }
    }
    return $false
}

function Resolve-CodeAntReviewCompleteThreadStatus {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('fixed', 'dismissed')]
        [string]$Disposition
    )

    if ($Disposition -eq 'fixed') { return 'Fixed' }
    return 'WontFix'
}

function ConvertFrom-CodeAntReviewCommentDate {
    param($Comment)

    $when = Get-PsObjectPropertyValue -Object $Comment -Name 'publishedDate' -Default $null
    if (-not $when) {
        $when = Get-PsObjectPropertyValue -Object $Comment -Name 'lastUpdatedDate' -Default $null
    }
    if (-not $when) { return $null }
    return ([datetime]$when).ToUniversalTime()
}

function ConvertFrom-CodeAntReviewStatusDateText {
    param(
        [string]$Text,
        $DateHint = $null,
        [switch]$AllowNextDay
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $trimmed = $Text.Trim()
    $culture = [Globalization.CultureInfo]::GetCultureInfo('en-US')

    foreach ($format in @('MMM d, yyyy · HH:mm', 'MMM dd, yyyy · HH:mm', 'MMM d, yyyy · H:mm', 'MMM dd, yyyy · H:mm')) {
        $combined = [datetime]::MinValue
        if ([datetime]::TryParseExact(
                $trimmed,
                $format,
                $culture,
                [Globalization.DateTimeStyles]::AssumeUniversal,
                [ref]$combined
            )) {
            return $combined.ToUniversalTime()
        }
    }

    foreach ($format in @('HH:mm', 'H:mm')) {
        $timeOnly = [datetime]::MinValue
        if ([datetime]::TryParseExact(
                $trimmed,
                $format,
                $culture,
                [Globalization.DateTimeStyles]::NoCurrentDateDefault,
                [ref]$timeOnly
            )) {
            if ($null -ne $DateHint) {
                $hintUtc = ([datetime]$DateHint).ToUniversalTime()
                $combinedTime = $hintUtc.Date.AddHours($timeOnly.Hour).AddMinutes($timeOnly.Minute)
                if ($AllowNextDay -and $combinedTime -lt $hintUtc) {
                    $combinedTime = $combinedTime.AddDays(1)
                }
                return [datetime]::SpecifyKind($combinedTime, [DateTimeKind]::Utc)
            }
            return $null
        }
    }
    if ($trimmed -match '^\d{1,2}:\d{2}$') {
        return $null
    }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($trimmed, $culture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.ToUniversalTime()
    }
    return $null
}

function ConvertFrom-CodeAntReviewStatusCommitCell {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $value = $Text.Trim()
    if ($value -match '\[`?([0-9a-fA-F]+)`?\]') {
        return $Matches[1]
    }
    $value = $value.Trim('`').Trim()
    if ($value -match '([0-9a-fA-F]{7,40})') {
        return $Matches[1]
    }
    return ''
}

function Test-CodeAntReviewStatusFinishedText {
    param([string]$StatusText)
    return [bool]($StatusText -match '(?i)completed|finished|reviewed your pr')
}

function Test-CodeAntReviewStatusRunningText {
    param([string]$StatusText)
    return [bool]($StatusText -match '(?i)running|reviewing|in progress|started')
}

function Get-CodeAntReviewStatusTableRowsFromContent {
    param(
        [string]$Content,
        $FallbackUtc = $null
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'
    if ([string]::IsNullOrWhiteSpace($Content)) { return @($rows.ToArray()) }
    if ($Content -notmatch '(?i)Review Status') { return @($rows.ToArray()) }

    $lines = $Content -split '\r?\n'
    $headerIndex = -1
    $statusIdx = -1
    $commitIdx = -1
    $startedIdx = -1
    $finishedIdx = -1

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ([string]::IsNullOrWhiteSpace($lines[$i])) { continue }
        $cells = @(Split-MarkdownTableRowCells -Line $lines[$i])
        if ($cells.Count -eq 0) { continue }
        $headerNames = @($cells | ForEach-Object { $_.ToLowerInvariant() })
        if ($headerNames -contains 'status' -and $headerNames -contains 'commit') {
            $headerIndex = $i
            $statusIdx = [array]::IndexOf($headerNames, 'status')
            $commitIdx = [array]::IndexOf($headerNames, 'commit')
            $startedIdx = [array]::IndexOf($headerNames, 'started (utc)')
            if ($startedIdx -lt 0) { $startedIdx = [array]::IndexOf($headerNames, 'started') }
            $finishedIdx = [array]::IndexOf($headerNames, 'finished (utc)')
            if ($finishedIdx -lt 0) { $finishedIdx = [array]::IndexOf($headerNames, 'finished') }
            break
        }
    }
    if ($headerIndex -lt 0) { return @($rows.ToArray()) }

    for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -notmatch '^\|') { if ($rows.Count -gt 0) { break } else { continue } }
        if ($line -match '^\|\s*-+') { continue }
        $cells = @(Split-MarkdownTableRowCells -Line $line)
        if ($cells.Count -le $commitIdx -or $cells.Count -le $statusIdx) { continue }

        $statusText = [string]$cells[$statusIdx]
        $commit = ConvertFrom-CodeAntReviewStatusCommitCell -Text ([string]$cells[$commitIdx])
        $startedText = ''
        if ($startedIdx -ge 0 -and $cells.Count -gt $startedIdx) { $startedText = [string]$cells[$startedIdx] }
        $finishedText = ''
        if ($finishedIdx -ge 0 -and $cells.Count -gt $finishedIdx) { $finishedText = [string]$cells[$finishedIdx] }

        $startedUtc = ConvertFrom-CodeAntReviewStatusDateText -Text $startedText -DateHint $FallbackUtc
        $finishedUtc = ConvertFrom-CodeAntReviewStatusDateText -Text $finishedText -DateHint $startedUtc -AllowNextDay
        if (-not $finishedUtc) {
            $finishedUtc = ConvertFrom-CodeAntReviewStatusDateText -Text $finishedText -DateHint $FallbackUtc
        }

        $isFinished = Test-CodeAntReviewStatusFinishedText -StatusText $statusText
        $isRunning = (-not $isFinished) -and (
            (Test-CodeAntReviewStatusRunningText -StatusText $statusText) -or
            [string]::IsNullOrWhiteSpace($finishedText)
        )

        [void]$rows.Add([pscustomobject]@{
                StatusText  = $statusText
                Commit      = $commit
                StartedUtc  = $startedUtc
                FinishedUtc = $finishedUtc
                IsFinished  = $isFinished
                IsRunning   = $isRunning
            })
    }

    return @($rows.ToArray())
}

function Get-CodeAntReviewThreadList {
    param($Threads)

    if ($null -eq $Threads) { return @() }
    if ($Threads -is [System.Array] -and $Threads.Length -eq 1 -and $Threads[0] -is [System.Array]) {
        return @($Threads[0])
    }
    if (Test-PsObjectHasProperty -Object $Threads -Name 'value') {
        $value = $Threads.value
        if ($null -eq $value) { return @() }
        return @($value)
    }
    return @($Threads)
}

function Get-CodeAntReviewThreadsOrFetch {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        $Threads = $null,
        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if ($null -ne $Threads) {
        return @(Get-CodeAntReviewThreadList -Threads $Threads)
    }

    Import-CodeAntAdoCore | Out-Null
    return @(Get-CodeAntReviewThreadList -Threads (Get-AdoCorePullRequestThreads -PullRequestId $PullRequestId `
            -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
            -Repository $Repository -ServerUrl $ServerUrl))
}

function ConvertTo-CodeAntReviewThreadId {
    param($ThreadId)

    if ($null -eq $ThreadId -or "$ThreadId" -notmatch '^[0-9]+$') {
        throw 'ThreadId must be a positive integer.'
    }
    $parsed = [int]$ThreadId
    if ($parsed -le 0) {
        throw 'ThreadId must be a positive integer.'
    }
    return $parsed
}

function Get-CodeAntReviewThreadById {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        $ThreadId,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $threadIdInt = ConvertTo-CodeAntReviewThreadId -ThreadId $ThreadId
    Import-CodeAntAdoCore | Out-Null
    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $endpoints.ApiBase
    $uri = "$($endpoints.ApiBase)/pullRequests/$PullRequestId/threads/$threadIdInt`?api-version=7.0"
    return Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
}

function Select-CodeAntReviewLaterFinishedRow {
    param(
        $Current,
        $Candidate
    )

    if (-not $Candidate) { return $Current }
    if (-not $Current) { return $Candidate }
    $currentStamp = $Current.FinishedUtc
    if (-not $currentStamp) { $currentStamp = $Current.StartedUtc }
    $candidateStamp = $Candidate.FinishedUtc
    if (-not $candidateStamp) { $candidateStamp = $Candidate.StartedUtc }
    if ($candidateStamp -and ((-not $currentStamp) -or $candidateStamp -gt $currentStamp)) {
        return $Candidate
    }
    return $Current
}

function Get-CodeAntReviewShaCommittedUtc {
    param(
        [string]$Sha,
        [string]$WorkspaceRoot
    )

    if ([string]::IsNullOrWhiteSpace($Sha) -or [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return $null
    }
    if ($Sha -notmatch '^[0-9a-fA-F]+$') {
        return $null
    }
    if (-not (Get-Variable -Name CodeAntReviewShaCommittedUtcCache -Scope Script -ErrorAction SilentlyContinue) -or $null -eq $script:CodeAntReviewShaCommittedUtcCache) {
        $script:CodeAntReviewShaCommittedUtcCache = @{}
    }
    $cacheKey = "$WorkspaceRoot|$Sha"
    if ($script:CodeAntReviewShaCommittedUtcCache.ContainsKey($cacheKey)) {
        return $script:CodeAntReviewShaCommittedUtcCache[$cacheKey]
    }
    if ($script:CodeAntReviewShaCommittedUtcCache.Count -ge $script:CodeAntReviewShaCommittedUtcCacheLimit) {
        $script:CodeAntReviewShaCommittedUtcCache.Clear()
    }
    if (-not (Test-Path -LiteralPath $WorkspaceRoot)) {
        return $null
    }
    $gitMetadata = Join-Path $WorkspaceRoot '.git'
    if (-not (Test-Path -LiteralPath $gitMetadata)) {
        return $null
    }
    try {
        $raw = & git -C $WorkspaceRoot log -1 --format=%cI $Sha 2>$null
        if ([string]::IsNullOrWhiteSpace([string]$raw)) {
            $script:CodeAntReviewShaCommittedUtcCache[$cacheKey] = $null
            return $null
        }
        $utc = [datetime]::Parse(
            ([string]$raw).Trim(),
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind
        ).ToUniversalTime()
        $script:CodeAntReviewShaCommittedUtcCache[$cacheKey] = $utc
        return $utc
    }
    catch {
        return $null
    }
}

function Get-CodeAntReviewEvidence {
    param(
        $Threads,
        [string]$Sha,
        $ShaCommittedUtc = $null
    )

    $threadList = @(Get-CodeAntReviewThreadList -Threads $Threads)
    $latestActiveTriggerWhen = $null
    $latestTriggerWhen = $null
    $startedUtc = $null
    $finishedBoilerUtc = $null
    $hasStartedBoiler = $false
    $hasFinishedBoiler = $false
    $tipFinished = $null
    $latestFinished = $null
    $runningForTip = $false
    $anyRunning = $false
    $recentCutoff = (Get-Date).ToUniversalTime().AddMinutes(-10)

    foreach ($thread in $threadList) {
        $threadContext = Get-PsObjectPropertyValue -Object $thread -Name 'threadContext' -Default $null
        $filePath = ''
        if ($null -ne $threadContext) {
            $filePath = [string](Get-PsObjectPropertyValue -Object $threadContext -Name 'filePath' -Default '')
        }
        $status = Get-PsObjectPropertyValue -Object $thread -Name 'status' -Default 'active'
        $isFileThread = -not [string]::IsNullOrWhiteSpace($filePath)
        $isActiveThread = Test-IsActiveAdoThread -Status $status

        foreach ($comment in (Get-AdoThreadComments -Thread $thread)) {
            $body = Get-AdoCommentContentText -Comment $comment
            $when = ConvertFrom-CodeAntReviewCommentDate -Comment $comment
            if (-not $isFileThread -and (Test-IsCodeAntRetriggerCommentBody -Body $body) -and $when) {
                if (-not $latestTriggerWhen -or $when -gt $latestTriggerWhen) { $latestTriggerWhen = $when }
                if ($isActiveThread -and (-not $latestActiveTriggerWhen -or $when -gt $latestActiveTriggerWhen)) {
                    $latestActiveTriggerWhen = $when
                }
            }
            if ((Get-AdoCommentAuthorDisplayName -Comment $comment) -ne $script:CodeAntAuthorName) { continue }
            $kind = Test-IsCodeAntReviewBoilerplate -Content $body
            if ($kind -eq 'started') {
                $hasStartedBoiler = $true
                if ($when -and (-not $startedUtc -or $when -gt $startedUtc)) { $startedUtc = $when }
            }
            elseif ($kind -eq 'finished') {
                $hasFinishedBoiler = $true
                if ($when -and (-not $finishedBoilerUtc -or $when -gt $finishedBoilerUtc)) { $finishedBoilerUtc = $when }
            }

            foreach ($row in @(Get-CodeAntReviewStatusTableRowsFromContent -Content $body -FallbackUtc $when)) {
                if (-not $row.StartedUtc -and $when) { $row.StartedUtc = $when }
                if ($row.IsFinished -and -not $row.FinishedUtc -and $when) { $row.FinishedUtc = $when }
                if ($row.IsRunning) {
                    $anyRunning = $true
                    if (Test-CodeAntReviewShaPrefixMatch -Left $row.Commit -Right $Sha) {
                        $runningForTip = $true
                    }
                }
                if ($row.IsFinished) {
                    $latestFinished = Select-CodeAntReviewLaterFinishedRow -Current $latestFinished -Candidate $row
                    if (Test-CodeAntReviewShaPrefixMatch -Left $row.Commit -Right $Sha) {
                        $tipFinished = Select-CodeAntReviewLaterFinishedRow -Current $tipFinished -Candidate $row
                    }
                }
            }
        }
    }

    $startedAfterTipFinish = $false
    if ($hasStartedBoiler -and $startedUtc) {
        if ($tipFinished) {
            if ($tipFinished.FinishedUtc -and $startedUtc -gt $tipFinished.FinishedUtc) {
                $laterFinish = $null
                if ($latestFinished -and $latestFinished.FinishedUtc -and $latestFinished.FinishedUtc -gt $tipFinished.FinishedUtc) {
                    $laterFinish = $latestFinished.FinishedUtc
                }
                if (-not $laterFinish -or $startedUtc -gt $laterFinish) {
                    $startedAfterTipFinish = $true
                }
            }
            elseif (-not $tipFinished.FinishedUtc) {
                $startedAfterTipFinish = $true
            }
        }
        else {
            $startCutoff = $null
            if ($latestFinished) {
                $startCutoff = $latestFinished.FinishedUtc
                if (-not $startCutoff) { $startCutoff = $latestFinished.StartedUtc }
            }
            if ($startCutoff) {
                if ($startedUtc -gt $startCutoff) { $startedAfterTipFinish = $true }
            }
            else {
                $startedAfterTipFinish = $true
            }
        }
        if ($startedAfterTipFinish -and $ShaCommittedUtc -and $startedUtc -lt $ShaCommittedUtc) {
            $startedAfterTipFinish = $false
        }
    }

    $finishStamp = $null
    $cutoffRow = $tipFinished
    if (-not $cutoffRow) { $cutoffRow = $latestFinished }
    if ($cutoffRow) {
        $finishStamp = $cutoffRow.FinishedUtc
        if (-not $finishStamp) { $finishStamp = $cutoffRow.StartedUtc }
    }
    $hasActiveTrigger = $false
    $hasRecentTrigger = $false
    if ($latestActiveTriggerWhen) {
        $activeOk = $true
        if ($finishStamp -and $latestActiveTriggerWhen -le $finishStamp) { $activeOk = $false }
        if ($activeOk -and $ShaCommittedUtc -and $latestActiveTriggerWhen -lt $ShaCommittedUtc) { $activeOk = $false }
        if ($activeOk) { $hasActiveTrigger = $true }
    }
    if ($latestTriggerWhen -and $latestTriggerWhen -gt $recentCutoff) {
        $recentOk = $true
        if ($finishStamp -and $latestTriggerWhen -le $finishStamp) { $recentOk = $false }
        if ($recentOk -and $ShaCommittedUtc -and $latestTriggerWhen -lt $ShaCommittedUtc) { $recentOk = $false }
        if ($recentOk) { $hasRecentTrigger = $true }
    }

    return [pscustomobject]@{
        TipFinished           = $tipFinished
        LatestFinished        = $latestFinished
        RunningForTip         = $runningForTip
        AnyRunning            = $anyRunning
        HasStartedBoiler      = $hasStartedBoiler
        HasFinishedBoiler     = $hasFinishedBoiler
        StartedUtc            = $startedUtc
        FinishedBoilerUtc     = $finishedBoilerUtc
        HasActiveTrigger      = $hasActiveTrigger
        HasRecentTrigger      = $hasRecentTrigger
        StartedAfterTipFinish = $startedAfterTipFinish
    }
}

function New-CodeAntReviewStateObject {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('none', 'in_flight', 'finished_this_sha', 'finished_stale_sha')]
        [string]$State,

        [Parameter(Mandatory = $true)]
        [string]$TipSha,

        $ReviewedSha = $null,
        $StartedUtc = $null,
        $FinishedUtc = $null
    )

    return [pscustomobject]@{
        state       = $State
        tipSha      = $TipSha
        reviewedSha = $ReviewedSha
        startedUtc  = $StartedUtc
        finishedUtc = $FinishedUtc
    }
}

function Get-CodeAntReviewState {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [string]$Sha,

        $Threads = $null,
        [string]$WorkspaceRoot = '',
        [datetime]$ShaCommittedUtc,
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $threadList = Get-CodeAntReviewThreadsOrFetch -PullRequestId $PullRequestId -Threads $Threads `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl

    $committedUtc = $null
    if ($PSBoundParameters.ContainsKey('ShaCommittedUtc')) {
        $committedUtc = $ShaCommittedUtc.ToUniversalTime()
    }
    else {
        $committedUtc = Get-CodeAntReviewShaCommittedUtc -Sha $Sha -WorkspaceRoot $WorkspaceRoot
    }
    $evidence = Get-CodeAntReviewEvidence -Threads $threadList -Sha $Sha -ShaCommittedUtc $committedUtc
    $requestedForTip = [bool](
        $evidence.RunningForTip -or
        $evidence.HasActiveTrigger -or
        $evidence.HasRecentTrigger -or
        $evidence.StartedAfterTipFinish
    )

    if ($requestedForTip) {
        $started = $evidence.StartedUtc
        if (-not $started -and $evidence.LatestFinished) { $started = $evidence.LatestFinished.StartedUtc }
        return New-CodeAntReviewStateObject -State 'in_flight' -TipSha $Sha `
            -ReviewedSha $(if ($evidence.LatestFinished) { $evidence.LatestFinished.Commit } else { $null }) `
            -StartedUtc $started `
            -FinishedUtc $null
    }
    if ($evidence.TipFinished) {
        return New-CodeAntReviewStateObject -State 'finished_this_sha' -TipSha $Sha `
            -ReviewedSha $evidence.TipFinished.Commit `
            -StartedUtc $evidence.TipFinished.StartedUtc `
            -FinishedUtc $evidence.TipFinished.FinishedUtc
    }
    if ($evidence.LatestFinished -or $evidence.HasFinishedBoiler) {
        $reviewed = $null
        $started = $evidence.StartedUtc
        $finished = $evidence.FinishedBoilerUtc
        if ($evidence.LatestFinished) {
            $reviewed = $evidence.LatestFinished.Commit
            if ($evidence.LatestFinished.StartedUtc) { $started = $evidence.LatestFinished.StartedUtc }
            if ($evidence.LatestFinished.FinishedUtc) { $finished = $evidence.LatestFinished.FinishedUtc }
        }
        return New-CodeAntReviewStateObject -State 'finished_stale_sha' -TipSha $Sha `
            -ReviewedSha $reviewed -StartedUtc $started -FinishedUtc $finished
    }
    if ($evidence.HasStartedBoiler -or $evidence.RunningForTip) {
        return New-CodeAntReviewStateObject -State 'in_flight' -TipSha $Sha `
            -ReviewedSha $null -StartedUtc $evidence.StartedUtc -FinishedUtc $null
    }
    return New-CodeAntReviewStateObject -State 'none' -TipSha $Sha
}

function Get-CodeAntReviewFindings {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        $Threads = $null,
        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $threadList = Get-CodeAntReviewThreadsOrFetch -PullRequestId $PullRequestId -Threads $Threads `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    return @(Get-CodeAntFileFindingsFromThreads -Threads $threadList -ActiveOnly)
}

function Request-CodeAntReview {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    Import-CodeAntAdoCore | Out-Null
    return New-AdoCorePullRequestThread -PullRequestId $PullRequestId `
        -Content (Get-CodeAntReviewRequestContent) `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
}

function Complete-CodeAntReviewFinding {
    param(
        [Parameter(Mandatory = $true)]
        $Finding,

        [Parameter(Mandatory = $true)]
        [ValidateSet('fixed', 'dismissed')]
        [string]$Disposition,

        [Parameter(Mandatory = $true)]
        [string]$Reply,

        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $threadId = $null
    if (Test-PsObjectHasProperty -Object $Finding -Name 'ThreadId') {
        $threadId = $Finding.ThreadId
    }
    elseif (Test-PsObjectHasProperty -Object $Finding -Name 'Id') {
        $threadId = $Finding.Id
    }
    if ($null -eq $threadId -or [string]::IsNullOrWhiteSpace([string]$threadId)) {
        throw 'Finding is missing ThreadId / Id.'
    }

    $parentCommentId = $null
    if (Test-PsObjectHasProperty -Object $Finding -Name 'ParentCommentId') {
        $parentCommentId = $Finding.ParentCommentId
    }
    if ($null -eq $parentCommentId -or [string]::IsNullOrWhiteSpace([string]$parentCommentId)) {
        throw 'Finding is missing ParentCommentId.'
    }

    $status = Resolve-CodeAntReviewCompleteThreadStatus -Disposition $Disposition
    $Reply = $Reply -creplace '(\\\\n|\\n|`n)', [Environment]::NewLine
    $oneThread = Get-CodeAntReviewThreadById -PullRequestId $PullRequestId -ThreadId $threadId `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    $alreadyPosted = Test-CodeAntReviewReplyAlreadyPosted -Threads @($oneThread) `
        -ThreadId $threadId -Reply $Reply

    $threadIdInt = ConvertTo-CodeAntReviewThreadId -ThreadId $threadId
    Import-CodeAntAdoCore | Out-Null
    $posted = $null
    if (-not $alreadyPosted) {
        $posted = Invoke-CodeAntReviewWriteComment -Write {
            Add-AdoCorePullRequestThreadComment -PullRequestId $PullRequestId `
                -ThreadId $threadIdInt -ParentCommentId ([int]$parentCommentId) -Content $Reply `
                -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
                -Repository $Repository -ServerUrl $ServerUrl
        } -PostedOnThread {
            $recheck = Get-CodeAntReviewThreadById -PullRequestId $PullRequestId -ThreadId $threadIdInt `
                -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
                -Repository $Repository -ServerUrl $ServerUrl
            Test-CodeAntReviewReplyAlreadyPosted -Threads @($recheck) `
                -ThreadId $threadIdInt -Reply $Reply
        }
    }
    Set-AdoCorePullRequestThreadStatus -PullRequestId $PullRequestId `
        -ThreadId $threadIdInt -Status $status `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl

    return [pscustomobject]@{
        PullRequestId = $PullRequestId
        ThreadId      = [int]$threadId
        CommentId     = $(if ($posted) { $posted.CommentId } else { $null })
        Disposition   = $Disposition
        Status        = $status
    }
}

function Clear-CodeAntReviewRequests {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        $Threads,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $clearParams = @{
        PullRequestId = $PullRequestId
        Collection    = $Collection
        Project       = $Project
        Repository    = $Repository
        ServerUrl     = $ServerUrl
        WorkspaceRoot = $WorkspaceRoot
    }
    if ($PSBoundParameters.ContainsKey('Threads')) {
        $clearParams.Threads = $Threads
    }
    return Clear-CodeAntRetriggerThreads @clearParams
}
