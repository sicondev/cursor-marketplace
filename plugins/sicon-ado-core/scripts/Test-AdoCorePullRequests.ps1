#Requires -Version 5.1
<#
.SYNOPSIS
  Scripted HTTP checks for Get-AdoCorePullRequests. No live ADO calls.
.EXAMPLE
  & "$PSScriptRoot\Test-AdoCorePullRequests.ps1"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'ado-core.ps1')

class AdoCoreTestHttpResponse {
    [int]$StatusCode
    AdoCoreTestHttpResponse([int]$StatusCode) { $this.StatusCode = $StatusCode }
}

class AdoCoreTestHttpException : System.Exception {
    [object]$Response
    AdoCoreTestHttpException([string]$Message, [int]$StatusCode) : base($Message) {
        $this.Response = [AdoCoreTestHttpResponse]::new($StatusCode)
    }
}

$script:StubUris = New-Object 'System.Collections.Generic.List[string]'
$script:StubResponses = New-Object 'System.Collections.Generic.List[object]'
$script:StubIndex = 0

function Reset-AdoCorePullRequestStub {
    param([object[]]$Responses)
    $script:StubUris = New-Object 'System.Collections.Generic.List[string]'
    $script:StubResponses = New-Object 'System.Collections.Generic.List[object]'
    foreach ($response in @($Responses)) {
        [void]$script:StubResponses.Add($response)
    }
    $script:StubIndex = 0
}

function Invoke-WebRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Method,
        [switch]$UseDefaultCredentials,
        [switch]$UseBasicParsing
    )

    [void]$script:StubUris.Add($Uri)
    if ($script:StubIndex -ge $script:StubResponses.Count) {
        throw "No scripted response for $Uri"
    }
    $next = $script:StubResponses[$script:StubIndex]
    $script:StubIndex++
    if ($next -is [System.Exception]) { throw $next }
    return $next
}

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}

function Get-ThrownError {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    try {
        & $Script | Out-Null
        return $null
    }
    catch {
        return $_
    }
}

function New-PullRequestPage {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$PullRequests,
        [string]$ContinuationToken = ''
    )

    $rows = New-Object 'System.Collections.Generic.List[string]'
    foreach ($pullRequest in @($PullRequests)) {
        $title = [string]$pullRequest.title
        $marker = [string]$pullRequest.customMarker
        [void]$rows.Add(
            '{"pullRequestId":' + [int]$pullRequest.pullRequestId +
            ',"title":"' + $title +
            '","isDraft":false,"customMarker":"' + $marker + '"}')
    }
    $headers = @{}
    if (-not [string]::IsNullOrWhiteSpace($ContinuationToken)) {
        $headers['x-ms-continuationtoken'] = $ContinuationToken
    }
    return [pscustomobject]@{
        StatusCode = 200
        Content    = '{"value":[' + ($rows -join ',') + ']}'
        Headers    = $headers
    }
}

function New-PullRequestItem {
    param([int]$Id)
    return [pscustomobject]@{
        pullRequestId = $Id
        title         = "PR $Id"
        customMarker  = "untouched-$Id"
    }
}

$apiBase = 'https://tfs.sicon.co.uk/tfs/Sicon/Project/_apis/git/repositories/Repo'

function Get-ExpectedPullRequestUri {
    param(
        [string]$Status = 'active',
        [string]$SourceRef = '',
        [string]$TargetRef = '',
        [string]$ContinuationToken = ''
    )

    $parts = New-Object 'System.Collections.Generic.List[string]'
    [void]$parts.Add("searchCriteria.status=$Status")
    if (-not [string]::IsNullOrWhiteSpace($SourceRef)) {
        [void]$parts.Add("searchCriteria.sourceRefName=$([uri]::EscapeDataString($SourceRef))")
    }
    if (-not [string]::IsNullOrWhiteSpace($TargetRef)) {
        [void]$parts.Add("searchCriteria.targetRefName=$([uri]::EscapeDataString($TargetRef))")
    }
    [void]$parts.Add('$top=100')
    [void]$parts.Add('api-version=7.0')
    $uri = "$apiBase/pullrequests?$([string]::Join('&', $parts.ToArray()))"
    if (-not [string]::IsNullOrWhiteSpace($ContinuationToken)) {
        $uri += "&continuationToken=$([uri]::EscapeDataString($ContinuationToken))"
    }
    return $uri
}

try {
    Assert-True ((Get-AdoCoreLibraryVersion) -eq [version]'0.11.0') 'library version is 0.11.0'
    Assert-True ($null -ne (Get-Command Get-AdoCorePullRequests -ErrorAction SilentlyContinue)) 'Get-AdoCorePullRequests is defined'

    Reset-AdoCorePullRequestStub -Responses @(
        (New-PullRequestPage -PullRequests @(
            (New-PullRequestItem -Id 7),
            (New-PullRequestItem -Id 8)
        ))
    )
    $onePage = Get-AdoCorePullRequests -ApiBase $apiBase
    Assert-True ($script:StubUris.Count -eq 1) 'one page issues one request'
    Assert-True ($script:StubUris[0] -eq (Get-ExpectedPullRequestUri)) "default URI was $($script:StubUris[0])"
    Assert-True ($onePage.count -eq 2) 'one page count is 2'
    Assert-True (@($onePage.pullRequests).Count -eq 2) 'one page returns both pull requests'
    Assert-True ([int]$onePage.pullRequests[0].pullRequestId -eq 7) 'first pull request id passes through'
    Assert-True ([string]$onePage.pullRequests[0].title -eq 'PR 7') 'title passes through unclassified'
    Assert-True ([string]$onePage.pullRequests[1].customMarker -eq 'untouched-8') 'extra API fields pass through unclassified'
    Assert-True ($onePage.pullRequests[0].isDraft -eq $false) 'isDraft passes through'

    Reset-AdoCorePullRequestStub -Responses @(
        (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 1), (New-PullRequestItem -Id 2)) -ContinuationToken 'next+1'),
        (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 3)) -ContinuationToken 'next+2'),
        (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 4)))
    )
    $paged = Get-AdoCorePullRequests -ApiBase $apiBase -Status active
    Assert-True ($script:StubUris.Count -eq 3) 'continuation header joins three pages'
    Assert-True ($script:StubUris[0] -eq (Get-ExpectedPullRequestUri)) 'first page has no continuation token'
    Assert-True ($script:StubUris[1] -eq (Get-ExpectedPullRequestUri -ContinuationToken 'next+1')) "second page URI was $($script:StubUris[1])"
    Assert-True ($script:StubUris[2] -eq (Get-ExpectedPullRequestUri -ContinuationToken 'next+2')) "third page URI was $($script:StubUris[2])"
    Assert-True ($paged.count -eq 4) 'paged count is the joined total'
    $pagedIds = @($paged.pullRequests | ForEach-Object { [int]$_.pullRequestId })
    Assert-True (($pagedIds -join ',') -eq '1,2,3,4') "joined ids were $($pagedIds -join ',')"

    Reset-AdoCorePullRequestStub -Responses @(
        (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 1), (New-PullRequestItem -Id 2)) -ContinuationToken 'next+1'),
        (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 3), (New-PullRequestItem -Id 4)) -ContinuationToken 'next+2'),
        (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 5)))
    )
    $truncated = Get-ThrownError -Script {
        Get-AdoCorePullRequests -ApiBase $apiBase -MaxPages 2
    }
    Assert-True ($null -ne $truncated) 'page cap throws'
    if ($null -ne $truncated) {
        Assert-True ($truncated.FullyQualifiedErrorId -like 'AdoCoreResultTruncated*') `
            "truncation ErrorId was $($truncated.FullyQualifiedErrorId)"
        Assert-True ($truncated.Exception.Message -match 'reading 4 pull request') `
            "truncation message was $($truncated.Exception.Message)"
    }
    Assert-True ($script:StubUris.Count -eq 2) 'page cap does not request the page past MaxPages'

    foreach ($status in @('active', 'completed', 'abandoned', 'all')) {
        Reset-AdoCorePullRequestStub -Responses @(
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{} }
        )
        $statusResult = Get-AdoCorePullRequests -ApiBase $apiBase -Status $status
        Assert-True ($statusResult.count -eq 0) "status $status on an empty page returns count 0"
        Assert-True ($script:StubUris[0] -eq (Get-ExpectedPullRequestUri -Status $status)) "status URI for $status was $($script:StubUris[0])"
    }

    foreach ($pair in @(
            @{ Source = 'feature/x'; Target = 'main'; SourceRef = 'refs/heads/feature/x'; TargetRef = 'refs/heads/main' }
            @{ Source = 'refs/heads/feature/x'; Target = 'refs/heads/main'; SourceRef = 'refs/heads/feature/x'; TargetRef = 'refs/heads/main' }
        )) {
        Reset-AdoCorePullRequestStub -Responses @(
            (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 9)))
        )
        $filtered = Get-AdoCorePullRequests -ApiBase $apiBase -SourceBranch $pair.Source -TargetBranch $pair.Target
        $expectedFilterUri = Get-ExpectedPullRequestUri -SourceRef $pair.SourceRef -TargetRef $pair.TargetRef
        Assert-True ($script:StubUris[0] -eq $expectedFilterUri) "branch filter URI for '$($pair.Source)' / '$($pair.Target)' was $($script:StubUris[0])"
        Assert-True ($filtered.count -eq 1) 'branch filter still returns the page'
    }

    Reset-AdoCorePullRequestStub -Responses @(
        [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}'; Headers = @{} }
    )
    $emptyValue = Get-AdoCorePullRequests -ApiBase $apiBase -Status completed
    Assert-True ($null -ne $emptyValue) 'zero results is not null'
    Assert-True ($emptyValue.count -eq 0) 'zero results count is 0'
    Assert-True (@($emptyValue.pullRequests).Count -eq 0) 'zero results is an empty array'

    Reset-AdoCorePullRequestStub -Responses @(
        [pscustomobject]@{ StatusCode = 200; Content = '{"count":0}'; Headers = @{} }
    )
    $missingValue = Get-AdoCorePullRequests -ApiBase $apiBase
    Assert-True ($null -ne $missingValue -and $missingValue.count -eq 0 -and @($missingValue.pullRequests).Count -eq 0) `
        'a payload without value is an empty list'

    $notFound = [AdoCoreTestHttpException]::new('The remote server returned an error: (404) Not Found.', 404)
    Reset-AdoCorePullRequestStub -Responses @($notFound)
    $missing = Get-ThrownError -Script {
        Get-AdoCorePullRequests -ApiBase $apiBase -ErrorPolicy Fail
    }
    Assert-True ($null -ne $missing) '404 under Fail throws'
    if ($null -ne $missing) {
        Assert-True ($missing.FullyQualifiedErrorId -like 'AdoCoreResourceNotFound*') `
            "404 ErrorId was $($missing.FullyQualifiedErrorId)"
        Assert-True ($missing.Exception.Message -eq 'ADO pull requests were not found.') `
            "404 message was $($missing.Exception.Message)"
    }

    Reset-AdoCorePullRequestStub -Responses @(
        [AdoCoreTestHttpException]::new('The remote server returned an error: (404) Not Found.', 404)
    )
    $omitted = Get-AdoCorePullRequests -ApiBase $apiBase -ErrorPolicy Omit
    Assert-True ($null -eq $omitted) '404 under Omit returns null'

    Reset-AdoCorePullRequestStub -Responses @(
        (New-PullRequestPage -PullRequests @((New-PullRequestItem -Id 1)) -ContinuationToken 'next+1'),
        [AdoCoreTestHttpException]::new('The remote server returned an error: (404) Not Found.', 404)
    )
    $omittedLater = Get-AdoCorePullRequests -ApiBase $apiBase -ErrorPolicy Omit
    Assert-True ($null -eq $omittedLater) '404 under Omit on a later page returns null rather than a partial list'

    Reset-AdoCorePullRequestStub -Responses @(
        [AdoCoreTestHttpException]::new('The remote server returned an error: (500) Internal Server Error.', 500)
    )
    $readFailed = Get-ThrownError -Script {
        Get-AdoCorePullRequests -ApiBase $apiBase
    }
    Assert-True ($null -ne $readFailed) 'non-404 failure throws'
    if ($null -ne $readFailed) {
        Assert-True ($readFailed.FullyQualifiedErrorId -like 'AdoCoreReadFailed*') `
            "non-404 ErrorId was $($readFailed.FullyQualifiedErrorId)"
        Assert-True ($readFailed.Exception.Message.StartsWith('Could not read')) `
            "non-404 message was $($readFailed.Exception.Message)"
    }

    Reset-AdoCorePullRequestStub -Responses @(
        [AdoCoreTestHttpException]::new('The remote server returned an error: (503) Server Unavailable.', 503)
    )
    $readFailedOmit = Get-ThrownError -Script {
        Get-AdoCorePullRequests -ApiBase $apiBase -ErrorPolicy Omit
    }
    Assert-True ($null -ne $readFailedOmit -and $readFailedOmit.FullyQualifiedErrorId -like 'AdoCoreReadFailed*' -and
        $readFailedOmit.Exception.Message.StartsWith('Could not read')) `
        'non-404 failure under Omit still throws AdoCoreReadFailed'
}
catch {
    [void]$failures.Add("unhandled: $($_.Exception.Message)")
}

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    Write-Error ('Test-AdoCorePullRequests FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join $sep))
    exit 1
}

Write-Output 'OK: ado-core pull request list'
exit 0
