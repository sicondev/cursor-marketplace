#Requires -Version 5.1
<#
.SYNOPSIS
  Resolve canonical CodeAnt Triage repo scope from git remote.origin.url.
.DESCRIPTION
  Emits JSON: remoteId (Collection/Project/Repository), displayName (folder leaf),
  plus collection/project/repository/workspaceRoot. On-prem TFS remotes only.
.EXAMPLE
  & "$env:USERPROFILE\.cursor\packs\codeant-triage\scripts\Get-CodeAntRepoScope.ps1"
.EXAMPLE
  & "...\Get-CodeAntRepoScope.ps1" -WorkspaceRoot C:\Repos\react-sicon-hub
#>
param(
    [string]$WorkspaceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $WorkspaceRoot = Get-GitWorkspaceRoot
}
else {
    $WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
}

if (-not (Test-Path -LiteralPath $WorkspaceRoot -PathType Container)) {
    throw "WorkspaceRoot does not exist or is not a directory: $WorkspaceRoot"
}

# A worktree uses a .git file, while a standard clone uses a .git directory.
$gitMetadataPath = Join-Path $WorkspaceRoot '.git'
if (-not (Test-Path -LiteralPath $gitMetadataPath)) {
    throw "WorkspaceRoot is not a Git repository: $WorkspaceRoot"
}

$ado = Get-AdoDefaultsFromGitRemote -WorkspaceRoot $WorkspaceRoot
$remoteId = '{0}/{1}/{2}' -f $ado.Collection, $ado.Project, $ado.Repository
$displayName = Split-Path -Leaf $WorkspaceRoot

[PSCustomObject]@{
    remoteId      = $remoteId
    displayName   = $displayName
    collection    = $ado.Collection
    project       = $ado.Project
    repository    = $ado.Repository
    workspaceRoot = $WorkspaceRoot
} | ConvertTo-Json -Compress
