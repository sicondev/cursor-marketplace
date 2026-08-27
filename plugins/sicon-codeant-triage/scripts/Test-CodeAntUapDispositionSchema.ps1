#Requires -Version 5.1
<#
.SYNOPSIS
  Schema checks for UAP Disposition column (legacy blank, populated, clear, Scope filter).
.EXAMPLE
  & "$PSScriptRoot\Test-CodeAntUapDispositionSchema.ps1"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'codeant-triage-lib.ps1')

$fixtures = Join-Path $scriptDir 'fixtures'
$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}

# Legacy 7-col => blank Disposition
$legacyMd = Get-Content -LiteralPath (Join-Path $fixtures 'uap-legacy-7col.md') -Raw
$legacyRows = @(Get-CodeAntUserAntiPatternRows -Markdown $legacyMd)
Assert-True ($legacyRows.Count -eq 1) 'Legacy fixture should yield 1 row'
if ($legacyRows.Count -gt 0) {
    Assert-True ($legacyRows[0].Id -eq 'UAP-1') 'Legacy row id'
    Assert-True ([string]::IsNullOrEmpty($legacyRows[0].Disposition)) 'Legacy missing Disposition column means blank'
    Assert-True ($legacyRows[0].EnforcedBy -eq 'CodeAnt Triage') 'Legacy Enforced by still last column'
    Assert-True ($legacyRows[0].FixDirection -eq 'Fix by adding coverage') 'Legacy Fix direction preserved'
}

# A catalog that was previously upgraded without padding rows remains readable.
$mixedMd = @'
| ID | Scope | Repo | Pattern | Signals | Fix direction | Disposition | Enforced by |
|----|-------|------|---------|---------|---------------|-------------|-------------|
| UAP-9 | Contoso/Proj/Repo | hub | Legacy rendered row | signal-x | Add coverage | CodeAnt Triage |
'@
$mixedRows = @(Get-CodeAntUserAntiPatternRows -Markdown $mixedMd)
Assert-True ($mixedRows.Count -eq 1) 'Mixed-schema fixture should yield 1 row'
if ($mixedRows.Count -gt 0) {
    Assert-True ([string]::IsNullOrEmpty($mixedRows[0].Disposition)) 'Unpadded legacy row stays blank after header upgrade'
    Assert-True ($mixedRows[0].EnforcedBy -eq 'CodeAnt Triage') 'Unpadded legacy Enforced by stays last column'
}

# Blank Disposition 8-col
$blankMd = Get-Content -LiteralPath (Join-Path $fixtures 'uap-blank-disposition.md') -Raw
$blankRows = @(Get-CodeAntUserAntiPatternRows -Markdown $blankMd)
Assert-True ($blankRows.Count -eq 1) 'Blank fixture should yield 1 row'
if ($blankRows.Count -gt 0) {
    Assert-True ([string]::IsNullOrEmpty($blankRows[0].Disposition)) 'Explicit blank Disposition cell'
    Assert-True ($blankRows[0].Id -eq 'UAP-2') 'Blank fixture id'
}

# Escaped pipes stay in the source cell.
$escapedPipeMd = @'
| ID | Scope | Repo | Pattern | Signals | Fix direction | Disposition | Enforced by |
|----|-------|------|---------|---------|---------------|-------------|-------------|
| UAP-8 | Contoso/Proj/Repo | hub | Escaped pipe | signal-x | Add coverage | Recommend WontFix - A\|B config | CodeAnt Triage |
'@
$escapedPipeRows = @(Get-CodeAntUserAntiPatternRows -Markdown $escapedPipeMd)
Assert-True ($escapedPipeRows.Count -eq 1) 'Escaped-pipe fixture should yield 1 row'
if ($escapedPipeRows.Count -gt 0) {
    Assert-True ($escapedPipeRows[0].Disposition -eq 'Recommend WontFix - A|B config') 'Escaped pipe remains in Disposition'
    Assert-True ($escapedPipeRows[0].EnforcedBy -eq 'CodeAnt Triage') 'Escaped pipe does not shift Enforced by'
}

# Rows missing a required column are ignored.
$malformedMd = @'
| ID | Scope | Repo | Pattern | Signals | Fix direction | Disposition | Enforced by |
|----|-------|------|---------|---------|---------------|-------------|-------------|
| UAP-7 | Contoso/Proj/Repo | hub | Missing column | signal-x | Add coverage |
'@
$malformedRows = @(Get-CodeAntUserAntiPatternRows -Markdown $malformedMd)
Assert-True ($malformedRows.Count -eq 0) 'Malformed six-cell row is ignored'

# Populated + Scope filter (does not exclude Disposition-populated rows)
$popMd = Get-Content -LiteralPath (Join-Path $fixtures 'uap-populated-disposition.md') -Raw
$popRows = @(Get-CodeAntUserAntiPatternRows -Markdown $popMd)
Assert-True ($popRows.Count -eq 2) 'Populated fixture should yield 2 rows'
if ($popRows.Count -gt 0) {
    $expectedDisposition = 'Recommend WontFix - systemic unit test pending'
    # Fixture may use Unicode em dash; normalize for compare
    $actualDisposition = ($popRows[0].Disposition -replace [char]0x2014, '-').Trim()
    Assert-True ($actualDisposition -eq $expectedDisposition) 'Populated Disposition preserved'
}

$scoped = @(Select-CodeAntUserAntiPatternsByScope -Rows $popRows -RemoteId 'Contoso/Proj/Repo')
Assert-True ($scoped.Count -eq 1) 'Scope filter should keep one row for Contoso/Proj/Repo'
if ($scoped.Count -gt 0) {
    Assert-True ($scoped[0].Id -eq 'UAP-3') 'Scoped row is UAP-3'
    Assert-True (-not [string]::IsNullOrEmpty($scoped[0].Disposition)) 'Scope filter must not drop Disposition-populated rows'
}

# Clear Disposition leaves other columns
if ($popRows.Count -gt 0) {
    $cleared = Clear-CodeAntUserAntiPatternDisposition -Row $popRows[0]
    Assert-True ([string]::IsNullOrEmpty($cleared.Disposition)) 'Clear empties Disposition'
    Assert-True ($cleared.Id -eq $popRows[0].Id) 'Clear keeps Id'
    Assert-True ($cleared.Pattern -eq $popRows[0].Pattern) 'Clear keeps Pattern'
    Assert-True ($cleared.FixDirection -eq $popRows[0].FixDirection) 'Clear keeps Fix direction'
    Assert-True ($cleared.EnforcedBy -eq $popRows[0].EnforcedBy) 'Clear keeps Enforced by'
}

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    $detail = $failures -join $sep
    $msg = 'Test-CodeAntUapDispositionSchema FAILED:' + [Environment]::NewLine + ' - ' + $detail
    Write-Error $msg
    exit 1
}

Write-Output 'OK: UAP Disposition schema fixtures (legacy blank, blank cell, populated, Scope non-filter, clear).'
exit 0
