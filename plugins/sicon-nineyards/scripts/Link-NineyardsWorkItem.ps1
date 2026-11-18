#Requires -Version 5.1
<#
.SYNOPSIS
  Link Azure DevOps work item(s) to an existing pull request.
  Pass -LinkCommits to also link each pull request commit (Fixed in Commit).
.EXAMPLE
  ./Link-NineyardsWorkItem.ps1 -WorkspaceRoot C:\Repos\approvals -PullRequestId 12345 -WorkItemId 19224 -Json
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$WorkspaceRoot,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$PullRequestId,

    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int[]]$WorkItemId,

    [switch]$LinkCommits,

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'nineyards-lib.ps1')

$root = Get-NineyardsRepoRoot -WorkspaceRoot $WorkspaceRoot

Push-Location $root
try {
    $wit = Get-AdoCoreWitApiBase -WorkspaceRoot $root
    $endpoints = $wit.Endpoints
    $results = New-Object 'System.Collections.Generic.List[object]'

    foreach ($id in @($WorkItemId)) {
        $link = Link-AdoCoreWorkItemToPullRequest -WorkItemId $id -PullRequestId $PullRequestId `
            -Endpoints $endpoints -WitApiBase $wit.WitApiBase -LinkCommits:$LinkCommits
        [void]$results.Add([pscustomobject]@{
            workItemId        = $id
            linkedToPr        = [bool]$link.LinkedToPr
            linkedCommitCount = [int]$link.LinkedCommitCount
            linkWarning       = [string]$link.LinkWarning
        })
    }

    $out = [pscustomobject]@{
        success       = $true
        pullRequestId = $PullRequestId
        workItemLinks = @($results.ToArray())
    }

    if ($Json) {
        $out | ConvertTo-Json -Depth 6
    }
    else {
        foreach ($r in $results) {
            Write-Output "WI #$($r.workItemId): PR linked=$($r.linkedToPr), commits=$($r.linkedCommitCount)"
            if ($r.linkWarning) { Write-Output "  Warning: $($r.linkWarning)" }
        }
    }
}
finally {
    Pop-Location
}
