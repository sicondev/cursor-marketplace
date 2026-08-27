#Requires -Version 5.1
<#
.SYNOPSIS
  Seed user catalog and promote-preferences when missing (Copy-IfMissing). Migrates once from the legacy packs path.
.DESCRIPTION
  Templates live beside this script (user pack or plugin): <installRoot>/templates/
  User files: %USERPROFILE%\.cursor\codeant-triage\ (survives pack/plugin reinstall).
  Does not recreate anti-patterns.core.md (reinstall the pack or plugin for that).
.EXAMPLE
  & "$env:USERPROFILE\.cursor\packs\codeant-triage\scripts\Initialize-CodeAntTriageCatalog.ps1"
.EXAMPLE
  powershell -NoProfile -File <plugin-root>\scripts\Initialize-CodeAntTriageCatalog.ps1
#>
param(
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.cursor'),
    [string]$TemplateRoot = '',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

$paths = Get-CodeAntTriagePathSet -ProfileRoot $ProfileRoot -ScriptsRoot $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($TemplateRoot)) {
    $TemplateRoot = $paths.templateRoot
}
$TemplateRoot = [IO.Path]::GetFullPath($TemplateRoot)
if (-not (Test-Path -LiteralPath $TemplateRoot)) {
    throw @"
Templates not found at: $TemplateRoot
Install codeant-triage (user pack or Team Marketplace plugin), then re-run this script from that install's scripts/ folder.
"@
}

$userDataRoot = $paths.userDataRoot
Copy-CodeAntTriageUserDataFromLegacyPack -ProfileRoot $paths.profileRoot -WhatIf:$WhatIf

function Copy-IfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FileName
    )
    $src = Join-Path $TemplateRoot $FileName
    $dest = Join-Path $userDataRoot $FileName
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Missing template: $src"
    }
    if (Test-Path -LiteralPath $dest) {
        Write-Output "Skip (exists): $dest"
        return
    }
    if ($WhatIf) {
        Write-Output "[WhatIf] copy $src -> $dest"
        return
    }
    if (-not (Test-Path -LiteralPath $userDataRoot)) {
        New-Item -ItemType Directory -Force -Path $userDataRoot | Out-Null
    }
    Copy-Item -LiteralPath $src -Destination $dest -Force
    Write-Output "Seeded: $dest"
}

Copy-IfMissing -FileName 'anti-patterns.user.md'
Copy-IfMissing -FileName 'promote-preferences.json'

Write-Output 'Done.'
