#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-GitWorkspaceRoot {
    $current = (Get-Location).Path
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    return (Get-Location).Path
}

function Get-AdoDefaultsFromGitRemote {
    param([string]$WorkspaceRoot)

    # A worktree uses a .git file; a standard clone uses a .git directory.
    $gitMetadataPath = Join-Path $WorkspaceRoot '.git'
    if (-not (Test-Path -LiteralPath $gitMetadataPath)) {
        throw "WorkspaceRoot is not a Git repository: $WorkspaceRoot"
    }

    $remote = git -C $WorkspaceRoot config --get remote.origin.url 2>$null
    if (-not $remote) {
        throw 'Could not read remote.origin.url. Pass -ServerUrl, -Collection, and -Project explicitly.'
    }

    if ($remote -match '^(https?://[^/]+)/tfs/([^/]+)/([^/]+)/_git/([^/?#]+)') {
        return @{
            ServerUrl  = $Matches[1]
            Collection = $Matches[2]
            Project    = $Matches[3]
            Repository = $Matches[4]
        }
    }

    throw "Unsupported remote.origin.url for ADO: $remote"
}

function Normalize-AdoServerUrl {
    param([string]$ServerUrl)

    if ([string]::IsNullOrWhiteSpace($ServerUrl)) { return $ServerUrl }
    $normalized = $ServerUrl.TrimEnd('/')
    if ($normalized -match '/tfs$') {
        return $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized
}

# Hosts allowed for UseDefaultCredentials calls (integrated auth must not leave these).
$script:TrustedAdoServerHosts = @(
    'tfs.sicon.co.uk'
)

function Assert-TrustedAdoServerUrl {
    <#
    .SYNOPSIS
      Require HTTPS and an allowlisted host before sending Windows credentials.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerUrl
    )

    $normalized = Normalize-AdoServerUrl -ServerUrl $ServerUrl
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'ADO ServerUrl is empty.'
    }

    $uri = $null
    try {
        $uri = [Uri]$normalized
    }
    catch {
        throw "ADO ServerUrl is not a valid absolute URI: $ServerUrl"
    }

    if (-not $uri.IsAbsoluteUri) {
        throw "ADO ServerUrl must be an absolute URI: $ServerUrl"
    }
    if ($uri.Scheme -ne 'https') {
        throw "ADO ServerUrl must use HTTPS (got '$($uri.Scheme)'): $ServerUrl"
    }
    if ($script:TrustedAdoServerHosts -notcontains $uri.Host) {
        $allowed = $script:TrustedAdoServerHosts -join ', '
        throw "ADO ServerUrl host '$($uri.Host)' is not trusted. Allowed: $allowed"
    }
}

function Get-AdoGitApiBase {
    param(
        [string]$ServerUrl,
        [string]$Collection,
        [string]$Project,
        [string]$Repository
    )
    $base = Normalize-AdoServerUrl -ServerUrl $ServerUrl
    return "$base/tfs/$Collection/$Project/_apis/git/repositories/$Repository"
}

$script:CodeAntAuthorName = 'Code Ant'
$script:CodeAntRetriggerCommentDefault = '@codeant-ai: review'
$script:CodeAntRetriggerCommentVariants = @(
    '@codeant-ai: review'
    '#codeant-ai: review'
)
# Boilerplate patterns - skipped when extracting file findings via Get-FirstCodeAntComment.
$script:CodeAntStartedPatterns = @(
    'CodeAnt AI is reviewing your PR'
    'CodeAnt AI is reviewing your code'
    'CodeAnt AI is running the review'
    'CodeAnt AI is running Incremental review'
)
$script:CodeAntFinishedPatterns = @(
    'CodeAnt AI finished reviewing your PR'
    'CodeAnt AI finished running the review'
    'CodeAnt AI Incremental review completed'
)

function Test-IsCodeAntReviewBoilerplate {
    param([string]$Content)

    if ($null -eq $Content) { return $null }
    $trimmed = $Content.Trim()
    foreach ($pattern in $script:CodeAntStartedPatterns) {
        $escaped = [regex]::Escape($pattern)
        if ($trimmed -match "^$escaped\.?\s*$") { return 'started' }
    }
    foreach ($pattern in $script:CodeAntFinishedPatterns) {
        $escaped = [regex]::Escape($pattern)
        if ($trimmed -match "^$escaped\.?\s*$") { return 'finished' }
    }
    return $null
}

function Get-CodeAntRetriggerCommentMatchers {
    param([string]$Comment = '')

    if (-not [string]::IsNullOrWhiteSpace($Comment)) {
        return @($Comment.Trim())
    }
    return @($script:CodeAntRetriggerCommentVariants)
}

function Test-IsCodeAntRetriggerCommentBody {
    param(
        [string]$Body,
        [string]$Comment = ''
    )

    if ($null -eq $Body) { return $false }
    $trimmed = $Body.Trim()
    foreach ($expected in (Get-CodeAntRetriggerCommentMatchers -Comment $Comment)) {
        if ($trimmed -ieq $expected) { return $true }
    }
    return $false
}

function Test-HasActiveCodeAntRetriggerThread {
    param(
        $Threads,
        [string]$Comment = ''
    )

    if (-not $Threads) { return $false }
    foreach ($thread in $Threads) {
        $threadContext = Get-PsObjectPropertyValue -Object $thread -Name 'threadContext' -Default $null
        $filePath = ''
        if ($null -ne $threadContext) {
            $filePath = [string](Get-PsObjectPropertyValue -Object $threadContext -Name 'filePath' -Default '')
        }
        if (-not [string]::IsNullOrWhiteSpace($filePath)) { continue }
        $status = 'active'
        if ($thread.PSObject.Properties.Name -contains 'status' -and $null -ne $thread.status) {
            $status = [string]$thread.status
        }
        if (-not (Test-IsActiveAdoThread -Status $status)) { continue }
        if (-not (Test-PsObjectHasProperty -Object $thread -Name 'comments')) { continue }
        $threadComments = Get-AdoThreadComments -Thread $thread
        if ($threadComments.Count -eq 0) { continue }
        foreach ($threadComment in $threadComments) {
            $body = Get-AdoCommentContentText -Comment $threadComment
            if (Test-IsCodeAntRetriggerCommentBody -Body $body -Comment $Comment) { return $true }
        }
    }
    return $false
}

function Test-HasRecentCodeAntRetriggerThread {
    param(
        $Threads,
        [int]$WithinMinutes = 10,
        [string]$Comment = ''
    )

    if (-not $Threads) { return $false }
    $cutoff = (Get-Date).ToUniversalTime().AddMinutes(-1 * $WithinMinutes)
    foreach ($thread in $Threads) {
        $threadContext = Get-PsObjectPropertyValue -Object $thread -Name 'threadContext' -Default $null
        $filePath = ''
        if ($null -ne $threadContext) {
            $filePath = [string](Get-PsObjectPropertyValue -Object $threadContext -Name 'filePath' -Default '')
        }
        if (-not [string]::IsNullOrWhiteSpace($filePath)) { continue }
        if (-not (Test-PsObjectHasProperty -Object $thread -Name 'comments')) { continue }
        $threadComments = Get-AdoThreadComments -Thread $thread
        if ($threadComments.Count -eq 0) { continue }
        foreach ($threadComment in $threadComments) {
            $body = Get-AdoCommentContentText -Comment $threadComment
            if (-not (Test-IsCodeAntRetriggerCommentBody -Body $body -Comment $Comment)) { continue }
            $when = $null
            if ($threadComment.PSObject.Properties.Name -contains 'publishedDate') { $when = $threadComment.publishedDate }
            if (-not $when -and ($threadComment.PSObject.Properties.Name -contains 'lastUpdatedDate')) {
                $when = $threadComment.lastUpdatedDate
            }
            if ($when -and ([datetime]$when).ToUniversalTime() -gt $cutoff) { return $true }
        }
    }
    return $false
}

function Set-CodeAntAdoThreadStatus {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [int]$ThreadId,

        [ValidateSet('Active', 'Fixed', 'WontFix', 'Closed', 'ByDesign')]
        [string]$Status = 'Fixed',

        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $statusMap = @{
        Active   = 1
        Fixed    = 2
        WontFix  = 3
        Closed   = 4
        ByDesign = 5
    }

    $endpoints = Resolve-AdoCodeAntTriageEndpoints -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    $patchUri = "$($endpoints.ApiBase)/pullRequests/$PullRequestId/threads/$ThreadId`?api-version=7.0"
    $patchBody = @{ status = $statusMap[$Status] } | ConvertTo-Json
    Invoke-RestMethod -Uri $patchUri -Method Patch -Body $patchBody `
        -ContentType 'application/json' -UseDefaultCredentials | Out-Null
}

function Get-CodeAntAdoContinuationToken {
    param(
        [Parameter(Mandatory = $true)]
        $Response
    )

    $headerValue = $Response.Headers['x-ms-continuationtoken']
    if (-not $headerValue) { return $null }
    $token = if ($headerValue -is [System.Array]) { [string]$headerValue[0] } else { [string]$headerValue }
    if ([string]::IsNullOrWhiteSpace($token)) { return $null }
    return $token
}

function Get-CodeAntPullRequestThreads {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $endpoints = Resolve-AdoCodeAntTriageEndpoints -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    $baseUri = "$($endpoints.ApiBase)/pullRequests/$PullRequestId/threads?api-version=7.0"
    $threads = New-Object 'System.Collections.Generic.List[object]'
    $continuationToken = $null
    do {
        $uri = $baseUri
        if ($continuationToken) {
            $uri = "$uri&continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        $response = Invoke-WebRequest -Uri $uri -Method Get -UseDefaultCredentials -UseBasicParsing
        $payload = $response.Content | ConvertFrom-Json
        if ($payload.PSObject.Properties.Name -contains 'value' -and $payload.value) {
            foreach ($item in @($payload.value)) {
                [void]$threads.Add($item)
            }
        }

        $continuationToken = Get-CodeAntAdoContinuationToken -Response $response
    } while ($continuationToken)

    return @($threads.ToArray())
}

function Test-IsCodeAntRetriggerThread {
    param(
        $Thread,
        [string]$Comment = ''
    )

    if (-not $Thread) { return $false }
    $threadContext = Get-PsObjectPropertyValue -Object $Thread -Name 'threadContext' -Default $null
    $filePath = ''
    if ($null -ne $threadContext) {
        $filePath = [string](Get-PsObjectPropertyValue -Object $threadContext -Name 'filePath' -Default '')
    }
    if (-not [string]::IsNullOrWhiteSpace($filePath)) { return $false }

    $status = 'active'
    if ($Thread.PSObject.Properties.Name -contains 'status' -and $null -ne $Thread.status) {
        $status = [string]$Thread.status
    }
    if (-not (Test-IsActiveAdoThread -Status $status)) { return $false }
    if (-not (Test-PsObjectHasProperty -Object $Thread -Name 'comments')) { return $false }

    foreach ($threadComment in (Get-AdoThreadComments -Thread $Thread)) {
        $body = Get-AdoCommentContentText -Comment $threadComment
        if (Test-IsCodeAntRetriggerCommentBody -Body $body -Comment $Comment) { return $true }
    }
    return $false
}

function Clear-CodeAntRetriggerThreads {
    <#
    .SYNOPSIS
      Marks active CodeAnt trigger threads (@/# codeant-ai: review) Fixed so they do not block ADO autocomplete.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        $Threads,

        [string]$Comment = '',

        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if (-not $Threads) {
        $Threads = Get-CodeAntPullRequestThreads -PullRequestId $PullRequestId `
            -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    }

    $resolved = New-Object System.Collections.Generic.List[int]
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($thread in @($Threads)) {
        if (-not (Test-IsCodeAntRetriggerThread -Thread $thread -Comment $Comment)) { continue }
        $threadId = [int]$thread.id
        try {
            Set-CodeAntAdoThreadStatus -PullRequestId $PullRequestId -ThreadId $threadId -Status Fixed `
                -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
            $resolved.Add($threadId)
        }
        catch {
            [void]$warnings.Add("Thread $threadId`: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        PullRequestId = $PullRequestId
        ResolvedCount = $resolved.Count
        ThreadIds     = @($resolved.ToArray())
        Warnings      = @($warnings.ToArray())
    }
}

function Get-CodeAntFileFindingsFromThreads {
    param(
        $Threads,
        [switch]$ActiveOnly
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $index = 0

    foreach ($thread in $Threads) {
        $comment = Get-FirstCodeAntComment -Thread $thread
        if (-not $comment) { continue }

        $path = ''
        $threadContext = Get-PsObjectPropertyValue -Object $thread -Name 'threadContext' -Default $null
        if ($null -ne $threadContext) {
            $path = [string](Get-PsObjectPropertyValue -Object $threadContext -Name 'filePath' -Default '')
        }
        if (-not $path) { continue }

        $status = 'active'
        if ($thread.PSObject.Properties.Name -contains 'status' -and $null -ne $thread.status) {
            $status = [string]$thread.status
        }
        if ($ActiveOnly -and -not (Test-IsActiveAdoThread -Status $status)) { continue }

        $index++
        [void]$findings.Add([pscustomobject]@{
                Number          = $index
                Path            = $path
                Line            = Get-AdoThreadLineRange -ThreadContext $threadContext
                Comment         = (Get-AdoCommentContentText -Comment $comment).Trim()
                ThreadId        = $thread.id
                ParentCommentId = $comment.id
                ThreadStatus    = $status
            })
    }

    return $findings
}

function Get-CodeAntFindingCounts {
    param(
        $Threads = $null,

        $Findings = $null
    )

    if ($null -eq $Findings) {
        if ($null -eq $Threads) {
            throw 'Get-CodeAntFindingCounts requires -Threads or -Findings.'
        }
        $Findings = Get-CodeAntFileFindingsFromThreads -Threads $Threads
    }

    $active = 0
    $fixed = 0
    foreach ($finding in @($Findings)) {
        if (Test-IsActiveAdoThread -Status $finding.ThreadStatus) {
            $active++
        }
        else {
            $fixed++
        }
    }

    return [pscustomobject]@{
        active = $active
        fixed  = $fixed
        total  = @($Findings).Count
    }
}

function Resolve-AdoCodeAntTriageEndpoints {
    param(
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if (-not $ServerUrl -or -not $Collection -or -not $Project -or -not $Repository) {
        $root = Get-GitWorkspaceRoot
        $defaults = Get-AdoDefaultsFromGitRemote -WorkspaceRoot $root
        if (-not $ServerUrl) { $ServerUrl = $defaults.ServerUrl }
        if (-not $Collection) { $Collection = $defaults.Collection }
        if (-not $Project) { $Project = $defaults.Project }
        if (-not $Repository) { $Repository = $defaults.Repository }
    }

    $ServerUrl = Normalize-AdoServerUrl -ServerUrl $ServerUrl
    Assert-TrustedAdoServerUrl -ServerUrl $ServerUrl

    return @{
        ServerUrl  = $ServerUrl
        Collection = $Collection
        Project    = $Project
        Repository = $Repository
        ApiBase    = (Get-AdoGitApiBase -ServerUrl $ServerUrl -Collection $Collection -Project $Project -Repository $Repository)
    }
}

function Test-ReviewerProperty {
    param($Object, [string]$Name)
    return $null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)
}

# StrictMode: missing note property ≠ $null — must probe before read.
function Test-PsObjectHasProperty {
    param($Object, [string]$Name)
    return $null -ne $Object -and ($Object.PSObject.Properties.Name -contains $Name)
}

function Get-PsObjectPropertyValue {
    param(
        $Object,
        [string]$Name,
        $Default = $null
    )
    if (-not (Test-PsObjectHasProperty -Object $Object -Name $Name)) {
        return $Default
    }
    $val = $Object.$Name
    if ($null -eq $val) { return $Default }
    return $val
}

function Get-AdoCommentContentText {
    param($Comment)
    $raw = Get-PsObjectPropertyValue -Object $Comment -Name 'content' -Default ''
    if ($null -eq $raw) { return '' }
    return [string]$raw
}

function Get-AdoCommentAuthorDisplayName {
    param($Comment)
    $author = Get-PsObjectPropertyValue -Object $Comment -Name 'author' -Default $null
    if ($null -eq $author) { return '' }
    $name = Get-PsObjectPropertyValue -Object $author -Name 'displayName' -Default ''
    if ($null -eq $name) { return '' }
    return [string]$name
}

function Get-AdoThreadComments {
    param($Thread)
    # Unary comma keeps Object[] intact: PowerShell unwraps single-element (and empty)
    # arrays on return, which breaks .Count under Set-StrictMode.
    $comments = Get-PsObjectPropertyValue -Object $Thread -Name 'comments' -Default @()
    if ($null -eq $comments) {
        return , @()
    }
    return , @($comments)
}

function Test-IsHumanPrReviewer {
    param($Reviewer)
    if (-not $Reviewer) { return $false }
    if (Test-ReviewerProperty $Reviewer 'displayName' -and [string]$Reviewer.displayName -eq $script:CodeAntAuthorName) {
        return $false
    }
    if (Test-ReviewerProperty $Reviewer 'isContainer' -and $Reviewer.isContainer -eq $true) {
        return $false
    }
    if (Test-ReviewerProperty $Reviewer 'displayName') {
        $name = [string]$Reviewer.displayName
        if ($name -match 'Build Service|Service \(|svc\)') { return $false }
    }
    return $true
}

function Get-RequiredReviewerApproved {
    param($Reviewers)
    if (-not $Reviewers) { return $false }
    $required = @(
        $Reviewers | Where-Object {
            (Test-ReviewerProperty $_ 'isRequired') -and $_.isRequired -eq $true
        }
    )
    if ($required.Count -eq 0) {
        return @(
            $Reviewers | Where-Object {
                (Test-ReviewerProperty $_ 'vote') -and $_.vote -eq 10 -and (Test-IsHumanPrReviewer $_)
            }
        ).Count -gt 0
    }
    $approvedCount = @(
        $required | Where-Object {
            (Test-ReviewerProperty $_ 'vote') -and $_.vote -eq 10
        }
    ).Count
    return $required.Count -gt 0 -and $approvedCount -eq $required.Count
}

function Get-AdoThreadLineRange {
    param($ThreadContext)
    if (-not $ThreadContext) { return '' }
    $start = $null
    $end = $null
    if ($ThreadContext.PSObject.Properties.Name -contains 'rightFileStart' -and $ThreadContext.rightFileStart) {
        if ($ThreadContext.rightFileStart.PSObject.Properties.Name -contains 'line') {
            $start = $ThreadContext.rightFileStart.line
        }
    }
    if ($ThreadContext.PSObject.Properties.Name -contains 'rightFileEnd' -and $ThreadContext.rightFileEnd) {
        if ($ThreadContext.rightFileEnd.PSObject.Properties.Name -contains 'line') {
            $end = $ThreadContext.rightFileEnd.line
        }
    }
    if (-not $start) { return '' }
    if (-not $end -or $end -eq $start) { return "$start" }
    return "$start`:$end"
}

function Test-IsActiveAdoThread {
    param($Status)

    if ($null -eq $Status) { return $true }
    $normalized = [string]$Status
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $true }
    if ($normalized -match '^\d+$') { return [int]$normalized -eq 1 }
    return $normalized -ieq 'active' -or $normalized -ieq 'pending'
}

function Get-FirstCodeAntComment {
    param($Thread)
    foreach ($comment in (Get-AdoThreadComments -Thread $Thread)) {
        if ((Get-AdoCommentAuthorDisplayName -Comment $comment) -ne $script:CodeAntAuthorName) { continue }
        $body = Get-AdoCommentContentText -Comment $comment
        if (Test-IsCodeAntReviewBoilerplate -Content $body) { continue }
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        return $comment
    }
    return $null
}

function Get-FirstHumanComment {
    param($Thread)
    foreach ($comment in (Get-AdoThreadComments -Thread $Thread)) {
        if ((Get-AdoCommentAuthorDisplayName -Comment $comment) -eq $script:CodeAntAuthorName) { continue }
        $body = Get-AdoCommentContentText -Comment $comment
        if (Test-IsCodeAntReviewBoilerplate -Content $body) { continue }
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        return $comment
    }
    return $null
}

function Get-HumanPrFindingsFromThreads {
    param(
        $Threads,
        [switch]$ActiveOnly
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $index = 0

    foreach ($thread in $Threads) {
        $comment = Get-FirstHumanComment -Thread $thread
        if (-not $comment) { continue }

        $path = ''
        $threadContext = Get-PsObjectPropertyValue -Object $thread -Name 'threadContext' -Default $null
        if ($null -ne $threadContext) {
            $path = [string](Get-PsObjectPropertyValue -Object $threadContext -Name 'filePath' -Default '')
        }
        if (-not $path) { continue }

        $status = 'active'
        if ($thread.PSObject.Properties.Name -contains 'status' -and $null -ne $thread.status) {
            $status = [string]$thread.status
        }
        if ($ActiveOnly -and -not (Test-IsActiveAdoThread -Status $status)) { continue }

        $index++
        [void]$findings.Add([pscustomobject]@{
                Number          = $index
                Path            = $path
                Line            = Get-AdoThreadLineRange -ThreadContext $threadContext
                Comment         = (Get-AdoCommentContentText -Comment $comment).Trim()
                Author          = Get-AdoCommentAuthorDisplayName -Comment $comment
                ThreadId        = $thread.id
                ParentCommentId = $comment.id
                ThreadStatus    = $status
            })
    }

    return $findings
}

function Split-MarkdownTableRowCells {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line
    )

    $trimmed = $Line.Trim()
    if (-not $trimmed.StartsWith('|')) { return @() }
    $inner = $trimmed.Trim('|')
    $cells = New-Object 'System.Collections.Generic.List[string]'
    $current = New-Object System.Text.StringBuilder
    $escaped = $false

    foreach ($character in $inner.ToCharArray()) {
        if ($escaped) {
            if ($character -ne '|') { [void]$current.Append('\') }
            [void]$current.Append($character)
            $escaped = $false
            continue
        }
        if ($character -eq '\') {
            $escaped = $true
            continue
        }
        if ($character -eq '|') {
            [void]$cells.Add($current.ToString().Trim())
            [void]$current.Clear()
            continue
        }
        [void]$current.Append($character)
    }

    if ($escaped) { [void]$current.Append('\') }
    [void]$cells.Add($current.ToString().Trim())
    return $cells.ToArray()
}

function Get-CodeAntUserAntiPatternRows {
    <#
    .SYNOPSIS
      Parse UAP rows from anti-patterns.user.md. Legacy 7-column rows ⇒ blank Disposition.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Markdown
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $inTable = $false
    $headerCells = @()

    $reader = [System.IO.StringReader]::new($Markdown)
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }

            if ($line -match '^\|\s*ID\s*\|') {
                $headerCells = @(Split-MarkdownTableRowCells -Line $line)
                $inTable = $true
                continue
            }
            if (-not $inTable) { continue }
            if ($line -match '^\|\s*-+') { continue }
            if ($line -notmatch '^\|') {
                if ($rows.Count -gt 0) { break }
                continue
            }

            $cells = @(Split-MarkdownTableRowCells -Line $line)
            if ($cells.Count -lt 7) { continue }
            if ($cells[0] -eq 'ID') { continue }

            # 8-col: ID Scope Repo Pattern Signals FixDirection Disposition EnforcedBy
            # 7-col legacy: ID Scope Repo Pattern Signals FixDirection EnforcedBy (no Disposition)
            $hasDispositionColumn = $headerCells -contains 'Disposition'
            if ($hasDispositionColumn -and $cells.Count -ge 8) {
                $disposition = $cells[6]
                $enforcedBy = $cells[7]
                $fixDirection = $cells[5]
            }
            elseif (-not $hasDispositionColumn -and $cells.Count -ge 7) {
                $disposition = ''
                $enforcedBy = $cells[6]
                $fixDirection = $cells[5]
            }
            elseif ($cells.Count -ge 8) {
                $disposition = $cells[6]
                $enforcedBy = $cells[7]
                $fixDirection = $cells[5]
            }
            else {
                $disposition = ''
                $enforcedBy = $cells[$cells.Count - 1]
                $fixDirection = $cells[5]
            }

            [void]$rows.Add([pscustomobject]@{
                    Id           = $cells[0]
                    Scope        = $cells[1]
                    Repo         = $cells[2]
                    Pattern      = $cells[3]
                    Signals      = $cells[4]
                    FixDirection = $fixDirection
                    Disposition  = $disposition
                    EnforcedBy   = $enforcedBy
                })
        }
    }
    finally {
        $reader.Dispose()
    }

    return $rows
}

function Select-CodeAntUserAntiPatternsByScope {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Rows,
        [Parameter(Mandatory = $true)]
        [string]$RemoteId
    )

    $remote = $RemoteId.Trim()
    return @($Rows | Where-Object {
            $scope = [string]$_.Scope
            if ([string]::IsNullOrWhiteSpace($scope)) { return $true }
            return ($scope -eq '*') -or ($scope.Equals($remote, [System.StringComparison]::OrdinalIgnoreCase))
        })
}

function Clear-CodeAntUserAntiPatternDisposition {
    <#
    .SYNOPSIS
      Return a copy of the row with Disposition cleared (other fields unchanged).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Row
    )

    return [pscustomobject]@{
        Id           = $Row.Id
        Scope        = $Row.Scope
        Repo         = $Row.Repo
        Pattern      = $Row.Pattern
        Signals      = $Row.Signals
        FixDirection = $Row.FixDirection
        Disposition  = ''
        EnforcedBy   = $Row.EnforcedBy
    }
}

function Get-CodeAntTriageProfileRoot {
    param([string]$ProfileRoot = '')
    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        $ProfileRoot = Join-Path $env:USERPROFILE '.cursor'
    }
    return [IO.Path]::GetFullPath($ProfileRoot)
}

function Get-CodeAntTriageUserDataRoot {
    param([string]$ProfileRoot = '')
    return Join-Path (Get-CodeAntTriageProfileRoot -ProfileRoot $ProfileRoot) 'codeant-triage'
}

function Get-CodeAntTriageLegacyPackRoot {
    param([string]$ProfileRoot = '')
    return Join-Path (Get-CodeAntTriageProfileRoot -ProfileRoot $ProfileRoot) 'packs\codeant-triage'
}

function Resolve-CodeAntTriageShippedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$InstallRoot,
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    $atRoot = Join-Path $InstallRoot $FileName
    if (Test-Path -LiteralPath $atRoot -PathType Leaf) {
        return $atRoot
    }
    $inContent = Join-Path $InstallRoot (Join-Path 'content' $FileName)
    if (Test-Path -LiteralPath $inContent -PathType Leaf) {
        return $inContent
    }
    return $atRoot
}

function Copy-CodeAntTriageUserDataFromLegacyPack {
    param(
        [string]$ProfileRoot = '',
        [switch]$WhatIf
    )
    $profile = Get-CodeAntTriageProfileRoot -ProfileRoot $ProfileRoot
    $userDataRoot = Get-CodeAntTriageUserDataRoot -ProfileRoot $profile
    $legacyRoot = Get-CodeAntTriageLegacyPackRoot -ProfileRoot $profile
    foreach ($name in @('anti-patterns.user.md', 'promote-preferences.json')) {
        $dest = Join-Path $userDataRoot $name
        $src = Join-Path $legacyRoot $name
        if ((Test-Path -LiteralPath $dest -PathType Leaf) -or -not (Test-Path -LiteralPath $src -PathType Leaf)) {
            continue
        }
        if ($WhatIf) {
            Write-Output "[WhatIf] migrate $src -> $dest"
            continue
        }
        if (-not (Test-Path -LiteralPath $userDataRoot)) {
            New-Item -ItemType Directory -Force -Path $userDataRoot | Out-Null
        }
        Copy-Item -LiteralPath $src -Destination $dest -Force
        Write-Output "Migrated: $dest"
    }
}

function Get-CodeAntTriagePathSet {
    param(
        [string]$ProfileRoot = '',
        [string]$ScriptsRoot = ''
    )
    $profile = Get-CodeAntTriageProfileRoot -ProfileRoot $ProfileRoot
    if ([string]::IsNullOrWhiteSpace($ScriptsRoot)) {
        $ScriptsRoot = $PSScriptRoot
    }
    $ScriptsRoot = [IO.Path]::GetFullPath($ScriptsRoot)
    $installRoot = [IO.Path]::GetFullPath((Split-Path -Parent $ScriptsRoot))
    $userDataRoot = Get-CodeAntTriageUserDataRoot -ProfileRoot $profile
    return [pscustomobject]@{
        profileRoot     = $profile
        userDataRoot    = $userDataRoot
        userCatalog     = Join-Path $userDataRoot 'anti-patterns.user.md'
        prefs           = Join-Path $userDataRoot 'promote-preferences.json'
        scriptsRoot     = $ScriptsRoot
        installRoot     = $installRoot
        coreCatalog     = Resolve-CodeAntTriageShippedFile -InstallRoot $installRoot -FileName 'anti-patterns.core.md'
        uapscanFixLoop  = Resolve-CodeAntTriageShippedFile -InstallRoot $installRoot -FileName 'uapscan-fix-loop.md'
        templateRoot    = Join-Path $installRoot 'templates'
        legacyPackRoot  = Get-CodeAntTriageLegacyPackRoot -ProfileRoot $profile
    }
}
