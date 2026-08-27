#Requires -Version 5.1
<#
.SYNOPSIS
  Path helper, init seed, legacy packs migrate, no public-xml copy.
.EXAMPLE
  & "$PSScriptRoot\Test-CodeAntTriagePaths.ps1"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'codeant-triage-lib.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("codeant-triage-paths-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
    $contentRoot = Split-Path -Parent $scriptDir
    $paths = Get-CodeAntTriagePathSet -ProfileRoot $tempRoot -ScriptsRoot $scriptDir
    Assert-True ($paths.userDataRoot -eq (Join-Path $tempRoot 'codeant-triage')) 'userDataRoot is <profile>/codeant-triage'
    Assert-True ($paths.userCatalog -eq (Join-Path $paths.userDataRoot 'anti-patterns.user.md')) 'userCatalog filename'
    Assert-True ($paths.prefs -eq (Join-Path $paths.userDataRoot 'promote-preferences.json')) 'prefs filename'
    Assert-True ($paths.scriptsRoot -eq ([IO.Path]::GetFullPath($scriptDir))) 'scriptsRoot is this scripts dir'
    Assert-True ($paths.installRoot -eq ([IO.Path]::GetFullPath($contentRoot))) 'installRoot is parent of scripts'
    Assert-True ($paths.coreCatalog -eq (Join-Path $contentRoot 'anti-patterns.core.md')) 'coreCatalog at install root in contrib layout'
    Assert-True (Test-Path -LiteralPath $paths.coreCatalog -PathType Leaf) 'coreCatalog exists in contrib'
    Assert-True ($paths.uapscanFixLoop -eq (Join-Path $contentRoot 'uapscan-fix-loop.md')) 'uapscanFixLoop at install root'
    Assert-True (Test-Path -LiteralPath $paths.uapscanFixLoop -PathType Leaf) 'uapscanFixLoop exists in contrib'

    $pluginLayout = Join-Path $tempRoot 'plugin-layout'
    $pluginContent = Join-Path $pluginLayout 'content'
    $pluginScripts = Join-Path $pluginLayout 'scripts'
    New-Item -ItemType Directory -Force -Path $pluginContent | Out-Null
    New-Item -ItemType Directory -Force -Path $pluginScripts | Out-Null
    Set-Content -LiteralPath (Join-Path $pluginContent 'anti-patterns.core.md') -Value "# core`n" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $pluginContent 'uapscan-fix-loop.md') -Value "# loop`n" -Encoding UTF8
    $pluginPaths = Get-CodeAntTriagePathSet -ProfileRoot $tempRoot -ScriptsRoot $pluginScripts
    $expectedCore = Join-Path $pluginContent 'anti-patterns.core.md'
    Assert-True ($pluginPaths.coreCatalog -eq $expectedCore) 'plugin layout resolves core under content/'
    Assert-True ($pluginPaths.uapscanFixLoop -eq (Join-Path $pluginContent 'uapscan-fix-loop.md')) 'plugin layout resolves uapscan under content/'

    $init = Join-Path $scriptDir 'Initialize-CodeAntTriageCatalog.ps1'
    $seedProfile = Join-Path $tempRoot 'seed-profile'
    New-Item -ItemType Directory -Force -Path $seedProfile | Out-Null
    $seedOut = & $init -ProfileRoot $seedProfile | Out-String
    $seedCatalog = Join-Path $seedProfile 'codeant-triage\anti-patterns.user.md'
    $seedPrefs = Join-Path $seedProfile 'codeant-triage\promote-preferences.json'
    $seedXml = Join-Path $seedProfile 'codeant-triage\public-xml-summaries.md'
    Assert-True (Test-Path -LiteralPath $seedCatalog -PathType Leaf) 'init seeds user catalog under profile codeant-triage'
    Assert-True (Test-Path -LiteralPath $seedPrefs -PathType Leaf) 'init seeds prefs under profile codeant-triage'
    Assert-True (-not (Test-Path -LiteralPath $seedXml)) 'init does not seed public-xml-summaries'
    Assert-True ($seedOut -match 'Seeded:') 'init reports Seeded'

    $skipOut = & $init -ProfileRoot $seedProfile | Out-String
    Assert-True ($skipOut -match 'Skip \(exists\)') 'second init skips existing user files'

    $migrateProfile = Join-Path $tempRoot 'migrate-profile'
    $legacyDir = Join-Path $migrateProfile 'packs\codeant-triage'
    New-Item -ItemType Directory -Force -Path $legacyDir | Out-Null
    $legacyCatalog = Join-Path $legacyDir 'anti-patterns.user.md'
    $legacyPrefs = Join-Path $legacyDir 'promote-preferences.json'
    $legacyXml = Join-Path $legacyDir 'public-xml-summaries.md'
    Set-Content -LiteralPath $legacyCatalog -Value "LEGACY-UAP`n" -Encoding UTF8
    Set-Content -LiteralPath $legacyPrefs -Value '{"version":2,"defaultsByScope":{},"actions":[]}' -Encoding UTF8
    Set-Content -LiteralPath $legacyXml -Value "should-not-copy`n" -Encoding UTF8
    $migOut = & $init -ProfileRoot $migrateProfile | Out-String
    $migCatalog = Join-Path $migrateProfile 'codeant-triage\anti-patterns.user.md'
    $migPrefs = Join-Path $migrateProfile 'codeant-triage\promote-preferences.json'
    $migXml = Join-Path $migrateProfile 'codeant-triage\public-xml-summaries.md'
    Assert-True (Test-Path -LiteralPath $migCatalog -PathType Leaf) 'migrate creates user catalog'
    Assert-True ((Get-Content -LiteralPath $migCatalog -Raw) -match 'LEGACY-UAP') 'migrate copies catalog from packs path'
    Assert-True (Test-Path -LiteralPath $migPrefs -PathType Leaf) 'migrate copies prefs from packs path'
    Assert-True (-not (Test-Path -LiteralPath $migXml)) 'migrate does not copy public-xml'
    Assert-True ($migOut -match 'Migrated:') 'init reports Migrated'

    $getPrefs = Join-Path $scriptDir 'Get-CodeAntPromotePreference.ps1'
    $prefsJson = & $getPrefs -ProfileRoot $seedProfile -Json | Out-String
    Assert-True ($prefsJson -match '"version"') 'Get-CodeAntPromotePreference reads new prefs path'
}
finally {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    $detail = $failures -join $sep
    $msg = 'Test-CodeAntTriagePaths FAILED:' + [Environment]::NewLine + ' - ' + $detail
    Write-Error $msg
    exit 1
}

Write-Output 'OK: CodeAnt Triage paths (user data, plugin content/, init seed, packs migrate, no public-xml).'
exit 0
