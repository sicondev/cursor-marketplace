#Requires -Version 5.1
<#
.SYNOPSIS
  Nineyards ship for GitHub repos: push, then create a PR when none is open.
.EXAMPLE
  ./Invoke-NineyardsGitHubShip.ps1 -WorkspaceRoot C:\Repos\app -TargetBranch main -Title "fix: nav" -Json
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$SourceBranch = '',

    [Parameter(Mandatory = $true)]
    [string]$TargetBranch,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$Title,

    [string]$Description = '',
    [switch]$Draft,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'nineyards-lib.ps1')

function Assert-NineyardsBranchName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Branch
    )

    $validation = Invoke-GitCore -RepoRoot $RepoRoot `
        -GitArgs @('check-ref-format', '--branch', $Branch)
    if (-not $validation.ok) {
        throw "Invalid branch name '$Branch': $($validation.output)"
    }
}

function Invoke-NineyardsGh {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$GhArgs
    )

    Push-Location $RepoRoot
    try {
        $output = & gh @GhArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return [pscustomobject]@{
        ok     = ($code -eq 0)
        output = ($output | ForEach-Object { "$_" }) -join "`n"
        code   = $code
    }
}

$root = Get-NineyardsRepoRoot -WorkspaceRoot $WorkspaceRoot
$remoteType = Get-NineyardsRemoteType -RepoRoot $root
if ($remoteType -ne 'github') {
    throw "Invoke-NineyardsGitHubShip requires a GitHub remote (got: $remoteType)."
}

if (-not $SourceBranch) {
    $branchResult = Invoke-GitCore -RepoRoot $root -GitArgs @('branch', '--show-current')
    if (-not $branchResult.ok) { throw "Could not read current branch: $($branchResult.output)" }
    $SourceBranch = $branchResult.output.Trim()
}

Assert-NineyardsBranchName -RepoRoot $root -Branch $SourceBranch
Assert-NineyardsBranchName -RepoRoot $root -Branch $TargetBranch

Push-GitCore -RepoRoot $root -Branch $SourceBranch -SetUpstream

$list = Invoke-NineyardsGh -RepoRoot $root `
    -GhArgs @('pr', 'list', '--head', $SourceBranch, '--base', $TargetBranch, '--state', 'open', `
        '--json', 'number,url,title,baseRefName')
if (-not $list.ok) {
    throw "gh pr list failed: $($list.output)"
}

$openPullRequests = @($list.output | ConvertFrom-Json)
if ($openPullRequests.Count -gt 1) {
    throw "Multiple open pull requests found for branch '$SourceBranch'. Resolve manually."
}

if ($openPullRequests.Count -eq 1) {
    $pullRequest = $openPullRequests[0]
    $notApplied = New-Object 'System.Collections.Generic.List[string]'
    if ($Title -ne [string]$pullRequest.title) { [void]$notApplied.Add('title') }
    if ($Description) { [void]$notApplied.Add('description') }
    if ($Draft) { [void]$notApplied.Add('draft') }

    $result = [pscustomobject]@{
        success       = $true
        action        = 'pushed-existing'
        pullRequestId = [int]$pullRequest.number
        prUrl         = [string]$pullRequest.url
        sourceBranch  = $SourceBranch
        targetBranch  = [string]$pullRequest.baseRefName
        title         = [string]$pullRequest.title
        notApplied    = @($notApplied.ToArray())
    }
}
else {
    $createArgs = @('pr', 'create', '--base', $TargetBranch, '--head', $SourceBranch, '--title', $Title)
    if ($Description) { $createArgs += @('--body', $Description) }
    if ($Draft) { $createArgs += '--draft' }

    $create = Invoke-NineyardsGh -RepoRoot $root -GhArgs $createArgs
    if (-not $create.ok) {
        throw "gh pr create failed: $($create.output)"
    }

    $createdLines = @($create.output -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $prUrl = if ($createdLines.Count -gt 0) { $createdLines[-1] } else { '' }
    $createdId = 0
    if ($prUrl -match '/pull/(\d+)$') {
        $createdId = [int]$Matches[1]
    }
    else {
        $view = Invoke-NineyardsGh -RepoRoot $root -GhArgs @('pr', 'view', $SourceBranch, '--json', 'number')
        if ($view.ok) { $createdId = [int](($view.output | ConvertFrom-Json).number) }
    }

    $result = [pscustomobject]@{
        success       = $true
        action        = 'created-new'
        pullRequestId = $createdId
        prUrl         = $prUrl
        sourceBranch  = $SourceBranch
        targetBranch  = $TargetBranch
        title         = $Title
        notApplied    = @()
    }
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
}
else {
    Write-Output "$($result.action): $($result.prUrl)"
    if (@($result.notApplied).Count -gt 0) {
        Write-Output "  Not applied to the existing PR: $(@($result.notApplied) -join ', ')"
    }
}
