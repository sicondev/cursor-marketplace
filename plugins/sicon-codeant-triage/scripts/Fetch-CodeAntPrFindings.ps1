#Requires -Version 5.1
<#
.SYNOPSIS
  Fetches unresolved CodeAnt file threads from Azure DevOps for manual triage.
.DESCRIPTION
  Reads pull-request threads authored by "Code Ant" with file paths, filters to
  active/unresolved status, and emits **Path:** / **Line:** / **Comment:** blocks.

  Requires Windows integrated auth to on-prem Azure DevOps (same as git push).
.PARAMETER PullRequestId
  Azure DevOps pull request id (e.g. 28305).
.PARAMETER Json
  Emit machine-readable summary to stdout instead of triage markdown blocks.
.EXAMPLE
  ./Fetch-CodeAntPrFindings.ps1 -PullRequestId 28305
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$PullRequestId,

    [string]$Collection = '',
    [string]$Project = '',
    [string]$Repository = '',
    [string]$ServerUrl = '',

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

$endpoints = Resolve-AdoCodeAntTriageEndpoints -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
$ServerUrl = $endpoints.ServerUrl
$Collection = $endpoints.Collection
$Project = $endpoints.Project
$Repository = $endpoints.Repository
$apiBase = $endpoints.ApiBase
$prUri = "$apiBase/pullRequests/$PullRequestId`?api-version=7.0"
$threadsUri = "$apiBase/pullRequests/$PullRequestId/threads?api-version=7.0"

$pr = Invoke-RestMethod -Uri $prUri -Method Get -UseDefaultCredentials
$threadsResponse = Invoke-RestMethod -Uri $threadsUri -Method Get -UseDefaultCredentials

$sourceBranch = ($pr.sourceRefName -replace '^refs/heads/', '')
$targetBranch = ($pr.targetRefName -replace '^refs/heads/', '')
$reviewers = $null
if ($pr.PSObject.Properties.Name -contains 'reviewers') {
    $reviewers = $pr.reviewers
}
$approved = Get-RequiredReviewerApproved -Reviewers $reviewers
$prUrl = @(
    $ServerUrl
    'tfs'
    [Uri]::EscapeDataString($Collection)
    [Uri]::EscapeDataString($Project)
    '_git'
    [Uri]::EscapeDataString($Repository)
    'pullrequest'
    [string]$PullRequestId
) -join '/'

$threadList = @()
if ($threadsResponse.PSObject.Properties.Name -contains 'value' -and $null -ne $threadsResponse.value) {
    $threadList = @($threadsResponse.value)
}

$allFindings = @(Get-CodeAntFileFindingsFromThreads -Threads $threadList)
# Nitpicks are comment-equivalent findings embedded in a meta thread; they join
# the per-finding loop (and activeFindingCount) like file findings.
$allFindings = @($allFindings) + @(Get-CodeAntNitpickFindingsFromThreads -Threads $threadList)
$counts = Get-CodeAntFindingCounts -Findings $allFindings
$findings = New-Object 'System.Collections.Generic.List[object]'
$activeIndex = 0
foreach ($finding in $allFindings) {
    if (-not (Test-IsActiveAdoThread -Status $finding.ThreadStatus)) { continue }
    $activeIndex++
    $finding.Number = $activeIndex
    [void]$findings.Add($finding)
}
$findings = $findings
# Quality Gate security findings stay separate: no ADO thread of their own, so
# they are NOT folded into activeFindingCount / findingCount (consumer compat).
# Triage is only done when activeFindingCount == 0 AND securityFindingCount == 0.
$qualityGateParsed = Get-CodeAntQualityGateFromThreads -Threads $threadList
$securityFindings = @()
$qualityGate = $null
if ($null -ne $qualityGateParsed) {
    $securityFindings = @($qualityGateParsed.securityFindings)
    $qualityGate = [pscustomobject]@{
        status               = $qualityGateParsed.status
        commit               = $qualityGateParsed.commit
        scanTime             = $qualityGateParsed.scanTime
        resultsUrl           = $qualityGateParsed.resultsUrl
        metaThreadId         = $qualityGateParsed.metaThreadId
        parentCommentId      = $(if ($qualityGateParsed.PSObject.Properties.Name -contains 'parentCommentId') { $qualityGateParsed.parentCommentId } else { $null })
        gates                = $qualityGateParsed.gates
        securityFindingCount = $securityFindings.Count
    }
}
$retriggerMayBeInFlight = (Test-HasActiveCodeAntRetriggerThread -Threads $threadList) -or (
    Test-HasRecentCodeAntRetriggerThread -Threads $threadList
)

$prStatus = ''
if ($pr.PSObject.Properties.Name -contains 'status' -and $null -ne $pr.status) {
    $prStatus = [string]$pr.status
}

$summary = [pscustomobject]@{
    pullRequestId        = $PullRequestId
    title                = $pr.title
    status               = $prStatus
    sourceBranch         = $sourceBranch
    targetBranch         = $targetBranch
    prUrl                = $prUrl
    approved             = $approved
    activeFindingCount   = $counts.active
    fixedFindingCount    = $counts.fixed
    findingCount         = $counts.active
    findings             = $findings
    qualityGate          = $qualityGate
    securityFindings     = $securityFindings
    securityFindingCount = $securityFindings.Count
}

if ($Json) {
    $summary | ConvertTo-Json -Depth 6
    return
}

Write-Output ('# CodeAnt PR ' + $PullRequestId + ' - ' + $sourceBranch + ' -> ' + $targetBranch)
Write-Output ('PR: ' + $prUrl)
Write-Output (
    'Approved (required reviewer): ' + $approved +
    ' | Active findings: ' + $counts.active +
    ' | Fixed: ' + $counts.fixed +
    ' | Security findings: ' + $securityFindings.Count
)
if ($null -ne $qualityGate) {
    Write-Output ('Quality Gate: ' + $qualityGate.status + $(if ($qualityGate.resultsUrl) { ' | ' + $qualityGate.resultsUrl } else { '' }))
}
Write-Output ''

if (-not $approved) {
    Write-Output '>> Note: PR may not be approved yet; CodeAnt typically runs after approval. Findings below are still listed if present.'
    Write-Output ''
}

if ($retriggerMayBeInFlight -and $counts.active -gt 0) {
    Write-Output '>> Note: A recent @codeant-ai: review or #codeant-ai: review request may still be in progress. Re-fetch after push/retrigger before triaging.'
    Write-Output ''
}

if ($findings.Count -eq 0 -and $securityFindings.Count -eq 0) {
    Write-Output '>> No unresolved CodeAnt file comments on this PR.'
    return
}

foreach ($finding in $findings) {
    Write-Output (Get-CodeAntFindingScaffold -Finding $finding -Heading "Finding #$($finding.Number) of $($findings.Count)")
    Write-Output ''
}

if ($securityFindings.Count -gt 0) {
    Write-Output '## Quality Gate security findings (no per-finding ADO thread - see triage disposition model)'
    $secIndex = 0
    foreach ($sec in $securityFindings) {
        $secIndex++
        Write-Output (Get-CodeAntFindingScaffold -Finding $sec -Heading "Security finding #S$secIndex of $($securityFindings.Count)")
        if ($sec.resultsUrl) { Write-Output ''; Write-Output '**Results**'; Write-Output $sec.resultsUrl }
        Write-Output ''
    }
}
