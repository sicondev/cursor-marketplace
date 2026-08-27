#Requires -Version 5.1
<#
.SYNOPSIS
  Print CodeAnt Triage promote preferences (scoped defaults + action catalog).
.EXAMPLE
  & "$env:USERPROFILE\.cursor\packs\codeant-triage\scripts\Get-CodeAntPromotePreference.ps1"
.EXAMPLE
  powershell -NoProfile -File <plugin-root>\scripts\Get-CodeAntPromotePreference.ps1
.EXAMPLE
  & "...\Get-CodeAntPromotePreference.ps1" -RemoteId 'Collection/Project/Repo'
.EXAMPLE
  & "...\Get-CodeAntPromotePreference.ps1" -Json
#>
param(
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.cursor'),
    [string]$RemoteId = '',
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

function ConvertTo-PromotePrefsV2 {
    param([Parameter(Mandatory = $true)]$Prefs)

    $version = 1
    if ($null -ne $Prefs.PSObject.Properties['version']) {
        $parsedVersion = 0
        if ([int]::TryParse([string]$Prefs.version, [ref]$parsedVersion)) {
            $version = $parsedVersion
        }
    }

    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($a in @($Prefs.actions)) {
        if ($null -eq $a) { continue }
        $scope = '*'
        if ($null -ne $a.PSObject.Properties['scope'] -and -not [string]::IsNullOrWhiteSpace([string]$a.scope)) {
            $scope = [string]$a.scope
        }
        $actions.Add([pscustomobject]@{
            id     = [string]$a.id
            scope  = $scope
            label  = [string]$a.label
            kind   = if ($a.PSObject.Properties['kind']) { [string]$a.kind } else { 'follow-up' }
            prompt = [string]$a.prompt
        }) | Out-Null
    }

    $defaults = @{}
    if ($version -ge 2 -and $null -ne $Prefs.PSObject.Properties['defaultsByScope'] -and $null -ne $Prefs.defaultsByScope) {
        foreach ($p in $Prefs.defaultsByScope.PSObject.Properties) {
            $defaults[$p.Name] = $p.Value
        }
    }
    elseif ($null -ne $Prefs.PSObject.Properties['defaultActionId'] -and -not [string]::IsNullOrWhiteSpace([string]$Prefs.defaultActionId)) {
        $defaults['*'] = [string]$Prefs.defaultActionId
    }

    return [pscustomobject]@{
        version          = 2
        defaultsByScope  = [pscustomobject]$defaults
        actions          = @($actions.ToArray())
    }
}

function Resolve-DefaultForRemote {
    param(
        [Parameter(Mandatory = $true)]$PrefsV2,
        [string]$RemoteId
    )
    $map = $PrefsV2.defaultsByScope
    if ($null -eq $map) { return $null }

    if (-not [string]::IsNullOrWhiteSpace($RemoteId)) {
        foreach ($p in $map.PSObject.Properties) {
            if ($p.Name -eq $RemoteId) { return $p.Value }
        }
        foreach ($p in $map.PSObject.Properties) {
            if ([string]::Equals($p.Name, $RemoteId, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $p.Value
            }
        }
    }
    foreach ($p in $map.PSObject.Properties) {
        if ($p.Name -eq '*') { return $p.Value }
    }
    return $null
}

Copy-CodeAntTriageUserDataFromLegacyPack -ProfileRoot $ProfileRoot | Out-Null
$paths = Get-CodeAntTriagePathSet -ProfileRoot $ProfileRoot -ScriptsRoot $PSScriptRoot
$prefsPath = $paths.prefs

if (-not (Test-Path -LiteralPath $prefsPath)) {
    throw "Missing $prefsPath - run Initialize-CodeAntTriageCatalog.ps1 (user pack or Team Marketplace plugin)."
}

$raw = Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8
$prefs = ConvertTo-PromotePrefsV2 -Prefs ($raw | ConvertFrom-Json)

if ($Json) {
    Write-Output ($prefs | ConvertTo-Json -Depth 8)
    return
}

$resolved = Resolve-DefaultForRemote -PrefsV2 $prefs -RemoteId $RemoteId
if ($null -eq $resolved -or [string]::IsNullOrWhiteSpace([string]$resolved)) {
    Write-Output 'resolvedDefault: (none)'
}
else {
    Write-Output "resolvedDefault: $resolved"
}

Write-Output 'defaultsByScope:'
$anyDefault = $false
foreach ($p in $prefs.defaultsByScope.PSObject.Properties) {
    $anyDefault = $true
    Write-Output "  $($p.Name) -> $($p.Value)"
}
if (-not $anyDefault) {
    Write-Output '  (none)'
}

$actions = @($prefs.actions)
Write-Output "actions: $($actions.Count)"
foreach ($action in $actions) {
    $applicable = (
        $action.scope -eq '*' -or
        [string]::IsNullOrWhiteSpace($RemoteId) -or
        [string]::Equals($action.scope, $RemoteId, [System.StringComparison]::OrdinalIgnoreCase)
    )
    $mark = if ($applicable -and $action.id -eq $resolved) { ' *' } else { '' }
    $flag = if ($applicable) { '' } else { ' [filtered]' }
    Write-Output "  - $($action.id)$mark | scope=$($action.scope) | $($action.label) | prompt=$($action.prompt)$flag"
}

Write-Output "path: $prefsPath"
