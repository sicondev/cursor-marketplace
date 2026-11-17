#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'codeant-triage-lib.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { [void]$failures.Add($Message) } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ("$Expected" -ne "$Actual") { [void]$failures.Add("$Message (expected '$Expected', got '$Actual')") } }

Assert-True ($null -ne (Get-Command Invoke-CodeAntSilentTriage -ErrorAction SilentlyContinue)) 'Invoke-CodeAntSilentTriage is exported'
Assert-True ($null -ne (Get-Command New-CodeAntSilentTriageHandoff -ErrorAction SilentlyContinue)) 'New-CodeAntSilentTriageHandoff is exported'

$foo = [pscustomobject]@{ Id = '10'; Number = 1; Path = 'src/Foo.cs'; Line = '4'; Comment = 'use helper' }
$bar = [pscustomobject]@{ Id = '11'; Number = 2; Path = 'src/Bar.cs'; Line = '1'; Comment = 'other' }

$mixed = $false
try { $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo, $bar) -PullRequestId 1 } catch { $mixed = $true }
Assert-True $mixed 'mixed paths throw'

$empty = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @() -PullRequestId 1
Assert-Equal 0 @($empty.results).Count 'no issues → empty results'
Assert-Equal 0 @($empty.paths).Count 'no issues → no paths'

$await = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3
Assert-Equal 'ask' $await.results[0].disposition 'unfilled in-process call is ask pending'

$preset = @(
    [pscustomobject]@{
        Id = '10'; Number = 1; disposition = 'fixed'; reason = 'applied helper'
        already = $false
        report = [pscustomobject]@{ issue = 'use helper'; change = 'called Platform.Bar'; justification = 'matches house helper' }
    }
)
$got = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -WorkspaceRoot 'C:\tmp' -PreparedResults $preset
Assert-Equal 1 @($got.results).Count 'one prepared result'
Assert-Equal 'fixed' $got.results[0].disposition 'disposition preserved'
Assert-Equal 'src/Foo.cs' @($got.paths)[0] 'default dirty path is the file'
Assert-True ($got.results[0].report.change -match 'Platform') 'report.change kept'
Assert-True ($got.results[0].reason -notmatch 'UAP-') 'reason has no UAP id'

$idMismatch = $false
try {
    $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -PreparedResults @(
        [pscustomobject]@{ Id = '99'; Number = 1; disposition = 'fixed'; reason = 'x'; already = $false }
    )
} catch { $idMismatch = $true }
Assert-True $idMismatch 'prepared results must cover every issue Id'

$dupId = $false
try {
    $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -PreparedResults @(
        [pscustomobject]@{ Id = '10'; Number = 1; disposition = 'fixed'; reason = 'first'; already = $false }
        [pscustomobject]@{ Id = '10'; Number = 1; disposition = 'dismissed'; reason = 'second'; already = $false }
    )
} catch { $dupId = $true }
Assert-True $dupId 'duplicate prepared Ids throw'

$badDisposition = $false
try {
    $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -PreparedResults @(
        [pscustomobject]@{ Id = '10'; Number = 1; disposition = 'pass'; reason = 'not a valid row'; already = $false }
    )
} catch { $badDisposition = $true }
Assert-True $badDisposition 'invalid prepared disposition throws'

$blankReason = $false
try {
    $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -PreparedResults @(
        [pscustomobject]@{ Id = '10'; Number = 1; disposition = 'fixed'; reason = '   '; already = $false }
    )
} catch { $blankReason = $true }
Assert-True $blankReason 'blank prepared reason throws'

$alreadyStr = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -PreparedResults @(
    [pscustomobject]@{ Id = '10'; Number = 1; disposition = 'fixed'; reason = 'already matched'; already = 'false' }
)
Assert-Equal $false $alreadyStr.results[0].already "string 'false' is not already"

$alreadyUnknown = $false
try {
    $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -PreparedResults @(
        [pscustomobject]@{ Id = '10'; Number = 1; disposition = 'fixed'; reason = 'x'; already = 'no' }
    )
} catch { $alreadyUnknown = $true }
Assert-True $alreadyUnknown "string 'no' is not treated as already-fixed"

$extraPath = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -WorkspaceRoot 'C:\tmp' -PreparedResults @(
    [pscustomobject]@{
        Id = '10'; Number = 1; disposition = 'fixed'; reason = 'also touched helper'
        already = $false
        report = [pscustomobject]@{ issue = 'x'; change = 'y'; justification = 'z'; paths = @('src/Helper.cs') }
    }
)
Assert-True (@($extraPath.paths) -contains 'src/Helper.cs') 'relative report path is kept'

$paddedPath = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -WorkspaceRoot 'C:\tmp' -PreparedResults @(
    [pscustomobject]@{
        Id = '10'; Number = 1; disposition = 'fixed'; reason = 'also touched helper'
        already = $false
        report = [pscustomobject]@{ issue = 'x'; change = 'y'; justification = 'z'; paths = @("  src/Helper.cs`t") }
    }
)
Assert-True (@($paddedPath.paths) -contains 'src/Helper.cs') 'padded report path is trimmed before add'
Assert-True (@($paddedPath.paths) -notcontains "  src/Helper.cs`t") 'untrimmed report path is not kept'

$absReport = $false
try {
    $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -WorkspaceRoot 'C:\tmp' -PreparedResults @(
        [pscustomobject]@{
            Id = '10'; Number = 1; disposition = 'fixed'; reason = 'x'; already = $false
            report = [pscustomobject]@{ issue = 'x'; change = 'y'; justification = 'z'; paths = @('C:\Windows\win.ini') }
        }
    )
} catch { $absReport = $true }
Assert-True $absReport 'absolute report path is rejected'

$dotReport = $false
try {
    $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -WorkspaceRoot 'C:\tmp' -PreparedResults @(
        [pscustomobject]@{
            Id = '10'; Number = 1; disposition = 'fixed'; reason = 'x'; already = $false
            report = [pscustomobject]@{ issue = 'x'; change = 'y'; justification = 'z'; paths = @('../secret.txt') }
        }
    )
} catch { $dotReport = $true }
Assert-True $dotReport 'parent-directory report path is rejected'

$junctionRoot = Join-Path ([IO.Path]::GetTempPath()) ("silent-triage-" + [guid]::NewGuid().ToString('N'))
$junctionOutside = Join-Path ([IO.Path]::GetTempPath()) ("silent-triage-out-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $junctionRoot | Out-Null
New-Item -ItemType Directory -Path $junctionOutside | Out-Null
Set-Content -LiteralPath (Join-Path $junctionOutside 'secret.txt') -Value 'x'
$junctionLink = Join-Path $junctionRoot 'escape'
$junctionMade = $false
try {
    New-Item -ItemType Junction -Path $junctionLink -Target $junctionOutside | Out-Null
    $junctionMade = $true
} catch { }
if ($junctionMade) {
    $junctionReport = $false
    try {
        $null = Invoke-CodeAntSilentTriage -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 3 -WorkspaceRoot $junctionRoot -PreparedResults @(
            [pscustomobject]@{
                Id = '10'; Number = 1; disposition = 'fixed'; reason = 'x'; already = $false
                report = [pscustomobject]@{ issue = 'x'; change = 'y'; justification = 'z'; paths = @('escape/secret.txt') }
            }
        )
    } catch { $junctionReport = $true }
    Assert-True $junctionReport 'junction escape report path is rejected'
}
Remove-Item -LiteralPath $junctionRoot -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $junctionOutside -Recurse -Force -ErrorAction SilentlyContinue

# Pathless findings: empty Path in, discovered paths out (never '' out).
$pathless = [pscustomobject]@{ Id = 'qualitygate-902-1'; Number = 1; Path = ''; Line = ''; Comment = 'Secrets quality gate failed; no file/line detail was posted in ADO.' }
$located = Invoke-CodeAntSilentTriage -Path '' -Issues @($pathless) -PullRequestId 3 -WorkspaceRoot 'C:\tmp' -PreparedResults @(
    [pscustomobject]@{
        Id = 'qualitygate-902-1'; Number = 1; disposition = 'fixed'; reason = 'located and removed the credential'
        already = $false
        report = [pscustomobject]@{ issue = 'x'; change = 'y'; justification = 'z'; paths = @('src/Located.cs') }
    }
)
Assert-Equal 'fixed' $located.results[0].disposition 'pathless issue can be fixed by the specialist'
Assert-True (@($located.paths) -contains 'src/Located.cs') 'pathless fix reports the discovered path'
Assert-True (@($located.paths) -notcontains '') 'pathless result paths never contain empty string'
$pathlessAwait = Invoke-CodeAntSilentTriage -Path '' -Issues @($pathless) -PullRequestId 3
Assert-Equal 'ask' $pathlessAwait.results[0].disposition 'pathless unfilled call is ask pending'

$mdPath = Join-Path (Split-Path -Parent $scriptDir) 'codeant-silent-triage.md'
$md = Get-Content -LiteralPath $mdPath -Raw
Assert-True ($md -match 'Do not') 'silent-triage md forbids AskQuestion/finalize in prose'
Assert-True ($md -match 'AskQuestion') 'names AskQuestion as forbidden'
Assert-True ($md -match 'one issue at a time') 'serial issues'
Assert-True ($md -match '(?i)do not run.+test') 'specialist does not run repository test scripts'
Assert-True ($md -match '(?i)preference-only') 'preference-only findings are dismissed without a human bounce'
Assert-True ($md -match '(?i)bounded.+low-risk') 'bounded low-risk findings are fixed without a human bounce'
Assert-True ($md -match '(?i)security.+exploitation.+correctness.+bug') 'risk-bearing findings are not dismissed as flavour'
Assert-True ($md -match '(?i)separate Cursor Task') 'specialist runs as a separate Task'
Assert-True ($md -match 'PreparedResults') 'contract names PreparedResults for the validator'

$handoff = New-CodeAntSilentTriageHandoff -Path 'src/Foo.cs' -Issues @($foo) -PullRequestId 7 -WorkspaceRoot 'C:\tmp\ws' -Guidance 'use the helper'
Assert-equal '1' $handoff.ContractVersion 'handoff ContractVersion'
Assert-equal 'src/foo.cs' $handoff.Path 'handoff Path normalized'
Assert-equal 7 $handoff.PullRequestId 'handoff PullRequestId'
Assert-True ($handoff.Prompt -match 'src/foo.cs') 'handoff Prompt contains Path'
Assert-True ($handoff.Prompt -match '10') 'handoff Prompt contains Issue Id'
Assert-True ($handoff.Prompt -match 'use the helper') 'handoff Prompt echoes Guidance'
Assert-equal 2 ([regex]::Matches($handoff.Prompt, 'Earlier Paths in this Act').Count) 'path nudge is stated before Issues and restated after'
Assert-True ($handoff.Prompt -match 'already = true') 'handoff Prompt returns already when a prior edit satisfies the comment'
Assert-True ($handoff.Prompt -match 'helper outside this Path') 'handoff Prompt still allows a required helper join'
Assert-True ($handoff.Prompt -match 'report\.paths') 'handoff Prompt requires extra files in report.paths'
Assert-True ($handoff.Prompt -match 'Do not rework an earlier Path') 'handoff Prompt leaves settled Paths alone unless this Path needs them'
Assert-True ($md -match 'helper outside this Path') 'silent-triage md allows a required helper'
Assert-True ($md -match 'Earlier Paths from this Act') 'silent-triage md keeps earlier Act Paths in context'
Assert-True (@($handoff.IssueIds) -contains '10') 'handoff IssueIds includes issue'
Assert-True (@($handoff.Skills).Count -ge 1) 'handoff Skills non-empty when silent-triage.md resolves'
Assert-True ($handoff.Skills[0] -match 'codeant-silent-triage\.md$') 'Skills point at silent-triage contract'

$commandCandidates = @(
    (Join-Path (Split-Path -Parent (Split-Path -Parent $scriptDir)) 'adapters\cursor\commands\codeant-triage.md'),
    (Join-Path (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptDir))) 'commands\codeant-triage.md')
)
$commandPath = $commandCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
Assert-True (Test-Path -LiteralPath $commandPath -PathType Leaf) 'CodeAnt command exists for reply-format check'
if (Test-Path -LiteralPath $commandPath -PathType Leaf) {
    $commandMd = Get-Content -LiteralPath $commandPath -Raw
    Assert-True ($commandMd -match '\*\*WontFix Reason:\*\*') 'CodeAnt WontFix replies use the dedicated reason label'
    Assert-True ($commandMd -match '(?i)never put a WontFix reason on.+\*\*Fix:\*\*') 'CodeAnt command forbids Fix labels for WontFix'
    Assert-True ($commandMd -match '(?i)few-shot') 'CodeAnt command shows a few-shot correct Treat turn'
    Assert-True ($commandMd -match '(?i)scaffold') 'CodeAnt command uses the fetch explain scaffold'
    Assert-True ($commandMd -match '(?i)blocked sections') 'CodeAnt command requires blocked-section explain blocks, not wall-of-text'
}

if ($failures.Count -gt 0) {
    Write-Error ('Test-CodeAntSilentTriage FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
    exit 1
}
Write-Output 'OK: codeant-silent-triage'
exit 0
