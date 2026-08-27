#Requires -Version 5.1
<#
.SYNOPSIS
  Resolve CodeAnt Triage user-data and shipped-runtime paths (user pack or plugin).
.DESCRIPTION
  User catalog/prefs: %USERPROFILE%\.cursor\codeant-triage\
  Scripts/core: parent of this script (packs/codeant-triage or sicon-codeant-triage plugin tree).
.EXAMPLE
  & "$PSScriptRoot\Get-CodeAntTriagePaths.ps1" -Json
#>
param(
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.cursor'),
    [string]$ScriptsRoot = '',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

if ([string]::IsNullOrWhiteSpace($ScriptsRoot)) {
    $ScriptsRoot = $PSScriptRoot
}

$paths = Get-CodeAntTriagePathSet -ProfileRoot $ProfileRoot -ScriptsRoot $ScriptsRoot
if ($Json) {
    Write-Output ($paths | ConvertTo-Json -Compress)
    return
}

Write-Output "profileRoot: $($paths.profileRoot)"
Write-Output "userDataRoot: $($paths.userDataRoot)"
Write-Output "userCatalog: $($paths.userCatalog)"
Write-Output "prefs: $($paths.prefs)"
Write-Output "scriptsRoot: $($paths.scriptsRoot)"
Write-Output "installRoot: $($paths.installRoot)"
Write-Output "coreCatalog: $($paths.coreCatalog)"
Write-Output "uapscanFixLoop: $($paths.uapscanFixLoop)"
Write-Output "templateRoot: $($paths.templateRoot)"
Write-Output "legacyPackRoot: $($paths.legacyPackRoot)"
