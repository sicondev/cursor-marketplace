#Requires -Version 5.1
<#
.SYNOPSIS
  Probe per-repo nineyards capabilities (remote type).
.EXAMPLE
  ./Get-NineyardsRepoCapabilities.ps1 -RepoRoot C:\Repos\approvals -Json
#>
param(
    [string]$RepoRoot = '',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'nineyards-lib.ps1')

$root = Get-NineyardsRepoRoot -WorkspaceRoot $RepoRoot

$remoteType = Get-NineyardsRemoteType -RepoRoot $root
$capabilityLabel = Get-NineyardsCapabilityLabel -RemoteType $remoteType

$branchResult = Invoke-GitCore -RepoRoot $root -GitArgs @('branch', '--show-current')
$currentBranch = if ($branchResult.ok) { $branchResult.output.Trim() } else { '' }

$out = [pscustomobject]@{
    repoRoot        = $root
    currentBranch   = $currentBranch
    remoteType      = $remoteType
    capabilityLabel = $capabilityLabel
}

if ($Json) {
    $out | ConvertTo-Json -Depth 4
}
else {
    Write-Output "Repo: $root"
    Write-Output "Branch: $currentBranch"
    Write-Output "Capabilities: $capabilityLabel"
    Write-Output "Remote: $remoteType"
}
