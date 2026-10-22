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

function Test-CodeAntAdoCoreExports {
    $required = @{
        'New-AdoCorePullRequestThread' = @(
            'PullRequestId', 'Content', 'WorkspaceRoot', 'Collection', 'Project', 'Repository', 'ServerUrl'
        )
        'Get-AdoCorePullRequestThreads' = @(
            'PullRequestId', 'WorkspaceRoot', 'Collection', 'Project', 'Repository', 'ServerUrl'
        )
        'Add-AdoCorePullRequestThreadComment' = @(
            'PullRequestId', 'ThreadId', 'ParentCommentId', 'Content',
            'WorkspaceRoot', 'Collection', 'Project', 'Repository', 'ServerUrl'
        )
        'Set-AdoCorePullRequestThreadStatus' = @(
            'PullRequestId', 'ThreadId', 'Status',
            'WorkspaceRoot', 'Collection', 'Project', 'Repository', 'ServerUrl'
        )
        'Resolve-AdoCoreEndpoints' = @(
            'WorkspaceRoot', 'Collection', 'Project', 'Repository', 'ServerUrl'
        )
        'Assert-AdoCoreTrustedApiBase' = @(
            'ApiBase'
        )
    }
    foreach ($name in $required.Keys) {
        $command = Get-Command -Name $name -ErrorAction SilentlyContinue
        if (-not $command) {
            return $false
        }
        foreach ($parameter in $required[$name]) {
            if (-not $command.Parameters.ContainsKey($parameter)) {
                return $false
            }
        }
    }
    return $true
}

function Get-CodeAntAdoCoreScriptCandidates {
    param([string]$ProfileRoot = $env:USERPROFILE)

    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $pluginsRoot = Join-Path $ProfileRoot '.cursor\plugins'
    $direct = Join-Path $pluginsRoot 'sicon-ado-core\scripts\ado-core.ps1'
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        [void]$candidates.Add($direct)
    }

    $cacheRoot = Join-Path $pluginsRoot 'cache'
    if (Test-Path -LiteralPath $cacheRoot) {
        $cached = @(
            Get-ChildItem -LiteralPath $cacheRoot -Recurse -Filter 'ado-core.ps1' -File -ErrorAction SilentlyContinue |
                Where-Object {
                    $_.FullName -match '[\\/]sicon-ado-core[\\/].*[\\/]scripts[\\/]ado-core\.ps1$'
                } |
                Sort-Object LastWriteTimeUtc -Descending
        )
        foreach ($item in $cached) {
            if (-not $candidates.Contains($item.FullName)) {
                [void]$candidates.Add($item.FullName)
            }
        }
    }

    $userPack = Join-Path $ProfileRoot '.cursor\packs\ado-core\scripts\ado-core.ps1'
    if (Test-Path -LiteralPath $userPack -PathType Leaf) {
        [void]$candidates.Add($userPack)
    }
    return @($candidates.ToArray())
}

function Resolve-CodeAntAdoCoreScriptPath {
    param([string]$ProfileRoot = $env:USERPROFILE)

    $candidates = @(Get-CodeAntAdoCoreScriptCandidates -ProfileRoot $ProfileRoot)
    if ($candidates.Count -gt 0) {
        return $candidates[0]
    }
    throw 'ADO Core library not found. Install or upgrade sicon-ado-core from the Sicon Team Marketplace (or Install-UserPack -Pack ado-core).'
}

function Import-CodeAntAdoCore {
    param([string]$ProfileRoot = $env:USERPROFILE)

    $candidates = @(Get-CodeAntAdoCoreScriptCandidates -ProfileRoot $ProfileRoot)
    foreach ($path in $candidates) {
        try {
            $before = @{}
            Get-ChildItem Function: | ForEach-Object { $before[$_.Name] = $_.ScriptBlock }
            . $path
            $loadedFunctions = @(Get-ChildItem Function:)
            $loadedFunctions | ForEach-Object {
                $name = $_.Name
                $updated = -not $before.ContainsKey($name)
                if (-not $updated) {
                    $updated = -not [object]::ReferenceEquals($before[$name], $_.ScriptBlock)
                }
                if ($updated) {
                    Set-Item -Path "Function:global:$name" -Value $_.ScriptBlock
                }
            }
            if (Test-CodeAntAdoCoreExports) {
                return $true
            }
        }
        catch {
            continue
        }
    }

    if ($candidates.Count -eq 0) {
        throw 'ADO Core library not found. Install or upgrade sicon-ado-core from the Sicon Team Marketplace (or Install-UserPack -Pack ado-core).'
    }

    throw "ADO Core is installed but missing required PR thread helpers. Upgrade sicon-ado-core, then retry. Checked: $($candidates -join ', ')"
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
        [string]$ServerUrl = '',
        [string]$WorkspaceRoot = ''
    )

    Import-CodeAntAdoCore | Out-Null
    Set-AdoCorePullRequestThreadStatus -PullRequestId $PullRequestId -ThreadId $ThreadId -Status $Status `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl `
        -WorkspaceRoot $WorkspaceRoot
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
        [string]$ServerUrl = '',
        [string]$WorkspaceRoot = ''
    )

    $endpoints = Resolve-AdoCodeAntTriageEndpoints -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl -WorkspaceRoot $WorkspaceRoot
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
        [string]$ServerUrl = '',
        [string]$WorkspaceRoot = ''
    )

    if (-not $PSBoundParameters.ContainsKey('Threads') -or $null -eq $Threads) {
        $Threads = Get-CodeAntPullRequestThreads -PullRequestId $PullRequestId `
            -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl `
            -WorkspaceRoot $WorkspaceRoot
    }

    $resolved = New-Object System.Collections.Generic.List[int]
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($thread in @($Threads)) {
        if (-not (Test-IsCodeAntRetriggerThread -Thread $thread -Comment $Comment)) { continue }
        $threadId = [int]$thread.id
        try {
            Set-CodeAntAdoThreadStatus -PullRequestId $PullRequestId -ThreadId $threadId -Status Fixed `
                -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl `
                -WorkspaceRoot $WorkspaceRoot
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

function Test-IsCodeAntMetaThread {
    param($Thread)

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

    # Status-family allowlist: Code Ant author + first-heading match (not a human phrase mention).
    # Live posts often prefix emoji / shortcodes (e.g. "## <robot> CodeAnt AI - Review Status",
    # "# :checkered_flag: CodeAnt Quality Gate Results") - keep the allowlist tolerant of that.
    # Patterns must stay pure ASCII: this file is UTF-8 without BOM and Windows PowerShell 5.1
    # decodes it as ANSI, so any literal non-ASCII char (e.g. an em dash) loads as mojibake and
    # never matches live content. Use regex escapes such as \u2014 instead.
    $headerPatterns = @(
        '(?m)^##\s+(?:\S+\s+)?Ticket Scope Review\b'
        '(?m)^##\s+(?:\S+\s+)?CodeAnt AI\s*[-\u2014]\s*Review Status\b'
        '(?m)^#{1,2}\s+(?::[\w+]+:\s*)?CodeAnt Quality Gate Results\b'
        '(?m)^##\s+CodeAnt Nitpicks\b'
        '(?m)^(?:##\s+|\*\*)?CodeAnt PR Risk\b'
    )
    foreach ($threadComment in (Get-AdoThreadComments -Thread $Thread)) {
        if ((Get-AdoCommentAuthorDisplayName -Comment $threadComment) -ne $script:CodeAntAuthorName) { continue }
        $body = Get-AdoCommentContentText -Comment $threadComment
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        foreach ($pattern in $headerPatterns) {
            if ($body -match $pattern) { return $true }
        }
    }
    return $false
}

function Clear-CodeAntMetaThreads {
    <#
    .SYNOPSIS
      Marks active CodeAnt meta/status threads Closed (Ticket Scope / Review Status / Quality Gate / Nitpicks / PR Risk).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        $Threads,

        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = '',
        [string]$WorkspaceRoot = ''
    )

    if (-not $PSBoundParameters.ContainsKey('Threads') -or $null -eq $Threads) {
        $Threads = Get-CodeAntPullRequestThreads -PullRequestId $PullRequestId `
            -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl `
            -WorkspaceRoot $WorkspaceRoot
    }

    $resolved = New-Object System.Collections.Generic.List[int]
    $warnings = New-Object System.Collections.Generic.List[string]
    foreach ($thread in @($Threads)) {
        if (-not (Test-IsCodeAntMetaThread -Thread $thread)) { continue }
        $threadId = [int]$thread.id
        try {
            Set-CodeAntAdoThreadStatus -PullRequestId $PullRequestId -ThreadId $threadId -Status Closed `
                -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl `
                -WorkspaceRoot $WorkspaceRoot
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
                Id              = [string]$thread.id
                Number          = $index
                Path            = $path
                Line            = Get-AdoThreadLineRange -ThreadContext $threadContext
                Comment         = (Get-AdoCommentContentText -Comment $comment).Trim()
                ThreadId        = $thread.id
                ParentCommentId = $comment.id
                ThreadStatus    = $status
                Source          = 'file'
            })
    }

    return $findings
}

# --- Quality Gate + Nitpicks meta-comment parsing ---------------------------------
# CodeAnt posts two finding-bearing payloads as PR-level meta comments instead of
# file threads, so Get-CodeAntFileFindingsFromThreads cannot see them:
#   1. "CodeAnt Quality Gate Results" - per-gate table plus, inside <details>, a
#      generic File/Line detail table per failed gate (Secrets on PR 31460).
#   2. "CodeAnt Nitpicks" - numbered suggestions whose file/line live only in a
#      markdown link (`path:line`) on the line under each #### heading.
# Both are normalised here. Nitpicks become comment-equivalent findings (same
# Path/Line/Comment shape as file findings, Source = 'nitpick'). Quality Gate
# detail rows become *security findings* (source/gate/path/line/type/confidence/
# status/resultsUrl/metaThreadId) kept separate from file findings: they have no
# ADO thread of their own, so they must never be folded into activeFindingCount
# or completed per finding (see the disposition model in codeant-review-state.ps1).
# This file must stay pure ASCII (PS 5.1 decodes UTF-8-no-BOM as ANSI); all
# non-ASCII match characters below use regex \uXXXX escapes or [char] casts.

function ConvertTo-CodeAntGateStatus {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'unknown' }
    $clean = ($Text -replace ':[a-z0-9_+-]+:', ' ' -replace '\*', ' ').Trim().ToLowerInvariant()
    if ($clean -match 'fail') { return 'failed' }
    if ($clean -match 'pass') { return 'passed' }
    return 'unknown'
}

function Get-CodeAntMetaComment {
    param(
        $Thread,
        [Parameter(Mandatory = $true)]
        [string]$HeaderPattern
    )

    foreach ($comment in (Get-AdoThreadComments -Thread $Thread)) {
        if ((Get-AdoCommentAuthorDisplayName -Comment $comment) -ne $script:CodeAntAuthorName) { continue }
        $body = Get-AdoCommentContentText -Comment $comment
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        if ($body -match $HeaderPattern) { return $comment }
    }
    return $null
}

function Get-CodeAntThreadStatusText {
    param($Thread)

    $status = 'active'
    if ($Thread.PSObject.Properties.Name -contains 'status' -and $null -ne $Thread.status) {
        $status = [string]$Thread.status
    }
    return $status
}

function ConvertFrom-CodeAntSummaryGateName {
    param([string]$SummaryHtml)

    if ([string]::IsNullOrWhiteSpace($SummaryHtml)) { return '' }
    $text = ($SummaryHtml -replace '<[^>]+>', ' ').Trim()
    $text = ($text -replace ':[a-z0-9_+-]+:', ' ').Trim()
    $text = ($text -replace '^\W+', '').Trim()
    $parts = @($text -split "\u2014|\u2013|\s-\s")
    if ($parts.Count -eq 0) { return '' }
    return ([string]$parts[0]).Trim().TrimEnd(':').Trim()
}

function Get-CodeAntQualityGateFromContent {
    <#
    .SYNOPSIS
      Parse one Quality Gate results comment body into gate rows + detail rows.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [int]$MetaThreadId = 0
    )

    $overallText = ''
    $commit = ''
    $scanTime = ''
    $resultsUrl = ''
    $gates = New-Object 'System.Collections.Generic.List[object]'
    $detailRows = New-Object 'System.Collections.Generic.List[object]'
    $currentGate = ''
    $mode = ''
    $col = @{}

    foreach ($line in @($Content -split '\r?\n')) {
        if ($line -match 'Overall Status:\s*\**\s*([A-Za-z]+)') { $overallText = $Matches[1] }
        if ($line -match '^\s*\*\*Commit:\*\*\s*`?([^`\s]+)`?') { $commit = $Matches[1] }
        if ($line -match '^\s*\*\*Scan Time:\*\*\s*(.+?)\s*$') { $scanTime = $Matches[1] }
        if ([string]::IsNullOrWhiteSpace($resultsUrl) -and $line -match '(https://app\.codeant\.ai/quality-gates/results\?[^)\s]+)') {
            $resultsUrl = $Matches[1]
        }
        if ($line -match '<summary>(.*?)</summary>') {
            $gateName = ConvertFrom-CodeAntSummaryGateName -SummaryHtml $Matches[1]
            if (-not [string]::IsNullOrWhiteSpace($gateName)) { $currentGate = $gateName }
            $mode = ''
            continue
        }
        if ($line -notmatch '^\s*\|') {
            if ($line -notmatch '^\s*$') { $mode = '' }
            continue
        }
        if ($line -match '^\|\s*-+') { continue }

        $cells = @(Split-MarkdownTableRowCells -Line $line)
        if ($cells.Count -eq 0) { continue }
        $headers = @($cells | ForEach-Object { ([string]$_ -replace '\*', '').Trim().ToLowerInvariant() })

        if ($headers -contains 'quality gate' -and $headers -contains 'status') {
            $mode = 'gates'
            $col = @{
                Name    = [array]::IndexOf($headers, 'quality gate')
                Status  = [array]::IndexOf($headers, 'status')
                Details = [array]::IndexOf($headers, 'details')
            }
            continue
        }
        if ($headers -contains 'file' -and $headers -contains 'line') {
            $mode = 'detail'
            $typeIdx = [array]::IndexOf($headers, 'type')
            if ($typeIdx -lt 0) { $typeIdx = [array]::IndexOf($headers, 'issue') }
            if ($typeIdx -lt 0) { $typeIdx = [array]::IndexOf($headers, 'rule') }
            if ($typeIdx -lt 0) { $typeIdx = [array]::IndexOf($headers, 'message') }
            $col = @{
                File       = [array]::IndexOf($headers, 'file')
                Line       = [array]::IndexOf($headers, 'line')
                Type       = $typeIdx
                Confidence = [array]::IndexOf($headers, 'confidence')
            }
            continue
        }

        if ($mode -eq 'gates' -and $cells.Count -gt $col.Status) {
            $gateStatus = ConvertTo-CodeAntGateStatus -Text ([string]$cells[$col.Status])
            $details = ''
            if ($col.Details -ge 0 -and $cells.Count -gt $col.Details) { $details = ([string]$cells[$col.Details]).Trim() }
            [void]$gates.Add([pscustomobject]@{
                    name         = ([string]$cells[$col.Name] -replace '\*', '').Trim()
                    status       = $gateStatus
                    details      = $details
                    findingCount = 0
                })
            continue
        }
        if ($mode -eq 'detail' -and $cells.Count -gt $col.File -and $cells.Count -gt $col.Line) {
            $file = ([string]$cells[$col.File] -replace '`', '' -replace '\*', '').Trim()
            $lineText = ([string]$cells[$col.Line]).Trim()
            $lineNo = $null
            if ($lineText -match '(\d+)') { $lineNo = [int]$Matches[1] }
            $type = ''
            if ($col.Type -ge 0 -and $cells.Count -gt $col.Type) { $type = ([string]$cells[$col.Type]).Trim() }
            $confidence = ''
            if ($col.Confidence -ge 0 -and $cells.Count -gt $col.Confidence) { $confidence = ([string]$cells[$col.Confidence]).Trim() }
            if (-not [string]::IsNullOrWhiteSpace($file)) {
                [void]$detailRows.Add([pscustomobject]@{
                        gate       = $currentGate
                        path       = $file
                        line       = $lineNo
                        type       = $type
                        confidence = $confidence
                    })
            }
            continue
        }
    }

    $status = ConvertTo-CodeAntGateStatus -Text $overallText
    if ($status -eq 'unknown') {
        $failedGates = @($gates | Where-Object { $_.status -eq 'failed' })
        if ($failedGates.Count -gt 0) { $status = 'failed' }
        elseif ($gates.Count -gt 0) { $status = 'passed' }
    }

    foreach ($gate in $gates) {
        $gate.findingCount = @($detailRows | Where-Object { $_.gate -ieq $gate.name }).Count
    }

    $security = New-Object 'System.Collections.Generic.List[object]'
    foreach ($row in $detailRows) {
        $gateName = [string]$row.gate
        $gateRow = @($gates | Where-Object { $_.name -ieq $gateName }) | Select-Object -First 1
        if ($gateRow -and $gateRow.status -ne 'failed') { continue }
        if ([string]::IsNullOrWhiteSpace($gateName)) { $gateName = 'Quality Gate' }
        $type = [string]$row.type
        if ([string]::IsNullOrWhiteSpace($type)) { $type = "$gateName finding" }
        [void]$security.Add([pscustomobject]@{
                source       = 'qualityGate'
                gate         = $gateName
                path         = [string]$row.path
                line         = $row.line
                type         = $type
                confidence   = [string]$row.confidence
                status       = 'open'
                resultsUrl   = $resultsUrl
                metaThreadId = $MetaThreadId
            })
    }
    # Never drop a failed gate: a failed gate with no parseable detail row (web-only
    # detail behind the results URL, a new table shape, ...) still yields one
    # gate-level finding carrying resultsUrl so a human/agent can open the detail.
    foreach ($gate in @($gates | Where-Object { $_.status -eq 'failed' })) {
        if (@($security | Where-Object { $_.gate -ieq $gate.name }).Count -gt 0) { continue }
        [void]$security.Add([pscustomobject]@{
                source       = 'qualityGate'
                gate         = [string]$gate.name
                path         = ''
                line         = $null
                type         = 'Quality gate failed'
                confidence   = ''
                status       = 'open'
                resultsUrl   = $resultsUrl
                metaThreadId = $MetaThreadId
            })
    }
    if ($status -eq 'failed' -and $security.Count -eq 0) {
        [void]$security.Add([pscustomobject]@{
                source       = 'qualityGate'
                gate         = 'Quality Gate'
                path         = ''
                line         = $null
                type         = 'Quality gate failed'
                confidence   = ''
                status       = 'open'
                resultsUrl   = $resultsUrl
                metaThreadId = $MetaThreadId
            })
    }

    return [pscustomobject]@{
        status            = $status
        commit            = $commit
        scanTime          = $scanTime
        resultsUrl        = $resultsUrl
        metaThreadId      = $MetaThreadId
        gates             = @($gates.ToArray())
        securityFindings  = @($security.ToArray())
        securityFindingCount = $security.Count
    }
}

function Get-CodeAntQualityGateFromThreads {
    <#
    .SYNOPSIS
      Latest active Quality Gate meta thread on a PR, parsed; $null when absent.
    .DESCRIPTION
      CodeAnt threads often carry no ADO status property at all - a missing status
      counts as active (Test-IsActiveAdoThread). Non-active (e.g. Closed after a
      wont-fix meta summary) gate threads no longer contribute security findings.
    #>
    param($Threads)

    $best = $null
    $bestId = -1
    foreach ($thread in @(Get-CodeAntReviewThreadListSafe -Threads $Threads)) {
        if ($null -eq $thread) { continue }
        if (-not (Test-IsActiveAdoThread -Status (Get-CodeAntThreadStatusText -Thread $thread))) { continue }
        $comment = Get-CodeAntMetaComment -Thread $thread -HeaderPattern '(?m)^#{1,2}\s+(?::[\w+]+:\s*)?CodeAnt Quality Gate Results\b'
        if ($null -eq $comment) { continue }
        $threadId = 0
        $rawId = Get-PsObjectPropertyValue -Object $thread -Name 'id' -Default 0
        if ("$rawId" -match '^\d+$') { $threadId = [int]$rawId }
        if ($threadId -lt $bestId) { continue }
        $bestId = $threadId
        $best = Get-CodeAntQualityGateFromContent -Content (Get-AdoCommentContentText -Comment $comment) -MetaThreadId $threadId
        $best | Add-Member -NotePropertyName parentCommentId -NotePropertyValue $comment.id -Force
        $dismissedKeys = Get-CodeAntDismissedMetaFindingKeys -Thread $thread
        if ($dismissedKeys.Count -gt 0) {
            $kept = @($best.securityFindings | Where-Object {
                    $lineText = ''
                    if ($null -ne $_.line) { $lineText = [string]$_.line }
                    -not $dismissedKeys.ContainsKey((ConvertTo-CodeAntMetaFindingKey -Path ([string]$_.path) -Line $lineText))
                })
            $best.securityFindings = $kept
            $best.securityFindingCount = $kept.Count
        }
    }
    return $best
}

function Get-CodeAntReviewThreadListSafe {
    # Get-CodeAntReviewThreadList lives in codeant-review-state.ps1 (dot-sourced
    # after this file); resolve lazily so this parser also works if only the
    # helpers above it have been loaded, without re-implementing unwrapping.
    param($Threads)

    if (Get-Command -Name Get-CodeAntReviewThreadList -ErrorAction SilentlyContinue) {
        return @(Get-CodeAntReviewThreadList -Threads $Threads)
    }
    if ($null -eq $Threads) { return @() }
    return @($Threads)
}

function Get-CodeAntSecurityFindingsFromThreads {
    <#
    .SYNOPSIS
      Security findings normalised from the active Quality Gate meta thread.
    #>
    param($Threads)

    $gate = Get-CodeAntQualityGateFromThreads -Threads $Threads
    if ($null -eq $gate) { return @() }
    return @($gate.securityFindings)
}

function ConvertFrom-CodeAntNitpickComment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Content,

        [int]$MetaThreadId = 0,
        $ParentCommentId = $null,
        [string]$ThreadStatus = 'active'
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    $title = ''
    $index = 0
    foreach ($line in @($Content -split '\r?\n')) {
        if ($line -match '^\s*####\s+(\d+)\.\s+(.+?)\s*$') {
            $index = [int]$Matches[1]
            $title = ($Matches[2] -replace '&#x27;', "'" -replace '&quot;', '"' -replace '&amp;', '&').Trim()
            continue
        }
        if ([string]::IsNullOrWhiteSpace($title)) { continue }
        if ($line -notmatch '\[(`?)([^`\]]+)\1\]\([^)]+\)') { continue }
        $linkText = ([string]$Matches[2]).Trim()
        if ($linkText -notmatch '^(.+):(\d+)$') { continue }

        $rawPath = ([string]$Matches[1]).Trim().TrimStart('/')
        $category = ''
        $prefix = $line.Substring(0, $line.IndexOf('[')).Trim()
        if (-not [string]::IsNullOrWhiteSpace($prefix)) {
            $category = ($prefix -replace "\u00B7\s*$", '').Trim().TrimEnd('-').Trim()
        }
        [void]$findings.Add([pscustomobject]@{
                Id              = "$MetaThreadId-$index"
                Number          = $findings.Count + 1
                Path            = "/$rawPath"
                Line            = [string]$Matches[2]
                Comment         = $title
                Category        = $category
                ThreadId        = $MetaThreadId
                ParentCommentId = $ParentCommentId
                ThreadStatus    = $ThreadStatus
                Source          = 'nitpick'
                MetaThreadId    = $MetaThreadId
            })
        $title = ''
    }
    return @($findings.ToArray())
}

function ConvertTo-CodeAntMetaFindingKey {
    param(
        [string]$Path,
        [string]$Line
    )

    $normalised = ([string]$Path).Trim().TrimStart('/').Replace('\', '/').ToLowerInvariant()
    return "$normalised|$(([string]$Line).Trim())"
}

function Get-CodeAntDismissedMetaFindingKeys {
    <#
    .SYNOPSIS
      Location keys already dismissed inside a shared meta thread.
    .DESCRIPTION
      A won't-fix summary for meta-sourced findings is posted as a non-CodeAnt
      reply carrying **WontFix Reason:** and listing each dismissed finding's
      location (`path ~line` or a `path:line` link). When the shared meta
      thread stays active (a sibling finding was skipped or awaits re-review),
      the original CodeAnt comment would otherwise be reparsed next session
      and the dismissed findings would resurface as active. Only non-CodeAnt
      comments with the WontFix Reason marker count as dismissal evidence.
    #>
    param($Thread)

    $keys = @{}
    if ($null -eq $Thread) { return $keys }
    foreach ($comment in (Get-AdoThreadComments -Thread $Thread)) {
        if ((Get-AdoCommentAuthorDisplayName -Comment $comment) -eq $script:CodeAntAuthorName) { continue }
        $body = Get-AdoCommentContentText -Comment $comment
        if ([string]::IsNullOrWhiteSpace($body)) { continue }
        if ($body -notmatch '(?i)\*\*WontFix Reason:\*\*') { continue }
        foreach ($m in [regex]::Matches($body, '\[(`?)(?<path>[^`\]\s]+):(?<line>\d+)\1\]\(')) {
            $keys[(ConvertTo-CodeAntMetaFindingKey -Path $m.Groups['path'].Value -Line $m.Groups['line'].Value)] = $true
        }
        foreach ($m in [regex]::Matches($body, '(?<path>[A-Za-z0-9_.\-/]+\.[A-Za-z0-9]+)\s*~(?<line>\d+)')) {
            $keys[(ConvertTo-CodeAntMetaFindingKey -Path $m.Groups['path'].Value -Line $m.Groups['line'].Value)] = $true
        }
    }
    return $keys
}

function Get-CodeAntNitpickFindingsFromThreads {
    <#
    .SYNOPSIS
      Comment-equivalent findings embedded in active CodeAnt Nitpicks meta threads.
    #>
    param(
        $Threads,
        [switch]$ActiveOnly
    )

    $findings = New-Object 'System.Collections.Generic.List[object]'
    foreach ($thread in @(Get-CodeAntReviewThreadListSafe -Threads $Threads)) {
        if ($null -eq $thread) { continue }
        $status = Get-CodeAntThreadStatusText -Thread $thread
        if ($ActiveOnly -and -not (Test-IsActiveAdoThread -Status $status)) { continue }
        $threadContext = Get-PsObjectPropertyValue -Object $thread -Name 'threadContext' -Default $null
        $filePath = ''
        if ($null -ne $threadContext) {
            $filePath = [string](Get-PsObjectPropertyValue -Object $threadContext -Name 'filePath' -Default '')
        }
        if (-not [string]::IsNullOrWhiteSpace($filePath)) { continue }
        $comment = Get-CodeAntMetaComment -Thread $thread -HeaderPattern '(?m)^##\s+CodeAnt Nitpicks\b'
        if ($null -eq $comment) { continue }
        $threadId = 0
        $rawId = Get-PsObjectPropertyValue -Object $thread -Name 'id' -Default 0
        if ("$rawId" -match '^\d+$') { $threadId = [int]$rawId }
        $dismissedKeys = Get-CodeAntDismissedMetaFindingKeys -Thread $thread
        foreach ($finding in @(ConvertFrom-CodeAntNitpickComment -Content (Get-AdoCommentContentText -Comment $comment) `
                -MetaThreadId $threadId -ParentCommentId $comment.id -ThreadStatus $status)) {
            if ($dismissedKeys.ContainsKey((ConvertTo-CodeAntMetaFindingKey -Path ([string]$finding.Path) -Line ([string]$finding.Line)))) { continue }
            $finding.Number = $findings.Count + 1
            [void]$findings.Add($finding)
        }
    }
    return @($findings.ToArray())
}

function Test-IsCodeAntMetaSourcedFinding {
    <#
    .SYNOPSIS
      True for findings that live inside a shared meta thread (qualityGate /
      nitpick) rather than owning an ADO file thread.
    #>
    param($Finding)

    if ($null -eq $Finding) { return $false }
    if (Test-PsObjectHasProperty -Object $Finding -Name 'source') {
        if ([string]$Finding.source -eq 'qualityGate') { return $true }
    }
    if (Test-PsObjectHasProperty -Object $Finding -Name 'Source') {
        $source = [string]$Finding.Source
        if ($source -eq 'nitpick' -or $source -eq 'qualityGate') { return $true }
    }
    if (Test-PsObjectHasProperty -Object $Finding -Name 'metaThreadId') { return $true }
    if (Test-PsObjectHasProperty -Object $Finding -Name 'MetaThreadId') { return $true }
    return $false
}

function Get-CodeAntFindingScaffold {
    <#
    .SYNOPSIS
      Emit the per-finding explain-block scaffold the triage loop completes.
    .DESCRIPTION
      Deterministic starting point for the one-turn Treat gate: every slot
      except Verdict / Proposed change / Recommendation (and the code Context)
      is pre-filled from the finding, so the agent completes lines instead of
      remembering to construct a block before its AskQuestion card. Emitting
      a scaffold with <complete: ...> slots left in it is not a valid block.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Finding,

        [Parameter(Mandatory = $true)]
        [string]$Heading
    )

    $path = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'Path' -Default '')
    if ([string]::IsNullOrWhiteSpace($path)) { $path = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'path' -Default '') }
    $lineValue = Get-PsObjectPropertyValue -Object $Finding -Name 'Line' -Default $null
    if ($null -eq $lineValue) { $lineValue = Get-PsObjectPropertyValue -Object $Finding -Name 'line' -Default $null }
    $line = ''
    if ($null -ne $lineValue) { $line = [string]$lineValue }

    $said = ([string](Get-PsObjectPropertyValue -Object $Finding -Name 'Comment' -Default '')).Trim()
    if ([string]::IsNullOrWhiteSpace($said)) {
        $gate = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'gate' -Default '')
        if ([string]::IsNullOrWhiteSpace($gate)) { $gate = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'Gate' -Default '') }
        if ([string]::IsNullOrWhiteSpace($gate)) { $gate = 'Quality Gate' }
        $type = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'type' -Default '')
        if ([string]::IsNullOrWhiteSpace($type)) { $type = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'Type' -Default '') }
        $confidence = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'confidence' -Default '')
        if ([string]::IsNullOrWhiteSpace($confidence)) { $confidence = [string](Get-PsObjectPropertyValue -Object $Finding -Name 'Confidence' -Default '') }
        $said = "$gate quality gate reported $type"
        if (-not [string]::IsNullOrWhiteSpace($line)) { $said += " at line $line" }
        if (-not [string]::IsNullOrWhiteSpace($confidence)) { $said += " ($confidence confidence)" }
        $said += '.'
    }

    $location = ''
    if ([string]::IsNullOrWhiteSpace($path)) {
        $location = '(location not posted - locate from the gate/type context in the PR diff; do not invent a location)'
    }
    else {
        $location = '`' + $path.Trim() + '`'
        if (-not [string]::IsNullOrWhiteSpace($line)) { $location += " ~$line" }
    }

    # Blocked sections: label on its own line, body beneath, blank line between
    # sections. Inline "**Label:** ..." lines collapse into one wall-of-text
    # paragraph in chat rendering - never emit that shape.
    $sections = @(
        @{ Label = 'Header'; Body = "$Heading - $location" }
        @{ Label = 'CodeAnt said'; Body = $said }
        @{ Label = 'Context'; Body = '<complete: relevant code and/or branch diff at this location, citing lines>' }
        @{ Label = 'Rule cross-check'; Body = '<complete: CAP/AP row + scoped UAP/profile/open-repo rule, or why none applies>' }
        @{ Label = 'Verdict'; Body = '<complete: Already fixed | Valid | Partial | Invalid | Needs verification - with why>' }
        @{ Label = 'Proposed change'; Body = '<complete: concrete files + behaviour if Fix is chosen; do not apply yet>' }
        @{ Label = 'Recommendation'; Body = "<complete: Fix now | Won't fix | Skip - one-line rationale>" }
    )
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [void]$lines.Add("### $Heading - scaffold (complete every <complete: ...> slot, emit the completed block in chat, then AskQuestion in the same turn)")
    foreach ($section in $sections) {
        [void]$lines.Add('')
        [void]$lines.Add("**$($section.Label)**")
        [void]$lines.Add([string]$section.Body)
    }
    return ($lines -join [Environment]::NewLine)
}

function Get-CodeAntFindingCounts {
    param(
        $Threads = $null,

        $Findings = $null
    )

    if ($PSBoundParameters.ContainsKey('Findings')) {
        $Findings = @($Findings | Where-Object { $null -ne $_ })
    }
    elseif ($null -ne $Threads) {
        $Findings = @(Get-CodeAntFileFindingsFromThreads -Threads $Threads | Where-Object { $null -ne $_ })
    }
    else {
        throw 'Get-CodeAntFindingCounts requires -Threads or -Findings.'
    }

    $active = 0
    $fixed = 0
    foreach ($finding in $Findings) {
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
        [string]$ServerUrl = '',
        [string]$WorkspaceRoot = ''
    )

    if (-not $ServerUrl -or -not $Collection -or -not $Project -or -not $Repository) {
        $root = $WorkspaceRoot
        if ([string]::IsNullOrWhiteSpace($root)) {
            $root = Get-GitWorkspaceRoot
        }
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

# StrictMode: missing note property != $null - must probe before read.
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
                Id              = [string]$thread.id
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
      Parse UAP rows from anti-patterns.user.md. Legacy 7-column rows => blank Disposition.
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

. (Join-Path $PSScriptRoot 'codeant-review-state.ps1')
. (Join-Path $PSScriptRoot 'codeant-silent-triage.ps1')
