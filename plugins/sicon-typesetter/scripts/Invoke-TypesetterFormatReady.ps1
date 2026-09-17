#Requires -Version 5.1
<#
.SYNOPSIS
  Verify or fix format on dirty files (Typesetter format-ready).
#>
param(
    [string]$StartPath = (Get-Location).Path,
    [string[]]$Files = @(),
    [switch]$Fix,
    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'typesetter-lib.ps1')

if (@($Files).Count -gt 0) {
    $requested = @(
        $Files |
            ForEach-Object { ConvertTo-TypesetterNativePath -Path $_ } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
            Select-Object -Unique
    )
    $byRoot = Group-TypesetterByRoot -Files $requested
    $dirtyList = New-Object 'System.Collections.Generic.List[string]'
    $pathComparer = Get-TypesetterPathComparer
    foreach ($gitRoot in @($byRoot.Keys)) {
        $dirtyAllowed = New-Object 'System.Collections.Generic.HashSet[string]' ($pathComparer)
        foreach ($d in @(Get-TypesetterDirtyFiles -StartPath $gitRoot)) {
            [void]$dirtyAllowed.Add($d)
        }
        foreach ($f in @($byRoot[$gitRoot])) {
            if (-not (Test-TypesetterSafeRepoFile -Path $f -RepoRoot $gitRoot)) { continue }
            if ($dirtyAllowed.Contains($f)) {
                [void]$dirtyList.Add($f)
            }
        }
    }
    $dirty = @($dirtyList)
} else {
    $dirty = @(Get-TypesetterDirtyFiles -StartPath $StartPath)
}
$groups = Group-TypesetterByRoot -Files $dirty
$reportRows = @()
$overallPass = $true

if ($dirty.Count -eq 0) {
    if ($Json) {
        @{ ok = $true; message = 'No dirty files - nothing to format-ready.'; roots = @() } | ConvertTo-Json -Depth 6
    } else {
        Write-Output 'No dirty files - nothing to format-ready.'
    }
    exit 0
}

foreach ($key in @($groups.Keys | Sort-Object)) {
    $files = @($groups[$key])
    $tooling = Get-TypesetterRepoTooling -RepoRoot $key -SkipLint
    $engines = @($tooling.formatEngines)
    if ($engines.Count -eq 0) { $engines = @([string]$tooling.formatEngine) }
    $engine = if ($engines.Count -gt 1) { ($engines -join '+') } else { [string]$engines[0] }
    $formatFiles = @($files | Where-Object { $_ -match '\.(cs|ts|tsx|js|jsx|mjs|cjs|json|css|scss|html|md|vue|yaml|yml|graphql)$' })
    $ok = $true
    $message = ''
    $output = ''

    if ($formatFiles.Count -eq 0) {
        $message = 'No format-relevant dirty files in this root.'
        $reportRows += @{ repoRoot = $key; engine = $engine; files = @($formatFiles); ok = $true; message = $message; output = '' }
        continue
    }

    if ($engine -eq 'none') {
        $message = 'No format tooling detected - nothing to prep for.'
        $reportRows += @{ repoRoot = $key; engine = $engine; files = @($formatFiles); ok = $true; message = $message; output = '' }
        continue
    }

    Push-Location -LiteralPath $key
    try {
        foreach ($eng in $engines) {
            if ($eng -eq 'prettier') {
                $prettierFiles = @($formatFiles | Where-Object { $_ -notmatch '\.cs$' })
                if ($prettierFiles.Count -eq 0) { continue }
                $tool = Resolve-TypesetterLocalJsTool -RepoRoot $key -Name 'prettier'
                if (-not $tool) {
                    $ok = $false
                    $overallPass = $false
                    $message = 'Prettier is configured but node_modules/.bin/prettier is missing. Install the lockfile-pinned package locally.'
                } else {
                    $rels = ConvertTo-TypesetterRelativeInclude -RepoRoot $key -Files $prettierFiles
                    $fmtArgs = @()
                    if ($Fix) { $fmtArgs += '--write' } else { $fmtArgs += '--check' }
                    $fmtArgs += '--'
                    $fmtArgs += $rels
                    $run = Invoke-TypesetterNative -FilePath $tool -ArgumentList $fmtArgs
                    $output = Add-TypesetterReportOutput -Existing $output -Chunk ([string]$run.Output)
                    if ([int]$run.ExitCode -ne 0) {
                        $ok = $false
                        $overallPass = $false
                        $message = if ($Fix) { 'Prettier write finished with errors.' } else { 'Prettier check found drift.' }
                    } else {
                        $message = if ($Fix) { 'Prettier write applied.' } else { 'Prettier check clean.' }
                    }
                }
            }
            elseif ($eng -eq 'dotnet') {
                $csFiles = @($formatFiles | Where-Object { $_ -match '\.cs$' })
                if ($csFiles.Count -eq 0) { continue }
                $byProj = Group-TypesetterCsFilesByProject -RepoRoot $key -CsFiles $csFiles -ProjectIndex $tooling.projectIndex
                if ($byProj.Count -eq 0) {
                    $ok = $false
                    $overallPass = $false
                    $message = 'dotnet format engine selected but no .sln/.csproj found.'
                    continue
                }
                foreach ($target in @($byProj.Keys | Sort-Object)) {
                    $groupFiles = @($byProj[$target])
                    $rels = ConvertTo-TypesetterRelativeInclude -RepoRoot $key -Files $groupFiles
                    $fmtArgs = @('format', 'whitespace', $target, '--include') + $rels
                    if (-not $Fix) { $fmtArgs += '--verify-no-changes' }
                    $run = Invoke-TypesetterNative -FilePath 'dotnet' -ArgumentList $fmtArgs
                    $output = Add-TypesetterReportOutput -Existing $output -Chunk ([string]$run.Output)
                    if ([int]$run.ExitCode -ne 0) {
                        $ok = $false
                        $overallPass = $false
                        $message = if ($Fix) { 'dotnet format finished with errors.' } else { 'dotnet format found drift.' }
                    } elseif (-not $message) {
                        $message = if ($Fix) { 'dotnet format applied.' } else { 'dotnet format verify clean.' }
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
        files    = @($formatFiles)
        ok       = $ok
        message  = $message
        output   = $output
    }
}

if ($Json) {
    @{ ok = [bool]$overallPass; appliedFix = [bool]$Fix; roots = $reportRows } | ConvertTo-Json -Depth 8
} else {
    foreach ($r in $reportRows) {
        $tag = if ($r.ok) { 'OK' } else { 'DRIFT' }
        Write-Output ("[{0}] {1} :: {2}" -f $tag, $r.repoRoot, $r.message)
        if ($r.files -and @($r.files).Count -gt 0) {
            Write-Output ('  files: ' + ((@($r.files) | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
        }
        if (-not $r.ok -and $r.output) { Write-Output $r.output }
    }
}

if ($overallPass) { exit 0 } else { exit 1 }
