#Requires -Version 5.1
<#
.SYNOPSIS
  Probe dirty files and format/lint engines for Typesetter.
#>
param(
    [string]$StartPath = (Get-Location).Path,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'typesetter-lib.ps1')

$dirty = @(Get-TypesetterDirtyFiles -StartPath $StartPath)
$groups = Group-TypesetterByRoot -Files $dirty
$roots = @()
foreach ($key in @($groups.Keys | Sort-Object)) {
    $files = @($groups[$key])
    $tooling = Get-TypesetterRepoTooling -RepoRoot $key
    $formatFiles = @($files | Where-Object { $_ -match '\.(cs|ts|tsx|js|jsx|mjs|cjs|json|css|scss|html|md|vue|yaml|yml|graphql)$' })
    $lintFiles = @($files | Where-Object { $_ -match '\.(cs|ts|tsx|js|jsx|mjs|cjs)$' })
    $roots += [pscustomobject]@{
        repoRoot     = $key
        formatEngine = $tooling.formatEngine
        lintEngine   = $tooling.lintEngine
        dirtyCount   = $files.Count
        formatFiles  = $formatFiles
        lintFiles    = $lintFiles
        allDirty     = $files
    }
}

$result = [pscustomobject]@{
    startPath  = [IO.Path]::GetFullPath($StartPath)
    dirtyCount = $dirty.Count
    roots      = $roots
}

if ($Json) {
    $result | ConvertTo-Json -Depth 6
} else {
    Write-Output ("Dirty files: {0}" -f $result.dirtyCount)
    foreach ($r in $roots) {
        Write-Output ("Root: {0}" -f $r.repoRoot)
        Write-Output ("  formatEngine={0} lintEngine={1} formatFiles={2} lintFiles={3}" -f $r.formatEngine, $r.lintEngine, $r.formatFiles.Count, $r.lintFiles.Count)
    }
}
