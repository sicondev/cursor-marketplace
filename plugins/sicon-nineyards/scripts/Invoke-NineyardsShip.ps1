#Requires -Version 5.1
<#
.SYNOPSIS
  Nineyards ship for ADO repos: push, create PR if needed, optional WI on create.
.EXAMPLE
  ./Invoke-NineyardsShip.ps1 -WorkspaceRoot C:\Repos\react-sicon-hub -TargetBranch dev -Title "fix: nav" -Json
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [string]$SourceBranch = '',
    [Parameter(Mandatory = $true)]
    [string]$TargetBranch,

    [Parameter(Mandatory = $true)]
    [string]$Title,

    [string]$Description = '',
    [int[]]$WorkItemId = @(),
    [switch]$Draft,
    [switch]$SkipCodeAnt,
    [switch]$KickCodeAnt,
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

$root = Get-NineyardsRepoRoot -WorkspaceRoot $WorkspaceRoot
$remoteType = Get-NineyardsRemoteType -RepoRoot $root
if ($remoteType -ne 'ado') {
    throw "Invoke-NineyardsShip requires an ADO remote (got: $remoteType)."
}

if (-not $SourceBranch) {
    $branchResult = Invoke-GitCore -RepoRoot $root -GitArgs @('branch', '--show-current')
    if (-not $branchResult.ok) { throw "Could not read current branch: $($branchResult.output)" }
    $SourceBranch = $branchResult.output.Trim()
}

Assert-NineyardsBranchName -RepoRoot $root -Branch $SourceBranch

$openPr = Get-NineyardsOpenPullRequest -RepoRoot $root -SourceBranch $SourceBranch

Push-GitCore -RepoRoot $root -Branch $SourceBranch -SetUpstream

if ($openPr) {
    $notApplied = New-Object 'System.Collections.Generic.List[string]'
    if ($Title -ne [string]$openPr.Title) { [void]$notApplied.Add('title') }
    if ($TargetBranch -ne [string]$openPr.TargetBranch) { [void]$notApplied.Add('targetBranch') }
    if ($Description) { [void]$notApplied.Add('description') }
    if ($Draft) { [void]$notApplied.Add('draft') }
    if (@($WorkItemId).Count -gt 0) { [void]$notApplied.Add('workItemId') }

    $result = [pscustomobject]@{
        success          = $true
        action           = 'pushed-existing'
        pullRequestId    = $openPr.PullRequestId
        prUrl            = $openPr.PrUrl
        sourceBranch     = $SourceBranch
        targetBranch     = $openPr.TargetBranch
        title            = $openPr.Title
        notApplied       = @($notApplied.ToArray())
        codeAntTrigger   = 'skipped-existing-pr'
    }
    if ($Json) {
        $result | ConvertTo-Json -Depth 4
    }
    else {
        Write-Output "Pushed to existing PR #$($openPr.PullRequestId)"
        Write-Output $openPr.PrUrl
        if ($notApplied.Count -gt 0) {
            Write-Output "  Not applied to the existing PR: $($notApplied -join ', ')"
        }
    }
    exit 0
}

$pr = New-NineyardsPullRequest -RepoRoot $root -SourceBranch $SourceBranch `
    -TargetBranch $TargetBranch -Title $Title -Description $Description `
    -WorkItemIds $WorkItemId -Draft:$Draft

# Default: do not post @codeant-ai: review (CodeAnt usually auto-starts). Opt in with -KickCodeAnt.
# -SkipCodeAnt remains a legacy no-op skip (still does not post).
$codeAntTrigger = 'skipped-default'
$codeAntWarning = $null
$codeAntThreadId = $null
if ($SkipCodeAnt) {
    $codeAntTrigger = 'skipped-flag'
}
elseif ($KickCodeAnt) {
    try {
        $kick = Invoke-NineyardsCodeAntKick -RepoRoot $root -PullRequestId ([int]$pr.PullRequestId)
        $codeAntTrigger = 'posted'
        $codeAntThreadId = [int]$kick.ThreadId
    }
    catch {
        $codeAntTrigger = 'warn'
        $codeAntWarning = [string]$_.Exception.Message
        Write-Warning "CodeAnt trigger failed (PR created): $codeAntWarning"
    }
}

$result = [pscustomobject]@{
    success           = $true
    action            = 'created-new'
    pullRequestId     = $pr.PullRequestId
    prUrl             = $pr.PrUrl
    sourceBranch      = $SourceBranch
    targetBranch      = $TargetBranch
    title             = $pr.Title
    notApplied        = @()
    codeAntTrigger    = $codeAntTrigger
    codeAntThreadId   = $codeAntThreadId
    codeAntWarning    = $codeAntWarning
}

if ($Json) {
    $result | ConvertTo-Json -Depth 4
}
else {
    Write-Output "Created PR #$($pr.PullRequestId): $($pr.Title)"
    Write-Output $pr.PrUrl
    switch ($codeAntTrigger) {
        'posted' { Write-Output "CodeAnt: posted @codeant-ai: review (thread $codeAntThreadId)" }
        'skipped-default' { Write-Output 'CodeAnt: skipped by default (pass -KickCodeAnt to post)' }
        'skipped-flag' { Write-Output 'CodeAnt: skipped (-SkipCodeAnt)' }
        'warn' { Write-Output "CodeAnt: warn - $codeAntWarning" }
    }
}
