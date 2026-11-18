#Requires -Version 5.1
<#
.SYNOPSIS
  Resolve PR target branch (parent on origin) for nineyards.
.PARAMETER ExplicitTarget
  User override from command (into dev, into 260/dev).
.EXAMPLE
  ./Get-NineyardsTargetBranch.ps1 -RepoRoot C:\Repos\approvals -SourceBranch feature/foo -Json
#>
param(
    [string]$RepoRoot = '',
    [string]$SourceBranch = '',
    [string]$ExplicitTarget = '',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'nineyards-lib.ps1')

$root = Get-NineyardsRepoRoot -WorkspaceRoot $RepoRoot

if (-not $SourceBranch) {
    $branchResult = Invoke-GitCore -RepoRoot $root -GitArgs @('branch', '--show-current')
    if (-not $branchResult.ok) { throw "Could not read current branch: $($branchResult.output)" }
    $SourceBranch = $branchResult.output.Trim()
}
$SourceBranch = $SourceBranch.Trim()
if (-not $SourceBranch) {
    throw 'Could not resolve a source branch. Check out a branch or pass -SourceBranch explicitly.'
}
if ($SourceBranch -like 'refs/heads/*') {
    $SourceBranch = $SourceBranch.Substring('refs/heads/'.Length)
}
elseif ($SourceBranch -like 'origin/*') {
    $SourceBranch = $SourceBranch.Substring('origin/'.Length)
}

if ($ExplicitTarget) {
    $target = $ExplicitTarget.Trim()
    if ($target -like 'refs/heads/*') { $target = $target.Substring('refs/heads/'.Length) }
    elseif ($target -like 'origin/*') { $target = $target.Substring('origin/'.Length) }
    if ($target -eq $SourceBranch) {
        throw "PR target branch cannot equal source branch '$SourceBranch'."
    }
    $result = [pscustomobject]@{
        sourceBranch      = $SourceBranch
        targetBranch      = $target
        resolution        = 'explicit'
        openPullRequestId = 0
    }
    if ($Json) { $result | ConvertTo-Json } else { Write-Output "$target (explicit)" }
    exit 0
}

$remoteType = Get-NineyardsRemoteType -RepoRoot $root
if ($remoteType -eq 'ado') {
    $openPr = Get-NineyardsOpenPullRequest -RepoRoot $root -SourceBranch $SourceBranch -ReturnNullIfAmbiguous
    if ($openPr) {
        if ($openPr.TargetBranch -eq $SourceBranch) {
            throw "Open PR target branch cannot equal source branch '$SourceBranch'."
        }
        $result = [pscustomobject]@{
            sourceBranch      = $SourceBranch
            targetBranch      = $openPr.TargetBranch
            resolution        = 'existing-pr'
            openPullRequestId = $openPr.PullRequestId
        }
        if ($Json) { $result | ConvertTo-Json } else { Write-Output "$($openPr.TargetBranch) (existing-pr #$($openPr.PullRequestId))" }
        exit 0
    }
}

$upstream = Invoke-GitCore -RepoRoot $root -GitArgs @('rev-parse', '--abbrev-ref', '@{upstream}')
if ($upstream.ok -and $upstream.output -and $upstream.output.Trim() -and $upstream.output -notmatch 'fatal:|HEAD') {
    $up = $upstream.output.Trim()
    if ($up -match '^origin/(.+)$') {
        $upstreamTarget = $Matches[1]
        if ($upstreamTarget -ne $SourceBranch) {
            $result = [pscustomobject]@{
                sourceBranch      = $SourceBranch
                targetBranch      = $upstreamTarget
                resolution        = 'upstream'
                openPullRequestId = 0
            }
            if ($Json) { $result | ConvertTo-Json } else { Write-Output "$upstreamTarget (upstream)" }
            exit 0
        }
    }
}

$candidates = New-Object 'System.Collections.Generic.List[string]'
$refPatterns = New-Object 'System.Collections.Generic.List[string]'
[void]$refPatterns.Add('refs/remotes/origin/dev')
[void]$refPatterns.Add('refs/remotes/origin/main')
[void]$refPatterns.Add('refs/remotes/origin/master')
if ($SourceBranch -match '^([^/]+)/.+$') {
    [void]$refPatterns.Add("refs/remotes/origin/$($Matches[1])/dev")
}
$remoteBranches = Invoke-GitCore -RepoRoot $root `
    -GitArgs (@('for-each-ref', '--format=%(refname:short)') + @($refPatterns.ToArray()))
if ($remoteBranches.ok -and $remoteBranches.output) {
    foreach ($line in @($remoteBranches.output -split "`n")) {
        $ref = $line.Trim()
        if (-not $ref) { continue }
        $name = if ($ref -like 'origin/*') { $ref.Substring(7) } else { $ref }
        if ($name -and $name -ne $SourceBranch) {
            [void]$candidates.Add($name)
        }
    }
}

$bestTarget = ''
$bestResolution = 'nearest-merge-base'
$rankedCandidates = New-Object 'System.Collections.Generic.List[object]'
$sourceRevision = "origin/$SourceBranch"
$sourceRevisionCheck = Invoke-GitCore -RepoRoot $root -GitArgs @('rev-parse', '--verify', '--quiet', $sourceRevision)
if (-not $sourceRevisionCheck.ok) {
    $sourceRevision = $SourceBranch
    $sourceRevisionCheck = Invoke-GitCore -RepoRoot $root -GitArgs @('rev-parse', '--verify', '--quiet', $sourceRevision)
}
if (-not $sourceRevisionCheck.ok) {
    throw "Could not resolve source branch '$SourceBranch' locally or on origin."
}
foreach ($candidate in @($candidates | Sort-Object -Unique)) {
    $mergeBase = Invoke-GitCore -RepoRoot $root -GitArgs @('merge-base', "origin/$candidate", $sourceRevision)
    if (-not $mergeBase.ok -or -not $mergeBase.output.Trim()) { continue }

    $baseCommit = $mergeBase.output.Trim()
    $distanceResult = Invoke-GitCore -RepoRoot $root -GitArgs @('rev-list', '--count', "$baseCommit..$sourceRevision")
    $distance = 0
    if ($distanceResult.ok -and [int]::TryParse($distanceResult.output.Trim(), [ref]$distance)) {
        [void]$rankedCandidates.Add([pscustomobject]@{
            name     = $candidate
            distance = $distance
        })
    }
}

if ($rankedCandidates.Count -gt 0) {
    $nearestDistance = ($rankedCandidates | Measure-Object -Property distance -Minimum).Minimum
    $nearest = @($rankedCandidates | Where-Object { $_.distance -eq $nearestDistance })
    if ($nearest.Count -eq 1) {
        $bestTarget = $nearest[0].name
    }
    else {
        $ambiguousTargets = ($nearest.name | Sort-Object) -join ', '
        throw "Target branch topology is ambiguous between: $ambiguousTargets. Pass -ExplicitTarget."
    }
}

if (-not $bestTarget) {
    throw "Could not infer a PR target from repository topology. Pass -ExplicitTarget."
}
if ($bestTarget -eq $SourceBranch) {
    throw "Could not resolve a PR target different from source branch '$SourceBranch'. Pass -ExplicitTarget."
}

$final = [pscustomobject]@{
    sourceBranch      = $SourceBranch
    targetBranch      = $bestTarget
    resolution        = $bestResolution
    openPullRequestId = 0
}

if ($Json) {
    $final | ConvertTo-Json
}
else {
    Write-Output "$bestTarget ($bestResolution)"
}
