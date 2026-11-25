#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:AdoCoreLibraryVersion = [version]'0.11.0'

# System / derived fields never copied by Clone-AdoCoreWorkItem.
$script:AdoCoreCloneAlwaysSkipFieldRefNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
@(
    'System.Id'
    'System.Rev'
    'System.RevisedDate'
    'System.Watermark'
    'System.CreatedBy'
    'System.CreatedDate'
    'System.ChangedBy'
    'System.ChangedDate'
    'System.AuthorizedAs'
    'System.AuthorizedDate'
    'System.PersonId'
    'System.CommentCount'
    'System.AreaId'
    'System.IterationId'
    'System.NodeName'
    'System.TeamProject'
    'System.WorkItemType'
    'System.History'
    'System.Parent'
    'System.ExternalLinkCount'
    'System.RelatedLinkCount'
    'System.RemoteLinkCount'
    'System.HyperLinkCount'
    'System.AttachedFileCount'
    'Microsoft.VSTS.Common.ActivatedBy'
    'Microsoft.VSTS.Common.ActivatedDate'
    'Microsoft.VSTS.Common.StateChangeDate'
    'Microsoft.VSTS.Common.ResolvedBy'
    'Microsoft.VSTS.Common.ResolvedDate'
    'Microsoft.VSTS.Common.ClosedBy'
    'Microsoft.VSTS.Common.ClosedDate'
    'Microsoft.VSTS.Common.ResolvedReason'
) | ForEach-Object { [void]$script:AdoCoreCloneAlwaysSkipFieldRefNames.Add($_) }

# Version / build fields: blank on clone by default; -Fields may still set them.
$script:AdoCoreCloneVersionBuildFieldRefNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
@(
    'Microsoft.VSTS.Build.FoundIn'
    'Microsoft.VSTS.Build.IntegrationBuild'
    'Custom.FixBuild'
    'Custom.Plannedreleaseversion'
    'Custom.ReleaseCandidateBuild'
) | ForEach-Object { [void]$script:AdoCoreCloneVersionBuildFieldRefNames.Add($_) }

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

function Assert-AdoCoreTrustedDownloadUrl {
    <#
    .SYNOPSIS
      Validate an absolute HTTPS URL against the trusted ADO host allowlist before authenticated download.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Url,
        [string]$Name = 'DownloadUrl'
    )

    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "ADO $Name is empty."
    }

    $uri = $null
    if (-not [Uri]::TryCreate($Url.Trim(), [UriKind]::Absolute, [ref]$uri)) {
        throw "ADO $Name is not a valid absolute URI: $Url"
    }
    if ($uri.Scheme -ne 'https') {
        throw "ADO $Name must use HTTPS (got '$($uri.Scheme)'): $Url"
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

function ConvertTo-AdoCoreHtmlText {
    <#
    .SYNOPSIS
      HTML-encode text before embedding in a work-item discussion comment (private helper).
    #>
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Value)
}

function ConvertTo-AdoCoreUtf8RequestBody {
    <#
    .SYNOPSIS
      Encode a JSON string as UTF-8 bytes for Invoke-RestMethod (Windows PowerShell string bodies mangle £/non-ASCII).
    .NOTES
      Returns a true byte[] (unary comma) so PowerShell does not unwrap it to Object[].
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Json
    )

    return , [System.Text.Encoding]::UTF8.GetBytes($Json)
}

function Get-AdoCoreJsonContentType {
    param(
        [Parameter(Mandatory = $true)]
        [string]$MediaType
    )

    $trimmed = $MediaType.Trim()
    if ($trimmed -match '(?i)charset=') { return $trimmed }
    return "$trimmed; charset=utf-8"
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

function Get-AdoCoreBuildApiBase {
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
            # Repository / git ApiBase are optional for Build URL construction.
        }
    }

    $ServerUrl = Normalize-AdoCoreServerUrl -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedServerUrl -ServerUrl $ServerUrl
    if ([string]::IsNullOrWhiteSpace($Collection)) {
        throw 'ADO Collection is required for Build.'
    }
    if ([string]::IsNullOrWhiteSpace($Project)) {
        throw 'ADO Project is required for Build.'
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
        Endpoints    = $endpoints
        BuildApiBase = "$base/tfs/$collectionSegment/$projectSegment/_apis/build"
    }
}

function Resolve-AdoCoreBuildApiBaseValue {
    param(
        [string]$WorkspaceRoot = '',
        [string]$BuildApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($BuildApiBase)) {
        Assert-AdoCoreTrustedApiBase -ApiBase $BuildApiBase -Name 'BuildApiBase'
        return $BuildApiBase.TrimEnd('/')
    }

    $resolved = Get-AdoCoreBuildApiBase -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    return [string]$resolved.BuildApiBase
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

function Get-AdoCoreWorkItems {
    <#
    .SYNOPSIS
      GET work items by ids (batch, max 200). Prefer this over hand-rolled URIs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [int[]]$WorkItemIds,

        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Expand = '',
        [ValidateSet('', 'Fail', 'Omit')]
        [string]$ErrorPolicy = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $ids = @($WorkItemIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($ids.Count -eq 0) {
        throw 'WorkItemIds must contain at least one positive id.'
    }
    if ($ids.Count -gt 200) {
        throw "WorkItemIds exceeds ADO batch limit of 200 (got $($ids.Count))."
    }

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    $queryParts = @(
        "ids=$([string]::Join(',', $ids))",
        'api-version=7.0'
    )
    if (-not [string]::IsNullOrWhiteSpace($Expand)) {
        $queryParts = @("`$expand=$([uri]::EscapeDataString($Expand))") + $queryParts
    }
    if (-not [string]::IsNullOrWhiteSpace($ErrorPolicy)) {
        $queryParts += "errorPolicy=$([uri]::EscapeDataString($ErrorPolicy))"
    }

    $uri = "$base/workitems?$([string]::Join('&', $queryParts))"
    $response = Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
    $items = @()
    if ($response -and ($response.PSObject.Properties.Name -contains 'value') -and $response.value) {
        $items = @($response.value)
    }
    return [pscustomobject]@{
        count     = $items.Count
        workItems = $items
    }
}

function Get-AdoCoreWorkItemRevisions {
    <#
    .SYNOPSIS
      GET work-item revisions via WIT REST (paged, bounded). Prefer this over hand-rolled URIs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Expand = '',
        [ValidateRange(1, 5000)]
        [int]$MaxRevisions = 500,
        [ValidateRange(1, 200)]
        [int]$PageSize = 200,
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    $revisions = New-Object 'System.Collections.Generic.List[object]'
    $truncated = $false
    $skip = 0
    $maxPages = 40
    $pageCount = 0
    do {
        if ($pageCount -ge $maxPages) {
            $truncated = $true
            break
        }
        $pageCount++

        $remaining = $MaxRevisions - $revisions.Count
        if ($remaining -le 0) {
            $truncated = $true
            break
        }
        $top = [Math]::Min($PageSize, $remaining)
        $queryParts = @(
            "`$top=$top",
            "`$skip=$skip",
            'api-version=7.0'
        )
        if (-not [string]::IsNullOrWhiteSpace($Expand)) {
            $queryParts = @("`$expand=$([uri]::EscapeDataString($Expand))") + $queryParts
        }
        $uri = "$base/workitems/$WorkItemId/revisions?$([string]::Join('&', $queryParts))"
        $response = Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
        $page = @()
        if ($response -and ($response.PSObject.Properties.Name -contains 'value') -and $response.value) {
            $page = @($response.value)
        }

        if ($page.Count -eq 0) {
            break
        }

        foreach ($item in $page) {
            if ($revisions.Count -ge $MaxRevisions) {
                $truncated = $true
                break
            }
            [void]$revisions.Add($item)
        }

        if ($truncated) {
            break
        }

        $skip += $page.Count
        if ($page.Count -lt $top) {
            break
        }
    } while ($true)

    return [pscustomobject]@{
        count      = $revisions.Count
        revisions  = @($revisions.ToArray())
        truncated  = $truncated
    }
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

function Add-AdoCoreWorkItemComment {
    <#
    .SYNOPSIS
      POST a work-item discussion comment via WIT comments API. Prefer this over hand-rolled URIs.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        [Parameter(Mandatory = $true)]
        [string]$Text,

        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw 'Text is required.'
    }

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    $uri = "$base/workitems/$WorkItemId/comments?api-version=7.0-preview.3"
    $body = (@{ text = $Text } | ConvertTo-Json -Compress)
    return Invoke-RestMethod -Uri $uri -Method Post -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json') -UseDefaultCredentials
}

function Get-AdoCoreBuildDefinition {
    <#
    .SYNOPSIS
      GET a build definition by id, or resolve by exact name (case-insensitive). Prefer this over hand-rolled URIs.
    #>
    param(
        [ValidateRange(0, [int]::MaxValue)]
        [int]$DefinitionId = 0,

        [string]$Name = '',
        [string]$WorkspaceRoot = '',
        [string]$BuildApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $hasId = $DefinitionId -gt 0
    $hasName = -not [string]::IsNullOrWhiteSpace($Name)
    if (-not $hasId -and -not $hasName) {
        throw 'Provide -DefinitionId and/or -Name.'
    }

    $base = Resolve-AdoCoreBuildApiBaseValue -WorkspaceRoot $WorkspaceRoot -BuildApiBase $BuildApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'BuildApiBase'

    if ($hasId) {
        $uri = "$base/definitions/$DefinitionId`?api-version=7.0"
        return Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
    }

    $encodedName = [uri]::EscapeDataString($Name.Trim())
    $baseListUri = "$base/definitions?name=$encodedName&api-version=7.0"
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    $continuationToken = $null
    $maxPages = 40
    $pageCount = 0
    do {
        if ($pageCount -ge $maxPages) {
            throw "Build definition name lookup for '$Name' exceeded $maxPages pages. Pass -DefinitionId."
        }
        $pageCount++

        $listUri = $baseListUri
        if ($continuationToken) {
            $listUri = "$listUri&continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        $webResponse = Invoke-WebRequest -Uri $listUri -Method Get -UseDefaultCredentials -UseBasicParsing
        $listResponse = $webResponse.Content | ConvertFrom-Json
        $page = @()
        if ($listResponse -and ($listResponse.PSObject.Properties.Name -contains 'value') -and $listResponse.value) {
            $page = @($listResponse.value)
        }
        foreach ($item in $page) {
            [void]$candidates.Add($item)
        }

        $continuationToken = Get-AdoCoreContinuationToken -Response $webResponse
    } while ($continuationToken)

    $exact = @($candidates | Where-Object {
            $_.PSObject.Properties.Name -contains 'name' -and
            [string]::Equals([string]$_.name, $Name.Trim(), [StringComparison]::OrdinalIgnoreCase)
        })
    if ($exact.Count -eq 0) {
        throw "Build definition not found by name: $Name"
    }
    if ($exact.Count -gt 1) {
        $ids = @($exact | ForEach-Object { $_.id }) -join ', '
        throw "Multiple build definitions match name '$Name' (ids: $ids). Pass -DefinitionId."
    }

    $resolvedId = [int]$exact[0].id
    $uri = "$base/definitions/$resolvedId`?api-version=7.0"
    return Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
}

function Get-AdoCoreBuilds {
    <#
    .SYNOPSIS
      List builds for definition(s) with optional status/result/top/order filters. Prefer this over hand-rolled URIs.
    #>
    param(
        [int[]]$DefinitionIds = @(),

        [string]$WorkspaceRoot = '',
        [string]$BuildApiBase = '',
        [string]$StatusFilter = '',
        [string]$ResultFilter = '',
        [ValidateSet(
            '',
            'finishTimeDescending',
            'finishTimeAscending',
            'queueTimeDescending',
            'queueTimeAscending',
            'startTimeDescending',
            'startTimeAscending'
        )]
        [string]$QueryOrder = 'finishTimeDescending',
        [ValidateRange(1, 5000)]
        [int]$Top = 50,
        [string]$BranchName = '',
        [string]$MinTime = '',
        [string]$MaxTime = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $definitionIdList = @($DefinitionIds | Where-Object { $_ -gt 0 } | Select-Object -Unique)
    if ($definitionIdList.Count -eq 0) {
        throw 'DefinitionIds must contain at least one positive definition id.'
    }

    $base = Resolve-AdoCoreBuildApiBaseValue -WorkspaceRoot $WorkspaceRoot -BuildApiBase $BuildApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'BuildApiBase'

    $queryParts = @(
        "definitions=$([string]::Join(',', $definitionIdList))",
        "`$top=$Top",
        'api-version=7.0'
    )
    if (-not [string]::IsNullOrWhiteSpace($QueryOrder)) {
        $queryParts += "queryOrder=$([uri]::EscapeDataString($QueryOrder))"
    }
    if (-not [string]::IsNullOrWhiteSpace($StatusFilter)) {
        $queryParts += "statusFilter=$([uri]::EscapeDataString($StatusFilter))"
    }
    if (-not [string]::IsNullOrWhiteSpace($ResultFilter)) {
        $queryParts += "resultFilter=$([uri]::EscapeDataString($ResultFilter))"
    }
    if (-not [string]::IsNullOrWhiteSpace($BranchName)) {
        $queryParts += "branchName=$([uri]::EscapeDataString($BranchName))"
    }
    if (-not [string]::IsNullOrWhiteSpace($MinTime)) {
        $queryParts += "minTime=$([uri]::EscapeDataString($MinTime))"
    }
    if (-not [string]::IsNullOrWhiteSpace($MaxTime)) {
        $queryParts += "maxTime=$([uri]::EscapeDataString($MaxTime))"
    }

    $uri = "$base/builds?$([string]::Join('&', $queryParts))"
    $response = Invoke-RestMethod -Uri $uri -Method Get -UseDefaultCredentials
    $builds = @()
    if ($response -and ($response.PSObject.Properties.Name -contains 'value') -and $response.value) {
        $builds = @($response.value)
    }

    return [pscustomobject]@{
        count  = $builds.Count
        builds = $builds
    }
}

function Get-AdoCoreHttpStatusCode {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord) { return 0 }
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($ex.PSObject.Properties.Name -contains 'Response' -and $ex.Response) {
            try { return [int]$ex.Response.StatusCode } catch { }
        }
        $ex = $ex.InnerException
    }
    return 0
}

function Stop-AdoCoreTerminatingError {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [string]$ErrorId,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorCategory]$Category,

        [Exception]$InnerException = $null
    )

    $exception = if ($null -ne $InnerException) {
        New-Object System.InvalidOperationException -ArgumentList $Message, $InnerException
    }
    else {
        New-Object System.InvalidOperationException $Message
    }
    $record = New-Object System.Management.Automation.ErrorRecord (
        $exception, $ErrorId, $Category, $null)
    throw $record
}

function Invoke-AdoCoreAuthenticatedGet {
    <#
    .SYNOPSIS
      GET with default credentials. HTTP 404 follows -ErrorPolicy; every other failure is AdoCoreReadFailed.
    .DESCRIPTION
      Fail (default, same names as Get-AdoCoreWorkItems -ErrorPolicy): 404 throws
      ErrorId AdoCoreResourceNotFound and the caller-supplied message.
      Omit: 404 returns $null.
      Transport, auth, and non-404 HTTP failures always throw ErrorId AdoCoreReadFailed
      (message starts with "Could not read"), including when -ErrorPolicy is Omit.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,

        [ValidateSet('Fail', 'Omit')]
        [string]$ErrorPolicy = 'Fail',

        [Parameter(Mandatory = $true)]
        [string]$NotFoundMessage,

        [Parameter(Mandatory = $true)]
        [string]$ReadContext
    )

    try {
        return Invoke-WebRequest -Uri $Uri -Method Get -UseDefaultCredentials -UseBasicParsing
    }
    catch {
        $status = Get-AdoCoreHttpStatusCode -ErrorRecord $_
        if ($status -eq 404) {
            if ($ErrorPolicy -eq 'Omit') { return $null }
            Stop-AdoCoreTerminatingError -Message $NotFoundMessage -ErrorId 'AdoCoreResourceNotFound' `
                -Category ([System.Management.Automation.ErrorCategory]::ObjectNotFound) -InnerException $_.Exception
        }

        $detail = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = "$detail $($_.ErrorDetails.Message)"
        }
        Stop-AdoCoreTerminatingError -Message "Could not read ${ReadContext}: $detail" -ErrorId 'AdoCoreReadFailed' `
            -Category ([System.Management.Automation.ErrorCategory]::ReadError) -InnerException $_.Exception
    }
}

function Get-AdoCoreBuildTimeline {
    <#
    .SYNOPSIS
      GET one build timeline. Returns { count; records } — API record objects, unclassified.
    .DESCRIPTION
      Records pass through (id, parentId, type, name, state, result, order, startTime,
      finishTime, errorCount, warningCount, log.id). result may be absent. issues may be
      absent even when errorCount is non-zero; read the log for the message.
      -ErrorPolicy Fail (default): HTTP 404 throws ErrorId AdoCoreResourceNotFound,
      message "ADO build {BuildId} was not found."
      -ErrorPolicy Omit: HTTP 404 returns $null (distinct from a readable empty timeline).
      Any other failure throws ErrorId AdoCoreReadFailed, message
      "Could not read ADO build {BuildId} timeline: ...".
      Does not decide whether a build or task passed.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$BuildId,

        [string]$WorkspaceRoot = '',
        [string]$BuildApiBase = '',
        [ValidateSet('Fail', 'Omit')]
        [string]$ErrorPolicy = 'Fail',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $base = Resolve-AdoCoreBuildApiBaseValue -WorkspaceRoot $WorkspaceRoot -BuildApiBase $BuildApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'BuildApiBase'

    $uri = "$base/builds/$BuildId/timeline?api-version=7.0"
    $response = Invoke-AdoCoreAuthenticatedGet -Uri $uri -ErrorPolicy $ErrorPolicy `
        -NotFoundMessage "ADO build $BuildId was not found." `
        -ReadContext "ADO build $BuildId timeline"
    if ($null -eq $response) { return $null }

    if ([int]$response.StatusCode -eq 204 -or [string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return [pscustomobject]@{
            count   = 0
            records = @()
        }
    }

    try {
        $parsed = $response.Content | ConvertFrom-Json
    }
    catch {
        Stop-AdoCoreTerminatingError -Message "Could not read ADO build $BuildId timeline: $($_.Exception.Message)" `
            -ErrorId 'AdoCoreReadFailed' -Category ([System.Management.Automation.ErrorCategory]::ReadError) `
            -InnerException $_.Exception
    }

    $records = @()
    if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'records') -and $null -ne $parsed.records) {
        $records = @($parsed.records)
    }
    return [pscustomobject]@{
        count   = $records.Count
        records = $records
    }
}

function Get-AdoCoreBuildLogs {
    <#
    .SYNOPSIS
      GET the log list for one build. Returns { count; logs } — API log objects, no log text.
    .DESCRIPTION
      Each log passes through (id, type, lineCount, createdOn, lastChangedOn, url).
      Use lineCount to size a log before reading it with Get-AdoCoreBuildLog -StartLine/-EndLine.
      -ErrorPolicy Fail (default): HTTP 404 throws ErrorId AdoCoreResourceNotFound,
      message "ADO build {BuildId} was not found."
      -ErrorPolicy Omit: HTTP 404 returns $null.
      Any other failure throws ErrorId AdoCoreReadFailed, message
      "Could not read ADO build {BuildId} logs: ...".
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$BuildId,

        [string]$WorkspaceRoot = '',
        [string]$BuildApiBase = '',
        [ValidateSet('Fail', 'Omit')]
        [string]$ErrorPolicy = 'Fail',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $base = Resolve-AdoCoreBuildApiBaseValue -WorkspaceRoot $WorkspaceRoot -BuildApiBase $BuildApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'BuildApiBase'

    $uri = "$base/builds/$BuildId/logs?api-version=7.0"
    $response = Invoke-AdoCoreAuthenticatedGet -Uri $uri -ErrorPolicy $ErrorPolicy `
        -NotFoundMessage "ADO build $BuildId was not found." `
        -ReadContext "ADO build $BuildId logs"
    if ($null -eq $response) { return $null }

    if ([int]$response.StatusCode -eq 204 -or [string]::IsNullOrWhiteSpace([string]$response.Content)) {
        return [pscustomobject]@{
            count = 0
            logs  = @()
        }
    }

    try {
        $parsed = $response.Content | ConvertFrom-Json
    }
    catch {
        Stop-AdoCoreTerminatingError -Message "Could not read ADO build $BuildId logs: $($_.Exception.Message)" `
            -ErrorId 'AdoCoreReadFailed' -Category ([System.Management.Automation.ErrorCategory]::ReadError) `
            -InnerException $_.Exception
    }

    $logs = @()
    if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'value') -and $null -ne $parsed.value) {
        $logs = @($parsed.value)
    }
    return [pscustomobject]@{
        count = $logs.Count
        logs  = $logs
    }
}

function Get-AdoCoreBuildLog {
    <#
    .SYNOPSIS
      GET one build log as a plain string. Does not parse the text into objects.
    .DESCRIPTION
      Without -StartLine/-EndLine the whole log is returned (can be several MB).
      -StartLine/-EndLine are passed to the API as-is: lines are 1-based and inclusive;
      either may be given alone; a range past the end returns ''. Choosing which lines
      to read (tail, error window) is the caller's decision.
      -ErrorPolicy Fail (default): HTTP 404 throws ErrorId AdoCoreResourceNotFound,
      message "ADO build {BuildId} log {LogId} was not found."
      -ErrorPolicy Omit: HTTP 404 returns $null.
      A log id the server answers with HTTP 200 and an empty body returns '' — that is
      a readable empty log, not the not-found error.
      Any other failure throws ErrorId AdoCoreReadFailed, message
      "Could not read ADO build {BuildId} log {LogId}: ...".
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$BuildId,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$LogId,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$StartLine,

        [ValidateRange(1, [int]::MaxValue)]
        [int]$EndLine,

        [string]$WorkspaceRoot = '',
        [string]$BuildApiBase = '',
        [ValidateSet('Fail', 'Omit')]
        [string]$ErrorPolicy = 'Fail',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $base = Resolve-AdoCoreBuildApiBaseValue -WorkspaceRoot $WorkspaceRoot -BuildApiBase $BuildApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'BuildApiBase'

    $hasStart = $PSBoundParameters.ContainsKey('StartLine')
    $hasEnd = $PSBoundParameters.ContainsKey('EndLine')
    if ($hasStart -and $hasEnd -and $EndLine -lt $StartLine) {
        throw "EndLine ($EndLine) must be greater than or equal to StartLine ($StartLine)."
    }

    $query = @()
    if ($hasStart) { $query += "startLine=$StartLine" }
    if ($hasEnd) { $query += "endLine=$EndLine" }
    $query += 'api-version=7.0'

    $uri = "$base/builds/$BuildId/logs/$LogId`?$($query -join '&')"
    $response = Invoke-AdoCoreAuthenticatedGet -Uri $uri -ErrorPolicy $ErrorPolicy `
        -NotFoundMessage "ADO build $BuildId log $LogId was not found." `
        -ReadContext "ADO build $BuildId log $LogId"
    if ($null -eq $response) { return $null }
    if ($null -eq $response.Content) { return '' }
    return [string]$response.Content
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

function Get-AdoCorePullRequests {
    <#
    .SYNOPSIS
      GET a repository's pull requests. Returns { count; pullRequests } — API objects, unclassified.
    .DESCRIPTION
      General list. -Status is active (default), completed, abandoned, or all.
      -SourceBranch and -TargetBranch are optional; a short name is sent as refs/heads/<name>,
      and a refs/heads/... value is sent unchanged. Does not decide ready, blocking, or stale,
      and does not load threads, reviewers, or work item links.
      Pages follow x-ms-continuationtoken until it is absent ($top=100). If a further page
      remains after -MaxPages (default 30), throws ErrorId AdoCoreResultTruncated and includes
      the count read so far. An empty list is count 0 and an empty array, not $null.
      -ErrorPolicy Fail (default): HTTP 404 throws ErrorId AdoCoreResourceNotFound,
      message "ADO pull requests were not found."
      -ErrorPolicy Omit: HTTP 404 returns $null.
      Any other failure throws ErrorId AdoCoreReadFailed, message
      "Could not read ADO pull requests: ...", including when -ErrorPolicy is Omit.
      Get-AdoCoreOpenPullRequestsForBranch is a separate branch lookup and is unchanged.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ApiBase,

        [ValidateSet('active', 'completed', 'abandoned', 'all')]
        [string]$Status = 'active',

        [string]$SourceBranch = '',
        [string]$TargetBranch = '',

        [ValidateRange(1, [int]::MaxValue)]
        [int]$MaxPages = 30,

        [ValidateSet('Fail', 'Omit')]
        [string]$ErrorPolicy = 'Fail'
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $ApiBase

    $statusValue = $Status.ToLowerInvariant()
    $queryParts = @(
        "searchCriteria.status=$([uri]::EscapeDataString($statusValue))"
    )
    if (-not [string]::IsNullOrWhiteSpace($SourceBranch)) {
        $sourceRef = if ($SourceBranch -like 'refs/heads/*') { $SourceBranch } else { "refs/heads/$SourceBranch" }
        $queryParts += "searchCriteria.sourceRefName=$([uri]::EscapeDataString($sourceRef))"
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetBranch)) {
        $targetRef = if ($TargetBranch -like 'refs/heads/*') { $TargetBranch } else { "refs/heads/$TargetBranch" }
        $queryParts += "searchCriteria.targetRefName=$([uri]::EscapeDataString($targetRef))"
    }
    $queryParts += @(
        "`$top=100",
        'api-version=7.0'
    )

    $baseUri = "$($ApiBase.TrimEnd('/'))/pullrequests?$([string]::Join('&', $queryParts))"
    $pullRequests = New-Object 'System.Collections.Generic.List[object]'
    $continuationToken = $null
    $pageCount = 0
    do {
        if ($pageCount -ge $MaxPages) {
            Stop-AdoCoreTerminatingError `
                -Message "ADO pull request results were truncated after reading $($pullRequests.Count) pull request(s) across $pageCount page(s)." `
                -ErrorId 'AdoCoreResultTruncated' `
                -Category ([System.Management.Automation.ErrorCategory]::LimitsExceeded)
        }
        $pageCount++

        $uri = $baseUri
        if ($continuationToken) {
            $uri = "$uri&continuationToken=$([uri]::EscapeDataString($continuationToken))"
        }

        $response = Invoke-AdoCoreAuthenticatedGet -Uri $uri -ErrorPolicy $ErrorPolicy `
            -NotFoundMessage 'ADO pull requests were not found.' `
            -ReadContext 'ADO pull requests'
        if ($null -eq $response) { return $null }

        $content = [string]$response.Content
        if ([int]$response.StatusCode -ne 204 -and -not [string]::IsNullOrWhiteSpace($content)) {
            try {
                $parsed = $content | ConvertFrom-Json
            }
            catch {
                Stop-AdoCoreTerminatingError -Message "Could not read ADO pull requests: $($_.Exception.Message)" `
                    -ErrorId 'AdoCoreReadFailed' `
                    -Category ([System.Management.Automation.ErrorCategory]::ReadError) `
                    -InnerException $_.Exception
            }

            if ($parsed -and ($parsed.PSObject.Properties.Name -contains 'value') -and $null -ne $parsed.value) {
                foreach ($item in @($parsed.value)) {
                    [void]$pullRequests.Add($item)
                }
            }
        }

        $continuationToken = Get-AdoCoreContinuationToken -Response $response
    } while ($continuationToken)

    $items = [object[]]$pullRequests.ToArray()
    return [pscustomobject]@{
        count        = $items.Count
        pullRequests = $items
    }
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
    $pullRequest = Invoke-RestMethod -Uri $uri -Method Post -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json') -UseDefaultCredentials
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

    $response = Invoke-RestMethod -Uri $uri -Method Post -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json') -UseDefaultCredentials

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

    $posted = Invoke-RestMethod -Uri $uri -Method Post -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json') -UseDefaultCredentials

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
    Invoke-RestMethod -Uri $uri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json') -UseDefaultCredentials | Out-Null
}

function Resolve-AdoCoreGitApiBaseValue {
    param(
        [string]$WorkspaceRoot = '',
        [string]$ApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($ApiBase)) {
        Assert-AdoCoreTrustedApiBase -ApiBase $ApiBase
        return $ApiBase.TrimEnd('/')
    }

    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $WorkspaceRoot -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $endpoints.ApiBase
    return [string]$endpoints.ApiBase
}

function Set-AdoCorePullRequestReviewer {
    <#
    .SYNOPSIS
      Adds or updates a pull-request reviewer (Required or Optional).
    .DESCRIPTION
      Generic ADO REST helper — PUT reviewers/{reviewerId}. Callers own which identity
      GUID to use. -ReviewType maps to ADO isRequired today (Required → true, Optional → false)
      and can grow with future preference values without a new switch. Default is Required.
      Does not encode product/team policy. To inspect existing reviewers, use
      Get-AdoCorePullRequest and read .reviewers with null-safe property checks
      (isRequired may be absent on optional entries).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$ReviewerId,

        [ValidateSet('Required', 'Optional')]
        [string]$ReviewType = 'Required',

        [string]$WorkspaceRoot = '',
        [string]$ApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $base = Resolve-AdoCoreGitApiBaseValue -WorkspaceRoot $WorkspaceRoot -ApiBase $ApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base

    $isRequired = ($ReviewType -eq 'Required')
    $reviewerSegment = ConvertTo-AdoCoreUriPathSegment -Value $ReviewerId.Trim() -Name 'ReviewerId'
    $uri = "$base/pullRequests/$PullRequestId/reviewers/$reviewerSegment`?api-version=7.0"
    $body = @{
        id         = $ReviewerId.Trim()
        isRequired = [bool]$isRequired
    } | ConvertTo-Json -Compress

    $response = Invoke-RestMethod -Uri $uri -Method Put -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json') -UseDefaultCredentials

    $displayName = $null
    if ($response -and ($response.PSObject.Properties.Name -contains 'displayName')) {
        $displayName = [string]$response.displayName
    }
    $responseIsRequired = $isRequired
    if ($response -and ($response.PSObject.Properties.Name -contains 'isRequired')) {
        $responseIsRequired = [bool]$response.isRequired
    }
    $responseId = $ReviewerId.Trim()
    if ($response -and ($response.PSObject.Properties.Name -contains 'id') -and $response.id) {
        $responseId = [string]$response.id
    }

    $responseReviewType = if ($responseIsRequired) { 'Required' } else { 'Optional' }

    return [pscustomobject]@{
        Id            = $responseId
        DisplayName   = $displayName
        ReviewType    = $responseReviewType
        PullRequestId = $PullRequestId
    }
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
        Invoke-RestMethod -Uri $uri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
            -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials | Out-Null
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
    if ($resolvedPaths.Count -eq 0) { return 0 }

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

    if ($operations.Count -eq 0) { return 0 }

    $operationArray = [object[]]$operations.ToArray()
    $body = ConvertTo-Json -InputObject $operationArray -Depth 6 -Compress
    $patchUri = "$WitApiBase/workitems/$WorkItemId`?api-version=7.0"
    Invoke-RestMethod -Uri $patchUri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials | Out-Null
    return $operations.Count
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

function Test-AdoCoreWorkItemFieldValueEmpty {
    param($Value)

    if ($null -eq $Value) { return $true }
    if ($Value -is [string] -and [string]::IsNullOrWhiteSpace($Value)) { return $true }
    return $false
}

function ConvertTo-AdoCoreWorkItemFieldPatchValue {
    <#
    .SYNOPSIS
      Normalize a GET field value for JSON Patch create/update (identity objects → AssignedTo string).
    #>
    param($Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [byte] -or $Value -is [int16] -or
        $Value -is [uint16] -or $Value -is [int] -or $Value -is [uint32] -or $Value -is [long] -or
        $Value -is [uint64] -or $Value -is [float] -or $Value -is [double] -or $Value -is [decimal] -or
        $Value -is [datetime]) {
        return $Value
    }

    $names = @()
    if ($Value -is [System.Collections.IDictionary]) {
        $names = @($Value.Keys | ForEach-Object { [string]$_ })
    }
    elseif ($Value -is [System.Management.Automation.PSObject]) {
        $names = @($Value.PSObject.Properties.Name)
    }

    if ($names -contains 'uniqueName' -or $names -contains 'displayName' -or $names -contains 'descriptor') {
        $identity = Get-AdoCoreAssignedToFieldValue -User $Value
        if ($identity) { return $identity }
    }

    return $Value
}

function Test-AdoCoreCloneSourceFieldShouldSkip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RefName
    )

    if ($script:AdoCoreCloneAlwaysSkipFieldRefNames.Contains($RefName)) { return $true }
    if ($RefName.StartsWith('WEF_', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($RefName.StartsWith('System.Board', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($RefName.StartsWith('System.AreaLevel', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($RefName.StartsWith('System.IterationLevel', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($script:AdoCoreCloneVersionBuildFieldRefNames.Contains($RefName)) { return $true }
    if ($RefName.StartsWith('Microsoft.VSTS.Build.', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function New-AdoCoreCloneFieldMapFromSource {
    <#
    .SYNOPSIS
      Build a writable field hashtable for clone create (private helper used by Clone-AdoCoreWorkItem).
    #>
    param(
        [Parameter(Mandatory = $true)]
        $SourceFields,

        [hashtable]$Overrides = @{}
    )

    $map = @{}
    if ($SourceFields) {
        foreach ($prop in @($SourceFields.PSObject.Properties)) {
            $refName = [string]$prop.Name
            if ([string]::IsNullOrWhiteSpace($refName)) { continue }
            if ($refName -eq 'System.Title') { continue }
            if (Test-AdoCoreCloneSourceFieldShouldSkip -RefName $refName) { continue }
            if (Test-AdoCoreWorkItemFieldValueEmpty -Value $prop.Value) { continue }
            $patchValue = ConvertTo-AdoCoreWorkItemFieldPatchValue -Value $prop.Value
            if (Test-AdoCoreWorkItemFieldValueEmpty -Value $patchValue) { continue }
            $map[$refName] = $patchValue
        }
    }

    # ADO-like: new clone starts New / New unless overridden.
    $map['System.State'] = 'New'
    $map['System.Reason'] = 'New'

    if ($Overrides) {
        foreach ($key in @($Overrides.Keys)) {
            $refName = ConvertTo-AdoCoreWorkItemFieldRefName -Field ([string]$key)
            if ($refName -eq 'System.Title') { continue }
            $patchValue = ConvertTo-AdoCoreWorkItemFieldPatchValue -Value $Overrides[$key]
            if ($null -eq $patchValue) {
                if ($map.ContainsKey($refName)) { [void]$map.Remove($refName) }
                continue
            }
            $map[$refName] = $patchValue
        }
    }

    return $map
}

function New-AdoCoreWorkItem {
    <#
    .SYNOPSIS
      Create a work item via WIT REST (JSON Patch). Prefer this over hand-rolled create URIs.
    .DESCRIPTION
      Field values are passed through as-is — callers own HTML conversion and workflow
      defaults (area/iteration/tags/state).       Optional -PullRequestId links the pull request after create
      (Link-AdoCoreWorkItemToPullRequest). Commit links are off unless -LinkCommits.
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
        [switch]$LinkCommits,
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

    $workItem = Invoke-RestMethod -Uri $uri -Method Post -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials
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
                -PullRequestId $PullRequestId -Endpoints $endpoints -WitApiBase $base `
                -LinkCommits:$LinkCommits
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
        # System.Tags: "add" unions with existing tags on ADO; "replace" sets the full string.
        $op = if ($RefName -eq 'System.Tags') { 'replace' } else { 'add' }
        [void]$patch.Add([pscustomobject]@{
                op    = $op
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

    try {
        $workItem = Invoke-RestMethod -Uri $uri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
            -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $message = "$message $($_.ErrorDetails.Message)"
        }
        # Tags field absent: replace fails — retry that op as add.
        $hasTagsReplace = $false
        foreach ($op in @($patch)) {
            if ($op.path -eq '/fields/System.Tags' -and $op.op -eq 'replace') { $hasTagsReplace = $true; break }
        }
        if ($hasTagsReplace -and ($message -match 'could not be found|TF401320|does not exist|path')) {
            foreach ($op in @($patch)) {
                if ($op.path -eq '/fields/System.Tags') { $op.op = 'add' }
            }
            $body = @($patch.ToArray()) | ConvertTo-Json -Depth 5 -Compress
            if ($patch.Count -eq 1 -and -not $body.StartsWith('[')) { $body = "[$body]" }
            $workItem = Invoke-RestMethod -Uri $uri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
                -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials
        }
        else {
            throw
        }
    }

    return [pscustomobject]@{
        WorkItemId   = $WorkItemId
        Title        = [string]$workItem.fields.'System.Title'
        WebUrl       = (Get-AdoCoreWorkItemWebUrl -WorkItemId $WorkItemId -Endpoints $endpoints)
        AssignedToMe = $AssignToMe.IsPresent
        Endpoints    = $endpoints
        WitApiBase   = $base
    }
}

function ConvertFrom-AdoCoreWorkItemTags {
    param([string]$Tags)

    $set = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    if ([string]::IsNullOrWhiteSpace($Tags)) { return @() }
    foreach ($part in @($Tags -split ';')) {
        $tag = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($tag)) { continue }
        if ($seen.Add($tag)) { [void]$set.Add($tag) }
    }
    return @($set.ToArray())
}

function ConvertTo-AdoCoreWorkItemTags {
    param([string[]]$Tags)

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($part in @($Tags)) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        $tag = $part.Trim()
        if ($seen.Add($tag)) { [void]$parts.Add($tag) }
    }
    return [string]::Join('; ', $parts.ToArray())
}

function Update-AdoCoreWorkItemTags {
    <#
    .SYNOPSIS
      Add and/or remove work-item tags (GET System.Tags → merge → PATCH). Prefer this for single-tag edits.
    .DESCRIPTION
      Idempotent: adding an existing tag or removing a missing tag skips the PATCH when the merged set is unchanged.
      Provide at least one of -Add or -Remove. For a full tag-set replace, use Update-AdoCoreWorkItem -Fields
      @{ 'System.Tags' = '...' } instead.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        [string[]]$Add = @(),
        [string[]]$Remove = @(),
        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $addTags = @(ConvertFrom-AdoCoreWorkItemTags -Tags ([string]::Join(';', @($Add))))
    $removeTags = @(ConvertFrom-AdoCoreWorkItemTags -Tags ([string]::Join(';', @($Remove))))
    if ($addTags.Count -lt 1 -and $removeTags.Count -lt 1) {
        throw 'Provide -Add and/or -Remove with at least one non-empty tag.'
    }

    $existing = Get-AdoCoreWorkItem -WorkItemId $WorkItemId -WorkspaceRoot $WorkspaceRoot `
        -WitApiBase $WitApiBase -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    $currentRaw = ''
    if ($existing.fields -and ($existing.fields.PSObject.Properties.Name -contains 'System.Tags')) {
        $currentRaw = [string]$existing.fields.'System.Tags'
    }

    $current = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tag in @(ConvertFrom-AdoCoreWorkItemTags -Tags $currentRaw)) {
        if ($seen.Add($tag)) { [void]$current.Add($tag) }
    }

    $removeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tag in $removeTags) { [void]$removeSet.Add($tag) }

    if ($removeSet.Count -gt 0) {
        $kept = New-Object 'System.Collections.Generic.List[string]'
        foreach ($tag in @($current)) {
            if (-not $removeSet.Contains($tag)) { [void]$kept.Add($tag) }
        }
        $current = $kept
        $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($tag in @($current)) { [void]$seen.Add($tag) }
    }

    foreach ($tag in $addTags) {
        if ($seen.Add($tag)) { [void]$current.Add($tag) }
    }

    $merged = ConvertTo-AdoCoreWorkItemTags -Tags @($current.ToArray())

    $beforeSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tag in @(ConvertFrom-AdoCoreWorkItemTags -Tags $currentRaw)) { [void]$beforeSet.Add($tag) }
    $afterSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($tag in @(ConvertFrom-AdoCoreWorkItemTags -Tags $merged)) { [void]$afterSet.Add($tag) }
    $tagsUnchanged = $beforeSet.SetEquals($afterSet)

    # System.Tags: JSON Patch "add" unions with existing tags on ADO; use "replace" for set semantics.
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

    if ($tagsUnchanged) {
        $title = ''
        if ($existing.fields -and ($existing.fields.PSObject.Properties.Name -contains 'System.Title')) {
            $title = [string]$existing.fields.'System.Title'
        }
        return [pscustomobject]@{
            WorkItemId = $WorkItemId
            Title      = $title
            WebUrl     = (Get-AdoCoreWorkItemWebUrl -WorkItemId $WorkItemId -Endpoints $endpoints)
            Tags       = $merged
            TagList    = @(ConvertFrom-AdoCoreWorkItemTags -Tags $merged)
            Added      = $addTags
            Removed    = $removeTags
            Endpoints  = $endpoints
            WitApiBase = $base
        }
    }

    $patch = @(
        [pscustomobject]@{
            op    = 'replace'
            path  = '/fields/System.Tags'
            value = $merged
        }
    )
    # Empty set: replace with '' clears tags; if Tags was never set, replace can 400 — fall back to add.
    $uri = "$base/workitems/$WorkItemId`?api-version=7.0"
    $body = ConvertTo-Json -InputObject $patch -Depth 5 -Compress
    if (-not $body.StartsWith('[')) { $body = "[$body]" }
    try {
        $workItem = Invoke-RestMethod -Uri $uri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
            -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $message = "$message $($_.ErrorDetails.Message)"
        }
        if ($message -match 'could not be found|TF401320|does not exist|path') {
            $patch[0].op = 'add'
            $body = ConvertTo-Json -InputObject $patch -Depth 5 -Compress
            if (-not $body.StartsWith('[')) { $body = "[$body]" }
            $workItem = Invoke-RestMethod -Uri $uri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
                -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials
        }
        else {
            throw
        }
    }

    $title = ''
    if ($workItem.fields -and ($workItem.fields.PSObject.Properties.Name -contains 'System.Title')) {
        $title = [string]$workItem.fields.'System.Title'
    }
    $serverTags = $merged
    if ($workItem.fields -and ($workItem.fields.PSObject.Properties.Name -contains 'System.Tags')) {
        $serverTags = [string]$workItem.fields.'System.Tags'
    }

    return [pscustomobject]@{
        WorkItemId = $WorkItemId
        Title      = $title
        WebUrl     = (Get-AdoCoreWorkItemWebUrl -WorkItemId $WorkItemId -Endpoints $endpoints)
        Tags       = $serverTags
        TagList    = @(ConvertFrom-AdoCoreWorkItemTags -Tags $serverTags)
        Added      = $addTags
        Removed    = $removeTags
        Endpoints  = $endpoints
        WitApiBase = $base
    }
}

function Add-AdoCoreWorkItemRelation {
    <#
    .SYNOPSIS
      Add a work-item ↔ work-item relation (default Related). Prefer this over hand-rolled relation patches.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$TargetWorkItemId,

        [string]$LinkType = 'System.LinkTypes.Related',
        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = '',
        [int]$DuplicateRetryCount = 0
    )

    if ([string]::IsNullOrWhiteSpace($LinkType)) {
        throw 'LinkType is required.'
    }
    if ($WorkItemId -eq $TargetWorkItemId) {
        throw 'WorkItemId and TargetWorkItemId must differ.'
    }

    $base = Resolve-AdoCoreWitApiBaseValue -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Assert-AdoCoreTrustedApiBase -ApiBase $base -Name 'WitApiBase'

    $targetUrl = "$base/workitems/$TargetWorkItemId"
    $existingUri = "$base/workitems/$WorkItemId`?`$expand=relations&api-version=7.0"
    $existing = Invoke-RestMethod -Uri $existingUri -Method Get -UseDefaultCredentials
    $existingRelations = if ($existing.PSObject.Properties.Name -contains 'relations') { @($existing.relations) } else { @() }
    foreach ($relation in $existingRelations) {
        $relType = if ($relation.rel) { [string]$relation.rel } else { '' }
        $relUrl = if ($relation.url) { [string]$relation.url } else { '' }
        if ($relType -eq $LinkType -and $relUrl -and ($relUrl.TrimEnd('/') -ieq $targetUrl.TrimEnd('/'))) {
            return [pscustomobject]@{
                WorkItemId       = $WorkItemId
                TargetWorkItemId = $TargetWorkItemId
                LinkType         = $LinkType
                AlreadyExisted   = $true
                WitApiBase       = $base
            }
        }
    }

    $patch = @(
        [pscustomobject]@{
            op    = 'add'
            path  = '/relations/-'
            value = [pscustomobject]@{
                rel = $LinkType
                url = $targetUrl
            }
        }
    )
    $body = ConvertTo-Json -InputObject $patch -Depth 6 -Compress
    $uri = "$base/workitems/$WorkItemId`?api-version=7.0"
    try {
        Invoke-RestMethod -Uri $uri -Method Patch -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
            -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json-patch+json') -UseDefaultCredentials | Out-Null
    }
    catch {
        $message = [string]$_.Exception.Message
        if ($message -match 'already exists|RelationAlreadyExists|TF201036|relation already|duplicate') {
            if ($DuplicateRetryCount -lt 1) {
                return Add-AdoCoreWorkItemRelation -WorkItemId $WorkItemId `
                    -TargetWorkItemId $TargetWorkItemId -LinkType $LinkType `
                    -WorkspaceRoot $WorkspaceRoot -WitApiBase $base `
                    -Collection $Collection -Project $Project -Repository $Repository `
                    -ServerUrl $ServerUrl -DuplicateRetryCount ($DuplicateRetryCount + 1)
            }
            return [pscustomobject]@{
                WorkItemId       = $WorkItemId
                TargetWorkItemId = $TargetWorkItemId
                LinkType         = $LinkType
                AlreadyExisted   = $true
                WitApiBase       = $base
            }
        }
        throw
    }

    return [pscustomobject]@{
        WorkItemId       = $WorkItemId
        TargetWorkItemId = $TargetWorkItemId
        LinkType         = $LinkType
        AlreadyExisted   = $false
        WitApiBase       = $base
    }
}

function Copy-AdoCoreWorkItemAttachmentsFromSource {
    <#
    .SYNOPSIS
      Download AttachedFile relations from a source work item and attach them to a target (clone helper).
    #>
    param(
        [Parameter(Mandatory = $true)]
        [int]$SourceWorkItemId,
        [Parameter(Mandatory = $true)]
        [int]$TargetWorkItemId,
        [Parameter(Mandatory = $true)]
        [string]$WitApiBase,
        $SourceRelations = $null
    )

    Assert-AdoCoreTrustedApiBase -ApiBase $WitApiBase -Name 'WitApiBase'

    $relations = @()
    if ($null -ne $SourceRelations) {
        $relations = @($SourceRelations)
    }
    else {
        $existingUri = "$WitApiBase/workitems/$SourceWorkItemId`?`$expand=relations&api-version=7.0"
        $source = Invoke-RestMethod -Uri $existingUri -Method Get -UseDefaultCredentials
        if ($source.PSObject.Properties.Name -contains 'relations') {
            $relations = @($source.relations)
        }
    }

    $copied = 0
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $batchMaxCount = 10
    $batchMaxBytes = 32MB
    $pendingPaths = New-Object 'System.Collections.Generic.List[string]'
    $pendingDirs = New-Object 'System.Collections.Generic.List[string]'
    $pendingBytes = [long]0

    # Dot-source flush so $copied / pending* update in this scope.
    $flushPendingAttachments = {
        if ($pendingPaths.Count -eq 0) { return }
        try {
            $linked = Add-AdoCoreWorkItemAttachments -WorkItemId $TargetWorkItemId -WitApiBase $WitApiBase `
                -FilePaths ([string[]]$pendingPaths.ToArray())
            $copied += [int]$linked
        }
        finally {
            foreach ($dir in @($pendingDirs)) {
                if ($dir -and (Test-Path -LiteralPath $dir)) {
                    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            $pendingPaths.Clear()
            $pendingDirs.Clear()
            $pendingBytes = [long]0
        }
    }

    try {
        foreach ($relation in $relations) {
            if (-not $relation -or [string]$relation.rel -ne 'AttachedFile') { continue }
            $url = if ($relation.url) { [string]$relation.url } else { '' }
            if ([string]::IsNullOrWhiteSpace($url)) { continue }

            $fileName = 'attachment.bin'
            if ($relation.attributes -and $relation.attributes.name) {
                $fileName = [IO.Path]::GetFileName([string]$relation.attributes.name)
            }
            if ([string]::IsNullOrWhiteSpace($fileName)) { $fileName = 'attachment.bin' }

            try {
                Assert-AdoCoreTrustedDownloadUrl -Url $url -Name 'AttachmentUrl'
            }
            catch {
                [void]$warnings.Add("Skipped attachment '$fileName' from $SourceWorkItemId`: $($_.Exception.Message)")
                continue
            }

            # Unique temp directory so the uploaded basename stays the source file name
            # (Add-AdoCoreWorkItemAttachments uses the path basename as attributes.name).
            $tempDir = Join-Path ([IO.Path]::GetTempPath()) ("ado-core-clone-" + [guid]::NewGuid().ToString('N'))
            [void](New-Item -ItemType Directory -Path $tempDir -Force)
            $tempPath = Join-Path $tempDir $fileName
            try {
                # No cross-host redirects: authenticated download must stay on the trusted host.
                Invoke-WebRequest -Uri $url -OutFile $tempPath -UseDefaultCredentials -UseBasicParsing `
                    -MaximumRedirection 0 | Out-Null
            }
            catch {
                [void]$warnings.Add("Failed to download attachment '$fileName' from $SourceWorkItemId`: $($_.Exception.Message)")
                if (Test-Path -LiteralPath $tempDir) {
                    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
                }
                continue
            }

            $fileBytes = ([IO.FileInfo]$tempPath).Length
            if ($pendingPaths.Count -gt 0 -and (
                    $pendingPaths.Count -ge $batchMaxCount -or
                    ($pendingBytes + $fileBytes) -gt $batchMaxBytes)) {
                . $flushPendingAttachments
            }

            [void]$pendingPaths.Add($tempPath)
            [void]$pendingDirs.Add($tempDir)
            $pendingBytes += $fileBytes

            if ($pendingPaths.Count -ge $batchMaxCount -or $pendingBytes -ge $batchMaxBytes) {
                . $flushPendingAttachments
            }
        }

        . $flushPendingAttachments
    }
    finally {
        foreach ($dir in @($pendingDirs)) {
            if ($dir -and (Test-Path -LiteralPath $dir)) {
                Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return [pscustomobject]@{
        CopiedCount = $copied
        Warning     = if ($warnings.Count -gt 0) { [string]::Join('; ', $warnings.ToArray()) } else { '' }
    }
}

function Clone-AdoCoreWorkItem {
    <#
    .SYNOPSIS
      Clone a work item: copy writable fields, reset State/Reason to New, optional Related + Copied-from comment.
    .DESCRIPTION
      Defaults match agreed ado-core clone policy:
      - Title: -Title if supplied (non-blank); omit/$null → "{source title} - Copy"; blank/whitespace throws
      - Body/people/classification/planning: copy non-empty writable values
      - Version/build fields blank unless set via -Fields
      - State/Reason forced to New unless overridden in -Fields
      - Related link to source on (opt out -NoRelatedLink)
      - "Copied from …" discussion on (opt out -NoCopiedFromComment)
      - Other source relations not copied; attachments off unless -CopyAttachments
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, [int]::MaxValue)]
        [int]$WorkItemId,

        # Untyped so omit stays distinct from empty string.
        $Title = $null,
        [hashtable]$Fields = @{},
        [switch]$NoRelatedLink,
        [switch]$NoCopiedFromComment,
        [switch]$CopyAttachments,
        [string]$WorkspaceRoot = '',
        [string]$WitApiBase = '',
        [string]$Collection = '',
        [string]$Project = '',
        [string]$Repository = '',
        [string]$ServerUrl = ''
    )

    $expand = if ($CopyAttachments) { 'All' } else { '' }
    $source = Get-AdoCoreWorkItem -WorkItemId $WorkItemId -WorkspaceRoot $WorkspaceRoot `
        -WitApiBase $WitApiBase -Expand $expand -Collection $Collection -Project $Project `
        -Repository $Repository -ServerUrl $ServerUrl
    if (-not $source -or -not $source.fields) {
        throw "Work item $WorkItemId was not returned by WIT GET."
    }

    $sourceFields = $source.fields
    $workItemType = [string]$sourceFields.'System.WorkItemType'
    if ([string]::IsNullOrWhiteSpace($workItemType)) {
        throw "Work item $WorkItemId has no System.WorkItemType."
    }

    $sourceTitle = [string]$sourceFields.'System.Title'
    if ([string]::IsNullOrWhiteSpace($sourceTitle)) {
        throw "Work item $WorkItemId has no System.Title."
    }

    if ($null -ne $Title -and [string]::IsNullOrWhiteSpace([string]$Title)) {
        throw 'Title cannot be empty or whitespace; omit -Title to use "{source} - Copy".'
    }
    $cloneTitle = if ($null -ne $Title) {
        [string]$Title
    }
    else {
        "$sourceTitle - Copy"
    }

    $fieldMap = New-AdoCoreCloneFieldMapFromSource -SourceFields $sourceFields -Overrides $Fields

    $created = New-AdoCoreWorkItem -Title $cloneTitle -WorkItemType $workItemType -Fields $fieldMap `
        -WorkspaceRoot $WorkspaceRoot -WitApiBase $WitApiBase -Collection $Collection `
        -Project $Project -Repository $Repository -ServerUrl $ServerUrl

    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $relatedLinked = $false
    $copiedFromComment = $false
    $attachmentCount = 0

    if (-not $NoRelatedLink) {
        try {
            [void](Add-AdoCoreWorkItemRelation -WorkItemId $created.WorkItemId `
                    -TargetWorkItemId $WorkItemId -LinkType 'System.LinkTypes.Related' `
                    -WorkspaceRoot $WorkspaceRoot -WitApiBase $created.WitApiBase `
                    -Collection $Collection -Project $Project -Repository $Repository `
                    -ServerUrl $ServerUrl)
            $relatedLinked = $true
        }
        catch {
            [void]$warnings.Add("Related link failed after clone: $($_.Exception.Message)")
        }
    }

    if (-not $NoCopiedFromComment) {
        try {
            $sourceUrl = Get-AdoCoreWorkItemWebUrl -WorkItemId $WorkItemId -Endpoints $created.Endpoints
            $safeType = ConvertTo-AdoCoreHtmlText -Value $workItemType
            $safeUrl = ConvertTo-AdoCoreHtmlText -Value $sourceUrl
            $safeId = ConvertTo-AdoCoreHtmlText -Value ([string]$WorkItemId)
            $commentText = "Copied from $safeType <a href=`"$safeUrl`">$safeId</a>"
            [void](Add-AdoCoreWorkItemComment -WorkItemId $created.WorkItemId -Text $commentText `
                    -WorkspaceRoot $WorkspaceRoot -WitApiBase $created.WitApiBase `
                    -Collection $Collection -Project $Project -Repository $Repository `
                    -ServerUrl $ServerUrl)
            $copiedFromComment = $true
        }
        catch {
            [void]$warnings.Add("Copied-from comment failed after clone: $($_.Exception.Message)")
        }
    }

    if ($CopyAttachments) {
        try {
            $sourceRelations = if ($source.PSObject.Properties.Name -contains 'relations') { $source.relations } else { @() }
            $attachResult = Copy-AdoCoreWorkItemAttachmentsFromSource -SourceWorkItemId $WorkItemId `
                -TargetWorkItemId $created.WorkItemId -WitApiBase $created.WitApiBase `
                -SourceRelations $sourceRelations
            $attachmentCount = [int]$attachResult.CopiedCount
            if ($attachResult.Warning) {
                [void]$warnings.Add([string]$attachResult.Warning)
            }
        }
        catch {
            [void]$warnings.Add("Attachment copy failed after clone: $($_.Exception.Message)")
        }
    }

    return [pscustomobject]@{
        WorkItemId         = $created.WorkItemId
        SourceWorkItemId   = $WorkItemId
        Title              = $created.Title
        WebUrl             = $created.WebUrl
        WorkItemType       = $workItemType
        RelatedLinked      = $relatedLinked
        CopiedFromComment  = $copiedFromComment
        AttachmentCount    = $attachmentCount
        Warning            = if ($warnings.Count -gt 0) { [string]::Join('; ', $warnings.ToArray()) } else { '' }
        Endpoints          = $created.Endpoints
        WitApiBase         = $created.WitApiBase
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
        [string]$WitApiBase,
        # Off by default so a later re-link does not stamp every PR commit onto the work item.
        [switch]$LinkCommits
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

        if ($LinkCommits) {
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
    }
    catch {
        if ($LinkCommits) {
            [void]$warnings.Add("PR and commit links failed after linking $linkedCommitCount commit(s): $($_.Exception.Message)")
        }
        else {
            [void]$warnings.Add("PR link failed: $($_.Exception.Message)")
        }
    }

    $linkWarning = if ($warnings.Count -gt 0) { $warnings -join ' ' } else { '' }
    if (-not $linkedToPr -and $linkedCommitCount -eq 0 -and -not $linkWarning) {
        if ($LinkCommits) {
            $linkWarning = 'Work item was not linked to the pull request or its commits. Link it manually.'
        }
        else {
            $linkWarning = 'Work item was not linked to the pull request. Link it manually.'
        }
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
    return Invoke-RestMethod -Uri $uri -Method Post -Body (ConvertTo-AdoCoreUtf8RequestBody -Json $body) `
        -ContentType (Get-AdoCoreJsonContentType -MediaType 'application/json') -UseDefaultCredentials
}
