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

    # Live timestamps separate date and time with a middle dot (U+00B7), built
    # here via [char] so this file stays pure ASCII: Windows PowerShell 5.1
    # decodes UTF-8-no-BOM source as ANSI, so a literal dot in the format
    # strings becomes mojibake and never matches properly decoded ADO text -
    # the row date then silently falls back to the comment's publish date.
    $trimmed = $trimmed.Replace([string][char]0xC2, '').Replace([string][char]0xB7, ' ')
    $trimmed = ($trimmed -replace '\s+', ' ').Trim()

    foreach ($format in @('MMM d, yyyy HH:mm', 'MMM dd, yyyy HH:mm', 'MMM d, yyyy H:mm', 'MMM dd, yyyy H:mm')) {
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

function ConvertTo-CodeAntCanonicalSecurityFinding {
    <#
    .SYNOPSIS
      Project one raw Quality Gate security row (source/gate/path/line/type/...)
      into the canonical finding shape (Id/Number/Path/Line/Comment + Source).
    .DESCRIPTION
      This is the single normalisation point for security findings. The
      synthesised Comment carries gate, type, line and confidence (CodeAnt's
      own prompt leads with the line; clearance fingerprints are Path + first
      Comment line, so the line must be in the Comment to keep two same-type
      secrets in one file distinct). ThreadId/ParentCommentId stay null: a
      security row owns no ADO thread (see Complete-CodeAntReviewMetaFindings).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $SecurityFinding,

        [Parameter(Mandatory = $true)]
        [int]$Index
    )

    $gate = [string]$SecurityFinding.gate
    if ([string]::IsNullOrWhiteSpace($gate)) { $gate = 'Quality Gate' }
    $type = [string]$SecurityFinding.type
    $confidence = [string]$SecurityFinding.confidence
    $rawPath = ([string]$SecurityFinding.path).Trim()
    $lineText = ''
    if ($null -ne $SecurityFinding.line) { $lineText = [string]$SecurityFinding.line }

    if ([string]::IsNullOrWhiteSpace($rawPath)) {
        $comment = "$gate quality gate failed; no file/line detail was posted in ADO."
        $path = ''
    }
    else {
        $what = $type
        if ([string]::IsNullOrWhiteSpace($what) -or $what -eq 'Quality gate failed') { $what = 'a security issue' }
        $comment = "$gate quality gate reported $what"
        if (-not [string]::IsNullOrWhiteSpace($lineText)) { $comment += " at line $lineText" }
        if (-not [string]::IsNullOrWhiteSpace($confidence)) { $comment += " ($confidence confidence)" }
        $comment += '.'
        $path = '/' + $rawPath.TrimStart('/')
    }

    return [pscustomobject]@{
        Id              = "qualitygate-$($SecurityFinding.metaThreadId)-$Index"
        Number          = $Index
        Path            = $path
        Line            = $lineText
        Comment         = $comment
        ThreadId        = $null
        ParentCommentId = $null
        ThreadStatus    = 'active'
        Source          = 'qualityGate'
        Gate            = $gate
        Type            = $type
        Confidence      = $confidence
        Status          = [string]$SecurityFinding.status
        ResultsUrl      = [string]$SecurityFinding.resultsUrl
        MetaThreadId    = $SecurityFinding.metaThreadId
    }
}

function Get-CodeAntReviewFindings {
    <#
    .SYNOPSIS
      All active findings in one canonical list: file threads, Nitpicks, security.
    .DESCRIPTION
      One consolidated port for every consumer. File findings keep their ADO
      thread ids; Nitpicks (Source = 'nitpick') and Quality Gate security rows
      (Source = 'qualityGate') are normalised into the same Id/Number/Path/
      Line/Comment shape, renumbered as one list, and distinguished only by
      Source (+ MetaThreadId). Consumers that count findings (quiet, act)
      therefore need no separate security count. Completion still branches on
      Source - see Complete-CodeAntReviewMetaFindings. Pass -FileOnly for the
      legacy file-threads-only list.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        $Threads = $null,
        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = '',
        [switch]$FileOnly
    )

    $threadList = Get-CodeAntReviewThreadsOrFetch -PullRequestId $PullRequestId -Threads $Threads `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    $findings = @(Get-CodeAntFileFindingsFromThreads -Threads $threadList -ActiveOnly)
    if (-not $FileOnly) {
        $findings = @($findings) + @(Get-CodeAntNitpickFindingsFromThreads -Threads $threadList -ActiveOnly)
        $securityIndex = 0
        foreach ($sec in @(Get-CodeAntSecurityFindingsFromThreads -Threads $threadList)) {
            $securityIndex++
            $findings = @($findings) + @(ConvertTo-CodeAntCanonicalSecurityFinding -SecurityFinding $sec -Index $securityIndex)
        }
        $number = 0
        foreach ($finding in $findings) {
            $number++
            $finding.Number = $number
        }
    }
    return @($findings)
}

function Get-CodeAntReviewQualityGate {
    <#
    .SYNOPSIS
      Parsed Quality Gate meta thread (status/gates/resultsUrl), or $null.
    #>
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
    return Get-CodeAntQualityGateFromThreads -Threads $threadList
}

function Get-CodeAntReviewSecurityFindings {
    <#
    .SYNOPSIS
      Quality Gate security findings (separate from comment findings; never
      folded into a comment-finding count). Empty when the gate passes/absent.
    #>
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
    return @(Get-CodeAntSecurityFindingsFromThreads -Threads $threadList)
}

function Get-CodeAntMetaThreadIdFromFinding {
    param($Finding)

    foreach ($name in @('metaThreadId', 'MetaThreadId', 'ThreadId', 'Id')) {
        if (Test-PsObjectHasProperty -Object $Finding -Name $name) {
            $value = $Finding.$name
            if ("$value" -match '^\d+$') { return [int]$value }
            if ("$value" -match '^(\d+)-\d+$') { return [int]$Matches[1] }
        }
    }
    return $null
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

    if (Test-IsCodeAntMetaSourcedFinding -Finding $Finding) {
        throw 'Meta-sourced findings (Quality Gate security / Nitpicks) have no per-finding ADO thread to complete. Use Complete-CodeAntReviewMetaFindings: fixed is proven by a re-review clearing the gate/meta comment; dismissed needs one summary reply on the shared meta thread.'
    }

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

function Complete-CodeAntReviewMetaFindings {
    <#
    .SYNOPSIS
      Complete meta-sourced findings (Quality Gate security rows / Nitpicks) as a group.
    .DESCRIPTION
      Disposition model for findings that live inside a shared meta thread:

      - fixed: posts nothing and closes nothing. There is no per-finding ADO
        thread to Resolve, and closing the shared meta thread would hide the
        evidence for its other findings. Proof of clearance is a re-review:
        re-fetch shows the gate passed (security findings == 0) or the nitpick
        gone. Returns Status = 'AwaitingReReview'.
      - dismissed: posts exactly ONE summary -Reply on the shared meta thread
        (callers list every dismissed path:line + reason in that one reply),
        then marks the meta thread Closed. Never one reply per finding, and
        never WontFix per finding (the thread is a container, not a finding).

      All -Findings must be meta-sourced and share one metaThreadId.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Findings,

        [Parameter(Mandatory = $true)]
        [ValidateSet('fixed', 'dismissed')]
        [string]$Disposition,

        [string]$Reply = '',

        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $list = @($Findings | Where-Object { $null -ne $_ })
    if ($list.Count -eq 0) {
        throw 'Complete-CodeAntReviewMetaFindings requires at least one finding.'
    }
    $metaThreadIds = @()
    foreach ($finding in $list) {
        if (-not (Test-IsCodeAntMetaSourcedFinding -Finding $finding)) {
            throw 'Complete-CodeAntReviewMetaFindings only accepts meta-sourced findings (Quality Gate security / Nitpicks). Use Complete-CodeAntReviewFinding for file findings.'
        }
        $metaThreadIds += Get-CodeAntMetaThreadIdFromFinding -Finding $finding
    }
    $uniqueIds = @($metaThreadIds | Where-Object { $null -ne $_ } | Select-Object -Unique)
    if ($uniqueIds.Count -ne 1) {
        throw 'Meta findings must share exactly one metaThreadId.'
    }
    $metaThreadId = [int]$uniqueIds[0]

    if ($Disposition -eq 'fixed') {
        return [pscustomobject]@{
            PullRequestId = $PullRequestId
            MetaThreadId  = $metaThreadId
            FindingCount  = $list.Count
            Disposition   = $Disposition
            Status        = 'AwaitingReReview'
            CommentId     = $null
        }
    }

    if ([string]::IsNullOrWhiteSpace($Reply)) {
        throw 'Dismissed meta findings require a single summary -Reply covering every dismissed finding in the group.'
    }
    $Reply = $Reply -creplace '(\\\\n|\\n|`n)', [Environment]::NewLine

    $oneThread = Get-CodeAntReviewThreadById -PullRequestId $PullRequestId -ThreadId $metaThreadId `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    $parentCommentId = $null
    foreach ($comment in (Get-AdoThreadComments -Thread $oneThread)) {
        if ($null -ne (Get-PsObjectPropertyValue -Object $comment -Name 'id' -Default $null)) {
            $parentCommentId = [int]$comment.id
            break
        }
    }
    if ($null -eq $parentCommentId) {
        throw "Meta thread $metaThreadId has no comment to reply under."
    }
    $alreadyPosted = Test-CodeAntReviewReplyAlreadyPosted -Threads @($oneThread) `
        -ThreadId $metaThreadId -Reply $Reply

    Import-CodeAntAdoCore | Out-Null
    $posted = $null
    if (-not $alreadyPosted) {
        $posted = Invoke-CodeAntReviewWriteComment -Write {
            Add-AdoCorePullRequestThreadComment -PullRequestId $PullRequestId `
                -ThreadId $metaThreadId -ParentCommentId $parentCommentId -Content $Reply `
                -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
                -Repository $Repository -ServerUrl $ServerUrl
        } -PostedOnThread {
            $recheck = Get-CodeAntReviewThreadById -PullRequestId $PullRequestId -ThreadId $metaThreadId `
                -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
                -Repository $Repository -ServerUrl $ServerUrl
            Test-CodeAntReviewReplyAlreadyPosted -Threads @($recheck) `
                -ThreadId $metaThreadId -Reply $Reply
        }
    }
    Set-AdoCorePullRequestThreadStatus -PullRequestId $PullRequestId `
        -ThreadId $metaThreadId -Status Closed `
        -WorkspaceRoot $WorkspaceRoot -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl

    return [pscustomobject]@{
        PullRequestId = $PullRequestId
        MetaThreadId  = $metaThreadId
        FindingCount  = $list.Count
        Disposition   = $Disposition
        Status        = 'Closed'
        CommentId     = $(if ($posted) { $posted.CommentId } else { $null })
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
    else {
        # One snapshot for both clears - avoids a second fetch that can throw after kicks were fixed.
        $clearParams.Threads = Get-CodeAntPullRequestThreads -PullRequestId $PullRequestId `
            -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl `
            -WorkspaceRoot $WorkspaceRoot
    }

    $kick = Clear-CodeAntRetriggerThreads @clearParams
    $meta = Clear-CodeAntMetaThreads @clearParams

    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($id in @($kick.ThreadIds)) {
        if ($null -ne $id) { [void]$ids.Add([int]$id) }
    }
    foreach ($id in @($meta.ThreadIds)) {
        if ($null -ne $id) { [void]$ids.Add([int]$id) }
    }

    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($w in @($kick.Warnings)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$w)) { [void]$warnings.Add([string]$w) }
    }
    foreach ($w in @($meta.Warnings)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$w)) { [void]$warnings.Add([string]$w) }
    }

    return [pscustomobject]@{
        PullRequestId = $PullRequestId
        ResolvedCount = $ids.Count
        ThreadIds     = @($ids.ToArray())
        Warnings      = @($warnings.ToArray())
    }
}
