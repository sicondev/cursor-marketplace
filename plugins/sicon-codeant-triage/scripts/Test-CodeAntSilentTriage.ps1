#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'codeant-triage-lib.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { [void]$failures.Add($Message) } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ("$Expected" -ne "$Actual") { [void]$failures.Add("$Message (expected '$Expected', got '$Actual')") } }

Assert-True ($null -ne (Get-Command Invoke-CodeAntSilentTriage -ErrorAction SilentlyContinue)) 'Invoke-CodeAntSilentTriage is exported'

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

$mdPath = Join-Path (Split-Path -Parent $scriptDir) 'codeant-silent-triage.md'
$md = Get-Content -LiteralPath $mdPath -Raw
Assert-True ($md -match 'Do not') 'silent-triage md forbids AskQuestion/finalize in prose'
Assert-True ($md -match 'AskQuestion') 'names AskQuestion as forbidden'
Assert-True ($md -match 'one issue at a time') 'serial issues'
Assert-True ($md -match '(?i)do not run.+test') 'specialist does not run repository test scripts'
Assert-True ($md -match '(?i)preference-only') 'preference-only findings are dismissed without a human bounce'
Assert-True ($md -match '(?i)bounded.+low-risk') 'bounded low-risk findings are fixed without a human bounce'
Assert-True ($md -match '(?i)security.+exploitation.+correctness.+bug') 'risk-bearing findings are not dismissed as flavour'

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
}

if ($failures.Count -gt 0) {
    Write-Error ('Test-CodeAntSilentTriage FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
    exit 1
}
Write-Output 'OK: codeant-silent-triage'
exit 0
