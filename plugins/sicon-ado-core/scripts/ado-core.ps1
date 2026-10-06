#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:AdoCoreLibraryVersion = [version]'0.6.0'

function Get-AdoCoreLibraryVersion {
    return $script:AdoCoreLibraryVersion
}

function Get-AdoCoreWorkspaceRoot {
    param([string]$WorkspaceRoot = '')

    if ($WorkspaceRoot) {
        $root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
    }
    else {
        $result = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $result) {
            throw 'Not inside a git repository. Pass -WorkspaceRoot explicitly.'
        }
        $root = [string]$result
    }

    if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
        throw "Not a git repository: $root"
    }
    return $root
}

function Get-AdoCoreDefaultsFromGitRemote {
    param([string]$WorkspaceRoot = '')

    $root = Get-AdoCoreWorkspaceRoot -WorkspaceRoot $WorkspaceRoot
    $remote = git -C $root config --get remote.origin.url 2>$null
    if (-not $remote) {
        throw 'Could not read remote.origin.url. Pass -ServerUrl, -Collection, -Project, and -Repository explicitly.'
    }

    if ($remote -match '^(https?://[^/]+)/tfs/([^/]+)/([^/]+)/_git/([^/?#]+)') {
        return @{
            ServerUrl  = $Matches[1]
            Collection = [Uri]::UnescapeDataString([string]$Matches[2])
            Project    = [Uri]::UnescapeDataString([string]$Matches[3])
            Repository = [Uri]::UnescapeDataString([string]$Matches[4])
        }
    }

    throw "Unsupported remote.origin.url for ADO: $remote"
}

function Normalize-AdoCoreServerUrl {
    param([string]$ServerUrl)

    if ([string]::IsNullOrWhiteSpace($ServerUrl)) { return $ServerUrl }
    $normalized = $ServerUrl.TrimEnd('/')
    if ($normalized -match '/tfs$') {
        return $normalized.Substring(0, $normalized.Length - 4)
    }
    return $normalized
}

function Assert-AdoCoreTrustedServerUrl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerUrl
    )

    $normalized = Normalize-AdoCoreServerUrl -ServerUrl $ServerUrl
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw 'ADO ServerUrl is empty.'
    }

    $uri = $null
    if (-not [Uri]::TryCreate($normalized, [UriKind]::Absolute, [ref]$uri)) {
        throw "ADO ServerUrl is not a valid absolute URI: $ServerUrl"
    }
    if ($uri.Scheme -ne 'https') {
        throw "ADO ServerUrl must use HTTPS (got '$($uri.Scheme)'): $ServerUrl"
    }
    $trustedHosts = @('tfs.sicon.co.uk')
    if ($trustedHosts -notcontains $uri.Host) {
        $allowed = $trustedHosts -join ', '
        throw "ADO ServerUrl host '$($uri.Host)' is not trusted. Allowed: $allowed"
    }
}

function Assert-AdoCoreTrustedApiBase {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,
        [string]$Name = 'ApiBase'
    )

    if ([string]::IsNullOrWhiteSpace($ApiBase)) {
        throw "ADO $Name is empty."
    }

    $uri = $null
    if (-not [Uri]::TryCreate($ApiBase.TrimEnd('/'), [UriKind]::Absolute, [ref]$uri)) {
        throw "ADO $Name is not a valid absolute URI: $ApiBase"
    }
    if ($uri.Scheme -ne 'https') {
        throw "ADO $Name must use HTTPS (got '$($uri.Scheme)'): $ApiBase"
    }
    $trustedHosts = @('tfs.sicon.co.uk')
    if ($trustedHosts -notcontains $uri.Host) {
        $allowed = $trustedHosts -join ', '
        throw "ADO $Name host '$($uri.Host)' is not trusted. Allowed: $allowed"
    }
}

function ConvertTo-AdoCoreUriPathSegment {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "ADO $Name path segment is empty."
    }
    if ($Value -in @('.', '..') -or $Value -match '[/\\?#]') {
        throw "ADO $Name contains an invalid path delimiter: $Value"
    }
    return [Uri]::EscapeDataString($Value)
}

function Resolve-AdoCoreCollectionEndpoint {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$ServerUrl = ''
    )

    if (-not $ServerUrl -or -not $Collection) {
        $defaults = Get-AdoCoreDefaultsFromGitRemote -WorkspaceRoot $WorkspaceRoot
        if (-not $ServerUrl) { $ServerUrl = $defaults.ServerUrl }
        if (-not $Collection) { $Collection = $defaults.Collection }
    }

    $ServerUrl = Normalize-AdoCoreServerUrl -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedServerUrl -ServerUrl $ServerUrl
    return @{
        ServerUrl  = $ServerUrl
        Collection = $Collection
    }
}

function Get-AdoCoreGitApiBase {
    param(
        [string]$ServerUrl,
        [string]$Collection,
        [string]$Project,
        [string]$Repository
    )

    $base = Normalize-AdoCoreServerUrl -ServerUrl $ServerUrl
    $collectionSegment = ConvertTo-AdoCoreUriPathSegment -Value $Collection -Name 'Collection'
    $projectSegment = ConvertTo-AdoCoreUriPathSegment -Value $Project -Name 'Project'
    $repositorySegment = ConvertTo-AdoCoreUriPathSegment -Value $Repository -Name 'Repository'
    return "$base/tfs/$collectionSegment/$projectSegment/_apis/git/repositories/$repositorySegment"
}

function Resolve-AdoCoreEndpoints {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if (-not $ServerUrl -or -not $Collection -or -not $Project -or -not $Repository) {
        $defaults = Get-AdoCoreDefaultsFromGitRemote -WorkspaceRoot $WorkspaceRoot
        if (-not $ServerUrl) { $ServerUrl = $defaults.ServerUrl }
        if (-not $Collection) { $Collection = $defaults.Collection }
        if (-not $Project) { $Project = $defaults.Project }
        if (-not $Repository) { $Repository = $defaults.Repository }
    }

    $ServerUrl = Normalize-AdoCoreServerUrl -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedServerUrl -ServerUrl $ServerUrl
    return @{
        ServerUrl  = $ServerUrl
        Collection = $Collection
        Project    = $Project
        Repository = $Repository
        ApiBase    = (Get-AdoCoreGitApiBase -ServerUrl $ServerUrl -Collection $Collection `
            -Project $Project -Repository $Repository)
    }
}

function Get-AdoCoreWitApiBase {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if (-not $ServerUrl -or -not $Collection -or -not $Project) {
        $defaults = Get-AdoCoreDefaultsFromGitRemote -WorkspaceRoot $WorkspaceRoot
        if (-not $ServerUrl) { $ServerUrl = $defaults.ServerUrl }
        if (-not $Collection) { $Collection = $defaults.Collection }
        if (-not $Project) { $Project = $defaults.Project }
        if (-not $Repository) { $Repository = $defaults.Repository }
    }
    elseif (-not $Repository -and $WorkspaceRoot) {
        try {
            $defaults = Get-AdoCoreDefaultsFromGitRemote -WorkspaceRoot $WorkspaceRoot
            if (-not $Repository) { $Repository = $defaults.Repository }
        }
        catch {
            # Repository / git ApiBase are optional for WIT URL construction.
        }
    }

    $ServerUrl = Normalize-AdoCoreServerUrl -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedServerUrl -ServerUrl $ServerUrl
    if ([string]::IsNullOrWhiteSpace($Collection)) {
        throw 'ADO Collection is required for Work Item Tracking.'
    }
    if ([string]::IsNullOrWhiteSpace($Project)) {
        throw 'ADO Project is required for Work Item Tracking.'
    }

    $endpoints = @{
        ServerUrl  = $ServerUrl
        Collection = $Collection
        Project    = $Project
        Repository = $Repository
        ApiBase    = $null
    }
    if (-not [string]::IsNullOrWhiteSpace($Repository)) {
        $endpoints.ApiBase = Get-AdoCoreGitApiBase -ServerUrl $ServerUrl -Collection $Collection `
            -Project $Project -Repository $Repository
    }

    $base = Normalize-AdoCoreServerUrl -ServerUrl $ServerUrl
    $collectionSegment = ConvertTo-AdoCoreUriPathSegment -Value $Collection -Name 'Collection'
    $projectSegment = ConvertTo-AdoCoreUriPathSegment -Value $Project -Name 'Project'
    return @{
        Endpoints      = $endpoints
        WitApiBase     = "$base/tfs/$collectionSegment/$projectSegment/_apis/wit"
        ProjectWebBase = "$base/tfs/$collectionSegment/$projectSegment"
    }
}

function Resolve-AdoCoreWitApiBaseValue {
    param(
        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($WitApiBase)) {
        Assert-AdoCoreTrustedApiBase -ApiBase $WitApiBase -Name 'WitApiBase'
        return $WitApiBase.TrimEnd('/')
    }

    $resolved = Get-AdoCoreWitApiBase -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    return [string]$resolved.WitApiBase
}

function Get-AdoCoreWorkItem {
    <#
    .SYNOPSIS
      GET one work item via WIT REST. Expand is opt-in (pass -Expand all when needed). Prefer this over hand-rolled URIs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Expand = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    $query = 'api-version=7.0'
    if (-not [string]::IsNullOrWhiteSpace($Expand)) {
        $query = "`$expand=$([uri]::EscapeDataString($Expand))&$query"
    }
    $uri = "$base/workitems/$WorkItemId`?$query"
    return Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
}

function Get-AdoCoreWorkItemComments {
    <#
    .SYNOPSIS
      GET work-item comments via WIT comments API (continuation-aware, bounded). Prefer this over hand-rolled URIs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [ValidateRange(1, 2000)]
        [int]$MaxComments = 500,
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    $baseUri = "$base/workitems/$WorkItemId/comments?api-version=7.0-preview.3"
    $comments = New-Object 'System.Collections.Generic.List[object]'
    $continuationToken = $null
    $truncated = $false
    $maxPages = 40
    $pageCount = 0
    do {
        if ($pageCount -ge $maxPages) {
            $truncated = $true
            break
        }
        $pageCount++

        $uri = $baseUri
        if ($continuationToken) {
            $uri = "$uri&continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        $response = Invoke-WebRequest -Uri $uri -Method Get -UseDefaultCredentials -UseBasicParsing
        $payload = $response.Content | ConvertFrom-Json
        $page = @()
        if ($payload.PSObject.Properties.Name -contains 'comments' -and $payload.comments) {
            $page = @($payload.comments)
        }
        elseif ($payload.PSObject.Properties.Name -contains 'value' -and $payload.value) {
            $page = @($payload.value)
        }

        foreach ($item in $page) {
            if ($comments.Count -ge $MaxComments) {
                $truncated = $true
                break
            }
            [void]$comments.Add($item)
        }

        if ($truncated) {
            $continuationToken = $null
        }
        else {
            $continuationToken = Get-AdoCoreContinuationToken -Response $response
        }
    } while ($continuationToken)

    return [pscustomobject]@{
        count     = $comments.Count
        comments  = @($comments.ToArray())
        truncated = $truncated
    }
}

function Get-AdoCoreAuthenticatedUser {
    param(
        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$ServerUrl = ''
    )

    $endpoint = Resolve-AdoCoreCollectionEndpoint -WorkspaceRoot $WorkspaceRoot `
        -Collection $Collection -ServerUrl $ServerUrl
    $collectionSegment = ConvertTo-AdoCoreUriPathSegment -Value $endpoint.Collection -Name 'Collection'
    $uri = "$($endpoint.ServerUrl)/tfs/$collectionSegment/_apis/connectionData?api-version=7.0-preview"
    $connection = Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
    return $connection.authenticatedUser
}

function Get-AdoCoreAssignedToFieldValue {
    param($User)

    if (-not $User) { return $null }
    $displayName = ''
    if ($User.PSObject.Properties.Name -contains 'displayName') {
        $displayName = [string]$User.displayName
    }
    elseif ($User.PSObject.Properties.Name -contains 'providerDisplayName') {
        $displayName = [string]$User.providerDisplayName
    }

    $uniqueName = ''
    if ($User.PSObject.Properties.Name -contains 'uniqueName') {
        $uniqueName = [string]$User.uniqueName
    }
    elseif ($User.PSObject.Properties.Name -contains 'properties') {
        $properties = $User.properties
        if ($properties -and ($properties.PSObject.Properties.Name -contains 'Account')) {
            $accountProp = $properties.Account
            if ($accountProp -and ($accountProp.PSObject.Properties.Name -contains '$value')) {
                $account = [string]$accountProp.'$value'
                $uniqueName = if ($account -match '@') { $account } else { "SICON\$account" }
            }
        }
    }

    if ($displayName -and $uniqueName) { return "$displayName <$uniqueName>" }
    if ($displayName) { return $displayName }
    return $null
}

function Get-AdoCoreWorkItemWebUrl {
    param(
        [int]$WorkItemId,
        $Endpoints
    )

    $base = Normalize-AdoCoreServerUrl -ServerUrl $Endpoints.ServerUrl
    $collectionSegment = ConvertTo-AdoCoreUriPathSegment -Value ([string]$Endpoints.Collection) -Name 'Collection'
    $projectSegment = ConvertTo-AdoCoreUriPathSegment -Value ([string]$Endpoints.Project) -Name 'Project'
    return "$base/tfs/$collectionSegment/$projectSegment/_workitems/edit/$WorkItemId"
}

function Get-AdoCorePullRequestWebUrl {
    param(
        [Parameter(Mandatory = $true)]
        $Endpoints,

        [Parameter(Mandatory = $true)]
        [int]$PullRequestId
    )

    $base = Normalize-AdoCoreServerUrl -ServerUrl $Endpoints.ServerUrl
    $collectionSegment = ConvertTo-AdoCoreUriPathSegment -Value ([string]$Endpoints.Collection) -Name 'Collection'
    $projectSegment = ConvertTo-AdoCoreUriPathSegment -Value ([string]$Endpoints.Project) -Name 'Project'
    $repositorySegment = ConvertTo-AdoCoreUriPathSegment -Value ([string]$Endpoints.Repository) -Name 'Repository'
    return "$base/tfs/$collectionSegment/$projectSegment/_git/$repositorySegment/pullrequest/$PullRequestId"
}

function Get-AdoCoreContinuationToken {
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

function Get-AdoCoreOpenPullRequestsForBranch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,

        [Parameter(Mandatory = $true)]
        [string]$SourceBranch
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $ApiBase
    $sourceRef = if ($SourceBranch -like 'refs/heads/*') { $SourceBranch } else { "refs/heads/$SourceBranch" }
    $encoded = [uri]::EscapeDataString($sourceRef)
    $baseUri = "$ApiBase/pullrequests?searchCriteria.sourceRefName=$encoded&searchCriteria.status=active&api-version=7.0"
    $pullRequests = New-Object 'System.Collections.Generic.List[object]'
    $continuationToken = $null
    do {
        $uri = $baseUri
        if ($continuationToken) {
            $uri = "$uri&continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        $response = Invoke-WebRequest -Uri $uri -Method Get -UseDefaultCredentials -UseBasicParsing
        $payload = $response.Content | ConvertFrom-Json
        if ($payload.PSObject.Properties.Name -contains 'value' -and $payload.value) {
            foreach ($item in @($payload.value)) { [void]$pullRequests.Add($item) }
        }

        if ($pullRequests.Count -ge 2) { break }

        $continuationToken = Get-AdoCoreContinuationToken -Response $response
    } while ($continuationToken)

    return ,([object[]]$pullRequests.ToArray())
}

function Resolve-AdoCorePullRequestId {
    param(
        [int]$PullRequestId,
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,
        [Parameter(Mandatory = $true)]
        [string]$SourceBranch
    )

    if ($PullRequestId -gt 0) { return $PullRequestId }
    $openPrs = Get-AdoCoreOpenPullRequestsForBranch -ApiBase $ApiBase -SourceBranch $SourceBranch
    if (@($openPrs).Count -eq 0) {
        throw "No active pull request found for branch '$SourceBranch'. Pass -PullRequestId explicitly."
    }
    if (@($openPrs).Count -gt 1) {
        throw "Multiple active pull requests found for branch '$SourceBranch'. Pass -PullRequestId explicitly."
    }
    return [int]$openPrs[0].pullRequestId
}

function Get-AdoCorePullRequest {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,
        [Parameter(Mandatory = $true)]
        [string]$ApiBase
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $ApiBase
    $uri = "$ApiBase/pullRequests/$PullRequestId`?api-version=7.0"
    return Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
}

function New-AdoCorePullRequest {
    param(
        [string]$WorkspaceRoot = '',
        [Parameter(Mandatory = $true)]
        [string]$SourceBranch,
        [Parameter(Mandatory = $true)]
        [string]$TargetBranch,
        [Parameter(Mandatory = $true)]
        [string]$Title,
        [string]$Description = '',
        [int[]]$WorkItemIds = @(),
        [switch]$Draft,
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    $sourceRef = if ($SourceBranch -like 'refs/heads/*') { $SourceBranch } else { "refs/heads/$SourceBranch" }
    $targetRef = if ($TargetBranch -like 'refs/heads/*') { $TargetBranch } else { "refs/heads/$TargetBranch" }

    $bodyObject = [ordered]@{
        sourceRefName = $sourceRef
        targetRefName = $targetRef
        title         = $Title
    }
    if ($Description) { $bodyObject['description'] = $Description }
    if ($Draft) { $bodyObject['isDraft'] = $true }
    if ($WorkItemIds -and @($WorkItemIds).Count -gt 0) {
        $bodyObject['workItemRefs'] = @($WorkItemIds | ForEach-Object { @{ id = [string]$_ } })
    }

    Assert-AdoCoreTrustedApiBase -ApiBase $endpoints.ApiBase
    $uri = "$($endpoints.ApiBase)/pullrequests?api-version=7.0"
    $body = $bodyObject | ConvertTo-Json -Depth 4 -Compress
    $pullRequest = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
        -ContentType 'application/json' -UseDefaultCredentials
    $pullRequestId = [int]$pullRequest.pullRequestId

    return [pscustomobject]@{
        PullRequestId = $pullRequestId
        Title         = [string]$pullRequest.title
        PrUrl         = (Get-AdoCorePullRequestWebUrl -Endpoints $endpoints -PullRequestId $pullRequestId)
        SourceBranch  = $SourceBranch
        TargetBranch  = $TargetBranch
        Endpoints     = $endpoints
        Created       = $true
    }
}

function New-AdoCorePullRequestThread {
    <#
    .SYNOPSIS
      Posts a general (non-file) comment on an Azure DevOps pull request discussion thread.
    .DESCRIPTION
      Generic ADO REST helper — callers own content and any workflow policy (e.g. CodeAnt
      retrigger strings, skip/recent checks, thread resolve). Does not auto-resolve threads.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $endpoints.ApiBase

    $uri = "$($endpoints.ApiBase)/pullRequests/$PullRequestId/threads?api-version=7.0"
    $body = @{
        comments = @(
            @{
                parentCommentId = 0
                content         = $Content
                commentType     = 1
            }
        )
        status = 1
    } | ConvertTo-Json -Depth 5

    $response = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
        -ContentType 'application/json' -UseDefaultCredentials

    $threadId = [int]$response.id
    $commentId = [int]$response.comments[0].id

    return [pscustomobject]@{
        PullRequestId = $PullRequestId
        ThreadId      = $threadId
        CommentId     = $commentId
        PrUrl         = (Get-AdoCorePullRequestWebUrl -Endpoints $endpoints -PullRequestId $PullRequestId)
        Content       = $Content
    }
}

function ConvertTo-AdoCoreThreadStatusCode {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Active', 'Fixed', 'WontFix', 'Closed', 'ByDesign')]
        [string]$Status
    )

    $statusMap = @{
        Active   = 1
        Fixed    = 2
        WontFix  = 3
        Closed   = 4
        ByDesign = 5
    }
    return [int]$statusMap[$Status]
}

function Get-AdoCorePullRequestThreads {
    <#
    .SYNOPSIS
      Lists Azure DevOps pull-request discussion threads (continuation-aware).
    .DESCRIPTION
      Generic ADO REST helper. Does not change thread status.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $endpoints.ApiBase

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

        $continuationToken = Get-AdoCoreContinuationToken -Response $response
    } while ($continuationToken)

    return , ([object[]]$threads.ToArray())
}

function Add-AdoCorePullRequestThreadComment {
    <#
    .SYNOPSIS
      Posts a reply on an Azure DevOps pull-request discussion thread.
    .DESCRIPTION
      Generic ADO REST helper. Does not set thread status.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [int]$ThreadId,

        [Parameter(Mandatory = $true)]
        [int]$ParentCommentId,

        [Parameter(Mandatory = $true)]
        [string]$Content,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $endpoints.ApiBase

    $Content = $Content -creplace '(\\\\n|\\n|`n)', [Environment]::NewLine

    $uri = "$($endpoints.ApiBase)/pullRequests/$PullRequestId/threads/$ThreadId/comments?api-version=7.0"
    $body = @{
        parentCommentId = $ParentCommentId
        content         = $Content
        commentType     = 1
    } | ConvertTo-Json

    $posted = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
        -ContentType 'application/json' -UseDefaultCredentials

    return [pscustomobject]@{
        PullRequestId = $PullRequestId
        ThreadId      = $ThreadId
        CommentId     = [int]$posted.id
        Content       = $Content
    }
}

function Set-AdoCorePullRequestThreadStatus {
    <#
    .SYNOPSIS
      Sets Azure DevOps pull-request discussion thread status.
    .DESCRIPTION
      Generic ADO REST helper. Callers own when to resolve; list and reply do not set status.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [int]$ThreadId,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Active', 'Fixed', 'WontFix', 'Closed', 'ByDesign')]
        [string]$Status,

        [string]$WorkspaceRoot = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $endpoints.ApiBase

    $uri = "$($endpoints.ApiBase)/pullRequests/$PullRequestId/threads/$ThreadId`?api-version=7.0"
    $body = @{ status = (ConvertTo-AdoCoreThreadStatusCode -Status $Status) } | ConvertTo-Json
    Invoke-RestMethod -Uri $uri -Method Patch -Body $body `
        -ContentType 'application/json' -UseDefaultCredentials | Out-Null
}

function Get-AdoCoreGitRepositoryMetadata {
    param(
        [Parameter(Mandatory = $true)]
        $Endpoints
    )

    $apiBase = [string]$Endpoints.ApiBase
    Assert-AdoCoreTrustedApiBase -ApiBase $apiBase
    $repository = Invoke-RestMethod -Uri "$apiBase`?api-version=7.0" -Method Get -UseDefaultCredentials
    return [pscustomobject]@{
        ProjectId    = [string]$repository.project.id
        RepositoryId = [string]$repository.id
        ApiBase      = $apiBase
    }
}

function Get-AdoCorePullRequestArtifactUrl {
    param(
        [Parameter(Mandatory = $true)]
        $PullRequest,
        [Parameter(Mandatory = $true)]
        $RepositoryMetadata,
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId
    )

    if ($PullRequest.PSObject.Properties.Name -contains 'artifactId' -and $PullRequest.artifactId) {
        return [string]$PullRequest.artifactId
    }
    return "vstfs:///Git/PullRequestId/$($RepositoryMetadata.ProjectId)%2F$($RepositoryMetadata.RepositoryId)%2F$PullRequestId"
}

function Get-AdoCorePullRequestCommitIds {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        # When set, emit each page as a string[] (no giant in-memory list). Otherwise return all IDs.
        [switch]$PassThruPages
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $ApiBase
    $commitIds = if ($PassThruPages) { $null } else { New-Object 'System.Collections.Generic.List[string]' }
    $continuationToken = $null
    do {
        $uri = "$ApiBase/pullRequests/$PullRequestId/commits?api-version=7.0"
        if ($continuationToken) {
            $uri = "$uri&continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        $response = Invoke-WebRequest -Uri $uri -Method Get -UseDefaultCredentials -UseBasicParsing
        $payload = $response.Content | ConvertFrom-Json
        $items = if ($payload.PSObject.Properties.Name -contains 'value' -and $payload.value) {
            @($payload.value)
        }
        elseif ($payload) {
            @($payload)
        }
        else {
            @()
        }
        $pageIds = New-Object 'System.Collections.Generic.List[string]'
        foreach ($item in $items) {
            if ($item.PSObject.Properties.Name -contains 'commitId' -and $item.commitId) {
                [void]$pageIds.Add([string]$item.commitId)
            }
        }

        if ($PassThruPages) {
            # Emit the page as one pipeline object (do not unroll the array).
            Write-Output -NoEnumerate ([string[]]$pageIds.ToArray())
        }
        else {
            foreach ($commitId in $pageIds) {
                [void]$commitIds.Add($commitId)
            }
        }

        $continuationToken = Get-AdoCoreContinuationToken -Response $response
    } while ($continuationToken)

    if ($PassThruPages) { return }
    return [string[]]$commitIds.ToArray()
}

function New-AdoCoreArtifactLinkPatchOperation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArtifactUrl,
        [Parameter(Mandatory = $true)]
        [string]$LinkName
    )

    return [pscustomobject]@{
        op    = 'add'
        path  = '/relations/-'
        value = [pscustomobject]@{
            rel        = 'ArtifactLink'
            url        = $ArtifactUrl
            attributes = @{ name = $LinkName }
        }
    }
}

function Add-AdoCoreWorkItemArtifactLinks {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WorkItemId,
        [Parameter(Mandatory = $true)]
        [string]$WitApiBase,
        [Parameter(Mandatory = $true)]
        [object[]]$Links,
        # Optional caller-owned server-existing URL set; when set, skip the relations GET.
        # Not grown with newly linked URLs (per-batch dedupe uses $requestedUrls instead).
        [System.Collections.Generic.HashSet[string]]$ExistingUrls = $null,
        [ValidateRange(0, 1)]
        [int]$DuplicateRetryCount = 0
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $WitApiBase -Name 'WitApiBase'
    $uri = "$WitApiBase/workitems/$WorkItemId`?api-version=7.0"
    $existingUri = "$WitApiBase/workitems/$WorkItemId`?`$expand=relations&api-version=7.0"

    $urls = $ExistingUrls
    if ($null -eq $urls) {
        $urls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        $workItem = Invoke-RestMethod -Uri $existingUri -Method Get -UseDefaultCredentials
        $existingRelations = if ($workItem.PSObject.Properties.Name -contains 'relations') { @($workItem.relations) } else { @() }
        foreach ($relation in $existingRelations) {
            if ($relation.url) { [void]$urls.Add([string]$relation.url) }
        }
    }

    $requestedUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $operations = New-Object 'System.Collections.Generic.List[object]'
    foreach ($link in @($Links)) {
        $artifactUrl = [string]$link.ArtifactUrl
        if (-not $artifactUrl -or -not $requestedUrls.Add($artifactUrl) -or $urls.Contains($artifactUrl)) {
            continue
        }
        [void]$operations.Add((New-AdoCoreArtifactLinkPatchOperation `
                -ArtifactUrl $artifactUrl -LinkName ([string]$link.LinkName)))
    }

    if ($operations.Count -eq 0) { return $true }

    $operationArray = [object[]]$operations
    $body = ConvertTo-Json -InputObject $operationArray -Depth 6 -Compress
    try {
        Invoke-RestMethod -Uri $uri -Method Patch -Body $body `
            -ContentType 'application/json-patch+json' -UseDefaultCredentials | Out-Null
        return $true
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $message = "$message $($_.ErrorDetails.Message)"
        }
        if ($message -match 'already exists|RelationAlreadyExists|TF201036|relation already|duplicate') {
            $refreshed = Invoke-RestMethod -Uri $existingUri -Method Get -UseDefaultCredentials
            $refreshedRelations = if ($refreshed.PSObject.Properties.Name -contains 'relations') { @($refreshed.relations) } else { @() }
            $urls.Clear()
            foreach ($relation in $refreshedRelations) {
                if ($relation.url) { [void]$urls.Add([string]$relation.url) }
            }
            $missing = @($Links | Where-Object { -not $urls.Contains([string]$_.ArtifactUrl) })
            if ($missing.Count -eq 0) { return $true }
            if ($DuplicateRetryCount -lt 1) {
                return Add-AdoCoreWorkItemArtifactLinks -WorkItemId $WorkItemId `
                    -WitApiBase $WitApiBase -Links $missing -ExistingUrls $urls `
                    -DuplicateRetryCount ($DuplicateRetryCount + 1)
            }
        }
        throw
    }
}

function Add-AdoCoreWorkItemArtifactLink {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WorkItemId,
        [Parameter(Mandatory = $true)]
        [string]$WitApiBase,
        [Parameter(Mandatory = $true)]
        [string]$ArtifactUrl,
        [Parameter(Mandatory = $true)]
        [string]$LinkName
    )

    return Add-AdoCoreWorkItemArtifactLinks -WorkItemId $WorkItemId -WitApiBase $WitApiBase `
        -Links @([pscustomobject]@{ ArtifactUrl = $ArtifactUrl; LinkName = $LinkName })
}

function Add-AdoCoreWorkItemAttachments {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WorkItemId,
        [Parameter(Mandatory = $true)]
        [string]$WitApiBase,
        [Parameter(Mandatory = $true)]
        [string[]]$FilePaths,
        [string]$Comment = ''
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $WitApiBase -Name 'WitApiBase'

    $resolvedPaths = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in @($FilePaths)) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Attachment file not found: $path"
        }
        [void]$resolvedPaths.Add($path)
    }
    if ($resolvedPaths.Count -eq 0) { return $true }

    $existingUri = "$WitApiBase/workitems/$WorkItemId`?`$expand=relations&api-version=7.0"
    $workItem = Invoke-RestMethod -Uri $existingUri -Method Get -UseDefaultCredentials
    $existingNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $existingRelations = if ($workItem.PSObject.Properties.Name -contains 'relations') { @($workItem.relations) } else { @() }
    foreach ($relation in $existingRelations) {
        if ($relation.rel -ne 'AttachedFile') { continue }
        $existingName = ''
        if ($relation.attributes -and $relation.attributes.name) {
            $existingName = [string]$relation.attributes.name
        }
        if ($existingName) { [void]$existingNames.Add($existingName) }
    }

    $attributes = @{ }
    if (-not [string]::IsNullOrWhiteSpace($Comment)) {
        $attributes.comment = $Comment
    }

    $operations = New-Object 'System.Collections.Generic.List[object]'
    $requestedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $resolvedPaths) {
        $fileName = [IO.Path]::GetFileName($path)
        if (-not $requestedNames.Add($fileName) -or $existingNames.Contains($fileName)) {
            continue
        }

        $uploadUri = "$WitApiBase/attachments?fileName=$([uri]::EscapeDataString($fileName))&api-version=7.0"
        $uploadResponse = Invoke-WebRequest -Uri $uploadUri -Method Post -InFile $path `
            -ContentType 'application/octet-stream' -UseDefaultCredentials -UseBasicParsing
        $upload = $uploadResponse.Content | ConvertFrom-Json
        if (-not $upload.url) {
            throw "Attachment upload returned no url for $fileName"
        }

        [void]$operations.Add([pscustomobject]@{
                op    = 'add'
                path  = '/relations/-'
                value = [pscustomobject]@{
                    rel        = 'AttachedFile'
                    url        = [string]$upload.url
                    attributes = $attributes
                }
            })
    }

    if ($operations.Count -eq 0) { return $true }

    $operationArray = [object[]]$operations.ToArray()
    $body = ConvertTo-Json -InputObject $operationArray -Depth 6 -Compress
    $patchUri = "$WitApiBase/workitems/$WorkItemId`?api-version=7.0"
    Invoke-RestMethod -Uri $patchUri -Method Patch -Body $body `
        -ContentType 'application/json-patch+json' -UseDefaultCredentials | Out-Null
    return $true
}

function Add-AdoCoreWorkItemAttachment {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WorkItemId,
        [Parameter(Mandatory = $true)]
        [string]$WitApiBase,
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [string]$Comment = ''
    )

    return Add-AdoCoreWorkItemAttachments -WorkItemId $WorkItemId -WitApiBase $WitApiBase `
        -FilePaths @($FilePath) -Comment $Comment
}

function ConvertTo-AdoCoreWorkItemFieldRefName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Field
    )

    $trimmed = $Field.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw 'Work item field name is empty.'
    }
    if ($trimmed -like '/fields/*') {
        return $trimmed.Substring('/fields/'.Length)
    }
    if ($trimmed.StartsWith('/')) {
        throw "Unsupported work item patch path '$trimmed'. Use a field ref name (e.g. System.Title) or /fields/<ref>."
    }
    return $trimmed
}

function New-AdoCoreWorkItem {
    <#
    .SYNOPSIS
      Create a work item via WIT REST (JSON Patch). Prefer this over hand-rolled create URIs.
    .DESCRIPTION
      Field values are passed through as-is — callers own HTML conversion and workflow
      defaults (area/iteration/tags/state). Optional -PullRequestId links via
      Link-AdoCoreWorkItemToPullRequest after create.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$WorkItemType = 'User Story',
        [string]$Description = '',
        [string]$AcceptanceCriteria = '',
        [hashtable]$Fields = @{},
        [switch]$AssignToMe,
        [ValidateRange(0, [int]::MaxValue)]
        [int]$PullRequestId = 0,
        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if ([string]::IsNullOrWhiteSpace($Title)) {
        throw 'Title is required.'
    }
    if ([string]::IsNullOrWhiteSpace($WorkItemType)) {
        throw 'WorkItemType is required.'
    }

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    if (-not [string]::IsNullOrWhiteSpace($WitApiBase)) {
        if ($base -notmatch '^(https?://[^/]+)/tfs/([^/]+)/([^/]+)/_apis/wit') {
            throw "Unsupported WitApiBase for endpoint derivation: $base"
        }
        $endpoints = @{
            ServerUrl  = $Matches[1]
            Collection = [Uri]::UnescapeDataString([string]$Matches[2])
            Project    = [Uri]::UnescapeDataString([string]$Matches[3])
            Repository = $Repository
            ApiBase    = $null
        }
    }
    else {
        $wit = Get-AdoCoreWitApiBase -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
            -Project $Project -Repository $Repository -ServerUrl $ServerUrl
        $endpoints = $wit.Endpoints
        if ($Repository) { $endpoints.Repository = $Repository }
    }

    # Soft-resolve Repository from git before the pre-create PR check (WitApiBase path skips discovery).
    if ($PullRequestId -gt 0 -and [string]::IsNullOrWhiteSpace([string]$endpoints.Repository)) {
        try {
            $defaults = Get-AdoCoreDefaultsFromGitRemote -WorkspaceRoot $WorkspaceRoot
            if (-not [string]::IsNullOrWhiteSpace([string]$defaults.Repository)) {
                $endpoints.Repository = [string]$defaults.Repository
            }
        }
        catch {
            # Soft-fail: leave Repository empty; prerequisite check below still throws if needed.
        }
    }
    if ($PullRequestId -gt 0 -and
        -not [string]::IsNullOrWhiteSpace([string]$endpoints.Repository) -and
        [string]::IsNullOrWhiteSpace([string]$endpoints.ApiBase)) {
        $endpoints.ApiBase = Get-AdoCoreGitApiBase -ServerUrl $endpoints.ServerUrl `
            -Collection $endpoints.Collection -Project $endpoints.Project `
            -Repository $endpoints.Repository
    }
    if ($PullRequestId -gt 0 -and [string]::IsNullOrWhiteSpace([string]$endpoints.Repository)) {
        throw 'PullRequestId requires a resolvable Repository (pass -Repository or run inside a git repo with remote.origin.url).'
    }

    $typeSegment = '$' + [uri]::EscapeDataString($WorkItemType.Trim())
    $uri = "$base/workitems/${typeSegment}?api-version=7.0"

    $patch = New-Object System.Collections.Generic.List[object]
    $claimed = @{}
    $addField = {
        param([string]$RefName, $Value)
        if ($null -eq $Value) { return }
        if ($claimed.ContainsKey($RefName)) { return }
        $claimed[$RefName] = $true
        [void]$patch.Add([pscustomobject]@{
                op    = 'add'
                path  = "/fields/$RefName"
                value = $Value
            })
    }

    & $addField 'System.Title' $Title
    if (-not [string]::IsNullOrWhiteSpace($Description)) {
        & $addField 'System.Description' $Description
    }
    if (-not [string]::IsNullOrWhiteSpace($AcceptanceCriteria)) {
        & $addField 'Microsoft.VSTS.Common.AcceptanceCriteria' $AcceptanceCriteria
    }

    foreach ($key in @($Fields.Keys)) {
        $refName = ConvertTo-AdoCoreWorkItemFieldRefName -Field ([string]$key)
        if ($refName -eq 'System.Title') { continue }
        if ($refName -eq 'System.Description' -and -not [string]::IsNullOrWhiteSpace($Description)) { continue }
        if ($refName -eq 'Microsoft.VSTS.Common.AcceptanceCriteria' -and -not [string]::IsNullOrWhiteSpace($AcceptanceCriteria)) { continue }
        if ($refName -eq 'System.AssignedTo' -and $AssignToMe) { continue }
        & $addField $refName $Fields[$key]
    }

    if ($AssignToMe) {
        $user = Get-AdoCoreAuthenticatedUser -WorkspaceRoot $WorkspaceRoot `
            -Collection ([string]$endpoints.Collection) -ServerUrl ([string]$endpoints.ServerUrl)
        $assignedTo = Get-AdoCoreAssignedToFieldValue -User $user
        if (-not $assignedTo) {
            throw 'Cannot assign work item: ADO connectionData did not return a usable user identity.'
        }
        & $addField 'System.AssignedTo' $assignedTo
    }

    $body = @($patch.ToArray()) | ConvertTo-Json -Depth 5 -Compress
    if ($patch.Count -eq 1 -and -not $body.StartsWith('[')) {
        $body = "[$body]"
    }

    $workItem = Invoke-RestMethod -Uri $uri -Method Post -Body $body `
        -ContentType 'application/json-patch+json' -UseDefaultCredentials
    $workItemId = [int]$workItem.id

    $linkResult = @{
        LinkedToPr        = $false
        LinkedCommitCount = 0
        CommitCount       = 0
        LinkWarning       = ''
    }
    $prUrl = ''
    if ($PullRequestId -gt 0) {
        try {
            if ([string]::IsNullOrWhiteSpace([string]$endpoints.ApiBase)) {
                $endpoints.ApiBase = Get-AdoCoreGitApiBase -ServerUrl $endpoints.ServerUrl `
                    -Collection $endpoints.Collection -Project $endpoints.Project `
                    -Repository $endpoints.Repository
            }
            $linkResult = Link-AdoCoreWorkItemToPullRequest -WorkItemId $workItemId `
                -PullRequestId $PullRequestId -Endpoints $endpoints -WitApiBase $base
            $prUrl = Get-AdoCorePullRequestWebUrl -Endpoints $endpoints -PullRequestId $PullRequestId
        }
        catch {
            $linkResult = @{
                LinkedToPr        = $false
                LinkedCommitCount = 0
                CommitCount       = 0
                LinkWarning       = "PR link failed after work item create: $($_.Exception.Message)"
            }
            $prUrl = ''
        }
    }

    return [pscustomobject]@{
        WorkItemId        = $workItemId
        Title             = [string]$workItem.fields.'System.Title'
        WebUrl            = (Get-AdoCoreWorkItemWebUrl -WorkItemId $workItemId -Endpoints $endpoints)
        WorkItemType      = $WorkItemType.Trim()
        PullRequestId     = $PullRequestId
        PrUrl             = $prUrl
        LinkedToPr        = [bool]$linkResult.LinkedToPr
        LinkedCommitCount = [int]$linkResult.LinkedCommitCount
        CommitCount       = [int]$linkResult.CommitCount
        LinkWarning       = if ($linkResult.LinkWarning) { [string]$linkResult.LinkWarning } else { '' }
        AssignedToMe      = $AssignToMe.IsPresent
        Endpoints         = $endpoints
        WitApiBase        = $base
    }
}

function Update-AdoCoreWorkItem {
    <#
    .SYNOPSIS
      Patch work item fields via WIT REST (JSON Patch add). Prefer this over hand-rolled update URIs.
    .DESCRIPTION
      Field values are passed through as-is — callers own HTML conversion. Provide at least one
      of -Title, -Description, -AcceptanceCriteria, -Fields, or -AssignToMe.
      For Description/AcceptanceCriteria: omit or $null skips the field; empty string clears it.
      For Title: omit or $null skips; empty string is rejected (ADO requires System.Title).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        # Untyped so $null stays omit (typed [string] coerces $null to '').
        $Title = $null,
        $Description = $null,
        $AcceptanceCriteria = $null,
        [hashtable]$Fields = @{},
        [switch]$AssignToMe,
        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $hasFields = $Fields -and @($Fields.Keys).Count -gt 0
    if ($null -eq $Title -and $null -eq $Description -and $null -eq $AcceptanceCriteria -and -not $hasFields -and -not $AssignToMe) {
        throw 'Provide -Title, -Description, -AcceptanceCriteria, -Fields, and/or -AssignToMe to update.'
    }
    if ($null -ne $Title -and [string]::IsNullOrWhiteSpace([string]$Title)) {
        throw 'System.Title cannot be cleared; omit -Title to leave it unchanged.'
    }

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    if (-not [string]::IsNullOrWhiteSpace($WitApiBase)) {
        if ($base -notmatch '^(https?://[^/]+)/tfs/([^/]+)/([^/]+)/_apis/wit') {
            throw "Unsupported WitApiBase for endpoint derivation: $base"
        }
        $endpoints = @{
            ServerUrl  = $Matches[1]
            Collection = [Uri]::UnescapeDataString([string]$Matches[2])
            Project    = [Uri]::UnescapeDataString([string]$Matches[3])
            Repository = $Repository
            ApiBase    = $null
        }
    }
    else {
        $wit = Get-AdoCoreWitApiBase -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
            -Project $Project -Repository $Repository -ServerUrl $ServerUrl
        $endpoints = $wit.Endpoints
        if ($Repository) { $endpoints.Repository = $Repository }
    }

    $uri = "$base/workitems/$WorkItemId`?api-version=7.0"
    $patch = New-Object System.Collections.Generic.List[object]
    $claimed = @{}
    $addField = {
        param([string]$RefName, $Value)
        if ($null -eq $Value) { return }
        if ($claimed.ContainsKey($RefName)) { return }
        $claimed[$RefName] = $true
        [void]$patch.Add([pscustomobject]@{
                op    = 'add'
                path  = "/fields/$RefName"
                value = $Value
            })
    }

    if ($null -ne $Title) {
        & $addField 'System.Title' $Title
    }
    if ($null -ne $Description) {
        & $addField 'System.Description' $Description
    }
    if ($null -ne $AcceptanceCriteria) {
        & $addField 'Microsoft.VSTS.Common.AcceptanceCriteria' $AcceptanceCriteria
    }

    foreach ($key in @($Fields.Keys)) {
        $refName = ConvertTo-AdoCoreWorkItemFieldRefName -Field ([string]$key)
        if ($refName -eq 'System.Title' -and $null -ne $Title) { continue }
        if ($refName -eq 'System.Description' -and $null -ne $Description) { continue }
        if ($refName -eq 'Microsoft.VSTS.Common.AcceptanceCriteria' -and $null -ne $AcceptanceCriteria) { continue }
        if ($refName -eq 'System.AssignedTo' -and $AssignToMe) { continue }
        & $addField $refName $Fields[$key]
    }

    if ($AssignToMe) {
        $user = Get-AdoCoreAuthenticatedUser -WorkspaceRoot $WorkspaceRoot `
            -Collection ([string]$endpoints.Collection) -ServerUrl ([string]$endpoints.ServerUrl)
        $assignedTo = Get-AdoCoreAssignedToFieldValue -User $user
        if (-not $assignedTo) {
            throw 'Cannot assign work item: ADO connectionData did not return a usable user identity.'
        }
        & $addField 'System.AssignedTo' $assignedTo
    }

    if ($patch.Count -lt 1) {
        throw 'No work item field updates were produced.'
    }

    $body = @($patch.ToArray()) | ConvertTo-Json -Depth 5 -Compress
    if ($patch.Count -eq 1 -and -not $body.StartsWith('[')) {
        $body = "[$body]"
    }

    $workItem = Invoke-RestMethod -Uri $uri -Method Patch -Body $body `
        -ContentType 'application/json-patch+json' -UseDefaultCredentials

    return [pscustomobject]@{
        WorkItemId   = $WorkItemId
        Title        = [string]$workItem.fields.'System.Title'
        WebUrl       = (Get-AdoCoreWorkItemWebUrl -WorkItemId $WorkItemId -Endpoints $endpoints)
        AssignedToMe = $AssignToMe.IsPresent
        Endpoints    = $endpoints
        WitApiBase   = $base
    }
}

function Link-AdoCoreWorkItemToPullRequest {
    param(
        [Parameter(Mandatory = $true)]
        [int]$WorkItemId,
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,
        [Parameter(Mandatory = $true)]
        $Endpoints,
        [Parameter(Mandatory = $true)]
        [string]$WitApiBase
    )

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $metadata = Get-AdoCoreGitRepositoryMetadata -Endpoints $Endpoints
    $pullRequest = Get-AdoCorePullRequest -PullRequestId $PullRequestId -ApiBase $metadata.ApiBase
    $prArtifactUrl = Get-AdoCorePullRequestArtifactUrl -PullRequest $pullRequest `
        -RepositoryMetadata $metadata -PullRequestId $PullRequestId

    $linkedToPr = $false
    $linkedCommitCount = 0
    $commitCount = 0
    $batchSize = 100
    $pending = New-Object 'System.Collections.Generic.List[object]'
    $existingUrls = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    try {
        Assert-AdoCoreTrustedApiBase -ApiBase $WitApiBase -Name 'WitApiBase'
        $existingUri = "$WitApiBase/workitems/$WorkItemId`?`$expand=relations&api-version=7.0"
        $existingWorkItem = Invoke-RestMethod -Uri $existingUri -Method Get -UseDefaultCredentials
        $existingRelations = if ($existingWorkItem.PSObject.Properties.Name -contains 'relations') { @($existingWorkItem.relations) } else { @() }
        foreach ($relation in $existingRelations) {
            if ($relation.url) { [void]$existingUrls.Add([string]$relation.url) }
        }

        [void](Add-AdoCoreWorkItemArtifactLinks -WorkItemId $WorkItemId -WitApiBase $WitApiBase -Links @(
                [pscustomobject]@{ ArtifactUrl = $prArtifactUrl; LinkName = 'Pull Request' }
            ) -ExistingUrls $existingUrls)
        $linkedToPr = $true

        Get-AdoCorePullRequestCommitIds -ApiBase $metadata.ApiBase -PullRequestId $PullRequestId -PassThruPages |
            ForEach-Object {
                foreach ($commitId in @($_)) {
                    if ([string]::IsNullOrWhiteSpace($commitId)) { continue }
                    $commitCount++
                    $commitArtifactUrl = "vstfs:///Git/Commit/$($metadata.ProjectId)%2F$($metadata.RepositoryId)%2F$commitId"
                    [void]$pending.Add([pscustomobject]@{
                            ArtifactUrl = $commitArtifactUrl
                            LinkName    = 'Fixed in Commit'
                        })
                    if ($pending.Count -ge $batchSize) {
                        $linkBatch = [object[]]$pending.ToArray()
                        [void](Add-AdoCoreWorkItemArtifactLinks -WorkItemId $WorkItemId -WitApiBase $WitApiBase `
                                -Links $linkBatch -ExistingUrls $existingUrls)
                        $linkedCommitCount += $pending.Count
                        $pending.Clear()
                    }
                }
            }

        if ($pending.Count -gt 0) {
            $linkBatch = [object[]]$pending.ToArray()
            [void](Add-AdoCoreWorkItemArtifactLinks -WorkItemId $WorkItemId -WitApiBase $WitApiBase `
                    -Links $linkBatch -ExistingUrls $existingUrls)
            $linkedCommitCount += $pending.Count
            $pending.Clear()
        }
    }
    catch {
        [void]$warnings.Add("PR and commit links failed after linking $linkedCommitCount commit(s): $($_.Exception.Message)")
    }

    $linkWarning = if ($warnings.Count -gt 0) { $warnings -join ' ' } else { '' }
    if (-not $linkedToPr -and $linkedCommitCount -eq 0 -and -not $linkWarning) {
        $linkWarning = 'Work item was not linked to the pull request or its commits. Link it manually.'
    }

    return @{
        LinkedToPr        = $linkedToPr
        LinkedCommitCount = $linkedCommitCount
        CommitCount       = $commitCount
        LinkWarning       = $linkWarning
    }
}

function Escape-AdoCoreWiqlLiteral {
    param([string]$Value)

    if ([string]::IsNullOrEmpty($Value)) { return '' }
    return $Value.Replace("'", "''")
}

function Invoke-AdoCoreWiql {
    param(
        [Parameter(Mandatory = $true)]
        [string]$WitApiBase,

        [Parameter(Mandatory = $true)]
        [string]$Query
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $WitApiBase -Name 'WitApiBase'
    $uri = "$WitApiBase/wiql?api-version=7.0"
    $body = (@{ query = $Query } | ConvertTo-Json -Compress)
    return Invoke-RestMethod -Uri $uri -Method Post -Body $body `
        -ContentType 'application/json' -UseDefaultCredentials
}
