#Requires -Version 5.1
<#
.SYNOPSIS
  Set CodeAnt Triage promote defaults and/or add a scoped catalog action (no prune - edit JSON for that).
.EXAMPLE
  & "...\Set-CodeAntPromotePreference.ps1" -AddAction -Id unit-test -Label 'Generate a unit test' -Prompt 'Generate a unit test?' -Scope '*' -SetAsDefault
.EXAMPLE
  & "...\Set-CodeAntPromotePreference.ps1" -DefaultActionId unit-test -Scope 'Collection/Project/Repo'
.EXAMPLE
  & "...\Set-CodeAntPromotePreference.ps1" -ClearDefault -Scope '*'
#>
param(
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.cursor'),
    [string]$Scope = '*',
    [string]$DefaultActionId,
    [switch]$ClearDefault,
    [switch]$AddAction,
    [string]$Id,
    [string]$Label,
    [string]$Prompt,
    [ValidateSet('follow-up')]
    [string]$Kind = 'follow-up',
    [switch]$SetAsDefault,
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

if ([string]::IsNullOrWhiteSpace($Scope)) {
    $Scope = '*'
}

if ($ClearDefault -and (
        -not [string]::IsNullOrWhiteSpace($DefaultActionId) -or
        $SetAsDefault
    )) {
    throw 'Use -ClearDefault, -DefaultActionId, or -SetAsDefault, not a combination.'
}
if ($AddAction) {
    if ([string]::IsNullOrWhiteSpace($Id) -or [string]::IsNullOrWhiteSpace($Label) -or [string]::IsNullOrWhiteSpace($Prompt)) {
        throw '-AddAction requires -Id, -Label, and -Prompt.'
    }
}

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
        $actionScope = '*'
        if ($null -ne $a.PSObject.Properties['scope'] -and -not [string]::IsNullOrWhiteSpace([string]$a.scope)) {
            $actionScope = [string]$a.scope
        }
        $actions.Add([pscustomobject]@{
            id     = [string]$a.id
            scope  = $actionScope
            label  = [string]$a.label
            kind   = if ($a.PSObject.Properties['kind']) { [string]$a.kind } else { 'follow-up' }
            prompt = [string]$a.prompt
        }) | Out-Null
    }

    $defaultsHash = [ordered]@{}
    if ($version -ge 2 -and $null -ne $Prefs.PSObject.Properties['defaultsByScope'] -and $null -ne $Prefs.defaultsByScope) {
        foreach ($p in $Prefs.defaultsByScope.PSObject.Properties) {
            $defaultsHash[$p.Name] = $p.Value
        }
    }
    elseif ($null -ne $Prefs.PSObject.Properties['defaultActionId'] -and -not [string]::IsNullOrWhiteSpace([string]$Prefs.defaultActionId)) {
        $defaultsHash['*'] = [string]$Prefs.defaultActionId
    }

    return @{
        Actions  = $actions
        Defaults = $defaultsHash
    }
}

Copy-CodeAntTriageUserDataFromLegacyPack -ProfileRoot $ProfileRoot | Out-Null
$paths = Get-CodeAntTriagePathSet -ProfileRoot $ProfileRoot -ScriptsRoot $PSScriptRoot
$prefsPath = $paths.prefs

if (-not (Test-Path -LiteralPath $prefsPath)) {
    throw "Missing $prefsPath - run Initialize-CodeAntTriageCatalog.ps1 (user pack or Team Marketplace plugin)."
}

$rawPrefs = (Get-Content -LiteralPath $prefsPath -Raw -Encoding UTF8) | ConvertFrom-Json
$normalized = ConvertTo-PromotePrefsV2 -Prefs $rawPrefs
$actions = $normalized.Actions
$defaults = $normalized.Defaults

if ($AddAction) {
    $match = $actions | Where-Object {
        $_.id -eq $Id -and [string]::Equals([string]$_.scope, $Scope, [System.StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1
    if ($match) {
        $match.label = $Label
        $match.prompt = $Prompt
        $match.kind = $Kind
        $match.scope = $Scope
        Write-Output "Updated action: $Id (scope=$Scope)"
    }
    else {
        $actions.Add([pscustomobject]@{
            id     = $Id
            scope  = $Scope
            label  = $Label
            kind   = $Kind
            prompt = $Prompt
        }) | Out-Null
        Write-Output "Added action: $Id (scope=$Scope)"
    }
}

if ($ClearDefault) {
    if ($defaults.Contains($Scope)) {
        $defaults.Remove($Scope)
    }
    Write-Output "Cleared defaultsByScope[$Scope]"
}
elseif (-not [string]::IsNullOrWhiteSpace($DefaultActionId)) {
    $found = $actions | Where-Object {
        $_.id -eq $DefaultActionId -and (
            $_.scope -eq '*' -or
            [string]::Equals([string]$_.scope, $Scope, [System.StringComparison]::OrdinalIgnoreCase)
        )
    } | Select-Object -First 1
    if (-not $found) {
        throw "Action id '$DefaultActionId' not in catalog for scope '$Scope'. Add it with -AddAction -Scope first."
    }
    $defaults[$Scope] = $DefaultActionId
    Write-Output "defaultsByScope[$Scope] = $DefaultActionId"
}
elseif ($SetAsDefault) {
    if (-not $AddAction) {
        throw '-SetAsDefault requires -AddAction (or pass -DefaultActionId).'
    }
    $defaults[$Scope] = $Id
    Write-Output "defaultsByScope[$Scope] = $Id"
}

$defaultsObj = [pscustomobject]@{}
foreach ($key in $defaults.Keys) {
    $defaultsObj | Add-Member -NotePropertyName $key -NotePropertyValue $defaults[$key] -Force
}

$out = [pscustomobject]@{
    version         = 2
    defaultsByScope = $defaultsObj
    actions         = $actions
}

$json = $out | ConvertTo-Json -Depth 8
if ($WhatIf) {
    Write-Output "[WhatIf] would write $prefsPath"
    Write-Output $json
    return
}

Set-Content -LiteralPath $prefsPath -Value $json -Encoding UTF8
Write-Output "Wrote: $prefsPath"
