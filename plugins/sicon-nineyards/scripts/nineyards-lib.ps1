#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:NineyardsPackRoot = Split-Path -Parent $PSScriptRoot

function Resolve-NineyardsAdoCoreScriptPath {
    <#
    .SYNOPSIS
      Prefer newest Team Marketplace sicon-ado-core plugin script; else user pack.
    #>
    $pluginHits = New-Object 'System.Collections.Generic.List[string]'
    $pluginsRoot = Join-Path $env:USERPROFILE '.cursor\plugins'
    if (Test-Path -LiteralPath $pluginsRoot) {
        Get-ChildItem -Path $pluginsRoot -Recurse -Filter 'ado-core.ps1' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]sicon-ado-core[\\/].*[\\/]scripts[\\/]ado-core\.ps1$' } |
            ForEach-Object { [void]$pluginHits.Add($_.FullName) }
    }

    if ($pluginHits.Count -gt 0) {
        return (
            $pluginHits |
                Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending |
                Select-Object -First 1
        )
    }

    $userPack = Join-Path $env:USERPROFILE '.cursor\packs\ado-core\scripts\ado-core.ps1'
    if (Test-Path -LiteralPath $userPack) {
        return $userPack
    }

    throw 'ADO Core library not found. Install Sicon ADO Core from the Sicon Team Marketplace (or Install-UserPack -Pack ado-core / nineyards).'
}

function Resolve-NineyardsGitCoreScriptPath {
    <#
    .SYNOPSIS
      Prefer newest Team Marketplace sicon-git-core plugin script; else user pack.
    #>
    $pluginHits = New-Object 'System.Collections.Generic.List[string]'
    $pluginsRoot = Join-Path $env:USERPROFILE '.cursor\plugins'
    if (Test-Path -LiteralPath $pluginsRoot) {
        Get-ChildItem -Path $pluginsRoot -Recurse -Filter 'git-core.ps1' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]sicon-git-core[\\/].*[\\/]scripts[\\/]git-core\.ps1$' } |
            ForEach-Object { [void]$pluginHits.Add($_.FullName) }
    }

    if ($pluginHits.Count -gt 0) {
        return (
            $pluginHits |
                Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending |
                Select-Object -First 1
        )
    }

    $userPack = Join-Path $env:USERPROFILE '.cursor\packs\git-core\scripts\git-core.ps1'
    if (Test-Path -LiteralPath $userPack) {
        return $userPack
    }

    throw 'Git Core library not found. Install Sicon Git Core from the Sicon Team Marketplace (or Install-UserPack -Pack git-core / nineyards).'
}

$script:AdoCorePath = Resolve-NineyardsAdoCoreScriptPath
. $script:AdoCorePath

if (-not (Get-Command Resolve-AdoCoreEndpoints -ErrorAction SilentlyContinue)) {
    throw "ADO Core library failed to load from: $script:AdoCorePath"
}

$script:GitCorePath = Resolve-NineyardsGitCoreScriptPath
. $script:GitCorePath

$pushGitCore = Get-Command Push-GitCore -ErrorAction SilentlyContinue
if (-not $pushGitCore) {
    throw "Git Core library failed to load from: $script:GitCorePath"
}
if (-not $pushGitCore.Parameters.ContainsKey('SetUpstream')) {
    throw "Push-GitCore from '$script:GitCorePath' lacks -SetUpstream. Upgrade Sicon Git Core (Team Marketplace plugin preferred) or Install-UserPack -Pack git-core / nineyards."
}

function Get-NineyardsRepoRoot {
    param([string]$WorkspaceRoot = '')

    if ($WorkspaceRoot) {
        $root = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
        if (-not (Test-Path -LiteralPath (Join-Path $root '.git'))) {
            throw "Not a git repository: $root"
        }
        return $root
    }

    $current = (Get-Location).Path
    while ($current) {
        if (Test-Path -LiteralPath (Join-Path $current '.git')) {
            return $current
        }
        $parent = Split-Path -Parent $current
        if (-not $parent -or $parent -eq $current) { break }
        $current = $parent
    }
    throw 'Not inside a git repository.'
}

function Get-NineyardsRemoteType {
    param([string]$RepoRoot)

    $remote = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('remote', 'get-url', 'origin')
    if (-not $remote.ok -or -not $remote.output) {
        return 'unknown'
    }
    $url = $remote.output.Trim()
    if ($url -match 'tfs\.sicon\.co\.uk|dev\.azure\.com') { return 'ado' }
    if ($url -match 'github\.com') { return 'github' }
    return 'other'
}

function Get-NineyardsOpenPullRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$SourceBranch,

        [switch]$ReturnNullIfAmbiguous
    )

    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $RepoRoot
    $openPrs = Get-AdoCoreOpenPullRequestsForBranch -ApiBase $endpoints.ApiBase -SourceBranch $SourceBranch
    if (@($openPrs).Count -eq 0) { return $null }
    if (@($openPrs).Count -gt 1) {
        if ($ReturnNullIfAmbiguous) { return $null }
        throw "Multiple active pull requests found for branch '$SourceBranch'. Resolve manually."
    }
    $pr = $openPrs[0]
    $target = [string]$pr.targetRefName
    if ($target -like 'refs/heads/*') {
        $target = $target.Substring('refs/heads/'.Length)
    }
    return [pscustomobject]@{
        PullRequestId = [int]$pr.pullRequestId
        Title         = [string]$pr.title
        TargetBranch  = $target
        PrUrl         = (Get-AdoCorePullRequestWebUrl -Endpoints $endpoints -PullRequestId ([int]$pr.pullRequestId))
        Endpoints     = $endpoints
    }
}

function New-NineyardsPullRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$SourceBranch,

        [Parameter(Mandatory = $true)]
        [string]$TargetBranch,

        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Description = '',
        [int[]]$WorkItemIds = @(),
        [switch]$Draft
    )

    return New-AdoCorePullRequest -WorkspaceRoot $RepoRoot -SourceBranch $SourceBranch `
        -TargetBranch $TargetBranch -Title $Title -Description $Description `
        -WorkItemIds $WorkItemIds -Draft:$Draft
}

function Invoke-NineyardsCodeAntKick {
    <#
    .SYNOPSIS
      Post @codeant-ai: review on a new PR via ado-core (create-only callers). Does not resolve the thread.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [int]$PullRequestId
    )

    if (-not (Get-Command New-AdoCorePullRequestThread -ErrorAction SilentlyContinue)) {
        throw 'New-AdoCorePullRequestThread is not available. Update Sicon ADO Core to 0.3.0+ (Team Marketplace plugin preferred).'
    }

    return New-AdoCorePullRequestThread -WorkspaceRoot $RepoRoot -PullRequestId $PullRequestId `
        -Content '@codeant-ai: review'
}

function Get-NineyardsCapabilityLabel {
    param(
        [string]$RemoteType
    )

    if ($RemoteType -eq 'ado') { return 'plain-ado' }
    if ($RemoteType -eq 'github') { return 'github' }
    return 'plain'
}
