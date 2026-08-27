#Requires -Version 5.1
<#
.SYNOPSIS
  Smoke test for Fetch-CodeAntPrFindings.ps1 JSON shape against a real PR.
.PARAMETER PullRequestId
  Azure DevOps pull request id (required — no Approvals-specific default).
.EXAMPLE
  & "$env:USERPROFILE\.cursor\packs\codeant-triage\scripts\Test-CodeAntPrFetch.ps1" -PullRequestId 28305
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$PullRequestId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$fetchScript = Join-Path $scriptDir 'Fetch-CodeAntPrFindings.ps1'

$json = & $fetchScript -PullRequestId $PullRequestId -Json | ConvertFrom-Json

if ($null -eq $json.pullRequestId) { throw 'Missing pullRequestId in JSON response.' }
if (-not ($json.PSObject.Properties.Name -contains 'findings')) { throw 'Missing findings array in JSON response.' }
if (-not ($json.PSObject.Properties.Name -contains 'activeFindingCount')) { throw 'Missing activeFindingCount in JSON response.' }
if (-not ($json.PSObject.Properties.Name -contains 'fixedFindingCount')) { throw 'Missing fixedFindingCount in JSON response.' }

if ($json.activeFindingCount -lt 1) {
    Write-Output "OK: PR $PullRequestId fetch succeeded with 0 active findings (structure valid, fixed=$($json.fixedFindingCount))."
    return
}

$first = @($json.findings)[0]
if ($null -eq $first -or -not $first.Path) { throw 'First finding missing Path.' }
if (-not $first.Comment) { throw 'First finding missing Comment.' }

Write-Output "OK: PR $PullRequestId returned $($json.activeFindingCount) active findings (first: $($first.Path))"
