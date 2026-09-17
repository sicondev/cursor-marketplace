#Requires -Version 5.1
<#
.SYNOPSIS
  Verify or fix lint on dirty files (Typesetter lint-ready).
#>
param(
    [string]$StartPath = (Get-Location).Path,
    [switch]$Fix,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'typesetter-lib.ps1')

$dirty = @(Get-TypesetterDirtyFiles -StartPath $StartPath)
$groups = Group-TypesetterByRoot -Files $dirty
$reportRows = @()
$overallPass = $true

if ($dirty.Count -eq 0) {
    if ($Json) {
        @{ ok = $true; message = 'No dirty files - nothing to lint-ready.'; roots = @() } | ConvertTo-Json -Depth 6
    } else {
        Write-Output 'No dirty files - nothing to lint-ready.'
    }
    exit 0
}

foreach ($key in @($groups.Keys | Sort-Object)) {
    $files = @($groups[$key])
    $tooling = Get-TypesetterRepoTooling -RepoRoot $key -SkipFormat
    $engines = @($tooling.lintEngines)
    if ($engines.Count -eq 0) { $engines = @([string]$tooling.lintEngine) }
    $engine = if ($engines.Count -gt 1) { ($engines -join '+') } else { [string]$engines[0] }
    $lintFiles = @($files | Where-Object { $_ -match '\.(cs|ts|tsx|js|jsx|mjs|cjs)$' })
    $ok = $true
    $noGate = $false
    $message = ''
    $output = ''

    if ($engine -eq 'none') {
        $noGate = $true
        $message = 'No lint/analyzer gate configured in this repo - nothing to prep for.'
        $reportRows += @{ repoRoot = $key; engine = $engine; files = @($lintFiles); ok = $true; noGate = $true; message = $message; output = '' }
        continue
    }

    if ($lintFiles.Count -eq 0) {
        $message = 'No lint-relevant dirty files in this root.'
        $reportRows += @{ repoRoot = $key; engine = $engine; files = @(); ok = $true; noGate = $false; message = $message; output = '' }
        continue
    }

    Push-Location -LiteralPath $key
    try {
        foreach ($eng in $engines) {
            if ($eng -eq 'eslint') {
                $jsFiles = @($lintFiles | Where-Object { $_ -notmatch '\.cs$' })
                if ($jsFiles.Count -eq 0) { continue }
                $tool = Resolve-TypesetterLocalJsTool -RepoRoot $key -Name 'eslint'
                if (-not $tool) {
                    $ok = $false
                    $overallPass = $false
                    $message = 'ESLint is configured but node_modules/.bin/eslint is missing. Install the lockfile-pinned package locally.'
                } else {
                    $rels = ConvertTo-TypesetterRelativeInclude -RepoRoot $key -Files $jsFiles
                    $eslintArgs = @()
                    if ($Fix) { $eslintArgs += '--fix' }
                    $eslintArgs += '--'
                    $eslintArgs += $rels
                    $run = Invoke-TypesetterNative -FilePath $tool -ArgumentList $eslintArgs
                    $output = Add-TypesetterReportOutput -Existing $output -Chunk ([string]$run.Output)
                    if ([int]$run.ExitCode -ne 0) {
                        $ok = $false
                        $overallPass = $false
                        $message = if ($Fix) { 'ESLint finished with remaining issues.' } else { 'ESLint found issues on dirty files.' }
                    } elseif ($Fix) {
                        $verifyArgs = @('--') + $rels
                        $verify = Invoke-TypesetterNative -FilePath $tool -ArgumentList $verifyArgs
                        $output = Add-TypesetterReportOutput -Existing $output -Chunk ([string]$verify.Output)
                        if ([int]$verify.ExitCode -ne 0) {
                            $ok = $false
                            $overallPass = $false
                            $message = 'ESLint fix applied but remaining issues were found on verify.'
                        } else {
                            $message = 'ESLint fix applied (clean).'
                        }
                    } else {
                        $message = 'ESLint clean on dirty files.'
                    }
                }
            }
            elseif ($eng -eq 'dotnet-analyzers') {
                $csFiles = @($lintFiles | Where-Object { $_ -match '\.cs$' })
                if ($csFiles.Count -eq 0) { continue }
                $byProj = Group-TypesetterCsFilesByProject -RepoRoot $key -CsFiles $csFiles -ProjectIndex $tooling.projectIndex
                if ($byProj.Count -eq 0) {
                    $ok = $false
                    $overallPass = $false
                    $message = 'Analyzer gate detected but no .sln/.csproj found.'
                    continue
                }
                foreach ($target in @($byProj.Keys | Sort-Object)) {
                    $groupFiles = @($byProj[$target])
                    $rels = ConvertTo-TypesetterRelativeInclude -RepoRoot $key -Files $groupFiles
                    $fmtArgs = @('format', 'style', $target, '--severity', 'warn', '--include') + $rels
                    if (-not $Fix) { $fmtArgs += '--verify-no-changes' }
                    $run = Invoke-TypesetterNative -FilePath 'dotnet' -ArgumentList $fmtArgs
                    $output = Add-TypesetterReportOutput -Existing $output -Chunk ([string]$run.Output)
                    if ([int]$run.ExitCode -ne 0) {
                        $ok = $false
                        $overallPass = $false
                        $message = if ($Fix) { 'dotnet format style finished with errors.' } else { 'dotnet format style found issues.' }
                    } elseif (-not $message) {
                        $message = if ($Fix) { 'dotnet format style applied.' } else { 'dotnet format style verify clean.' }
                    }
                }
            }
        }
    } finally {
        Pop-Location
    }

    $reportRows += @{
        repoRoot = $key
        engine   = $engine
        files    = @($lintFiles)
        ok       = $ok
        noGate   = $noGate
        message  = $message
        output   = $output
    }
}

if ($Json) {
    @{ ok = [bool]$overallPass; appliedFix = [bool]$Fix; roots = $reportRows } | ConvertTo-Json -Depth 8
} else {
    foreach ($r in $reportRows) {
        $tag = if ($r.noGate) { 'NO-GATE' } elseif ($r.ok) { 'OK' } else { 'ISSUES' }
        Write-Output ("[{0}] {1} :: {2}" -f $tag, $r.repoRoot, $r.message)
        if ($r.files -and @($r.files).Count -gt 0) {
            Write-Output ('  files: ' + ((@($r.files) | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
        }
        if (-not $r.ok -and $r.output) { Write-Output $r.output }
    }
}

if ($overallPass) { exit 0 } else { exit 1 }
