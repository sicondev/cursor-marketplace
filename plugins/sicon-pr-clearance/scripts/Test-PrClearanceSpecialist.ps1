#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'pr-clearance-lib.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { [void]$failures.Add($Message) } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ("$Expected" -ne "$Actual") { [void]$failures.Add("$Message (expected '$Expected', got '$Actual')") } }

Reset-PrClearanceRegistry
$cfg = Get-PrClearanceBindConfig -PackRoot $packRoot
Assert-Equal 'codeant-triage' $cfg.specialist 'default specialist tool id'

$a = [pscustomobject]@{ Id = '1'; Number = 1; Path = 'src/Foo.cs'; Line = '2'; Comment = 'a' }
$b = [pscustomobject]@{ Id = '2'; Number = 2; Path = 'src/Bar.cs'; Line = '3'; Comment = 'b' }
$c = [pscustomobject]@{ Id = '3'; Number = 3; Path = 'src/Foo.cs'; Line = '9'; Comment = 'c' }
$groups = @(Group-PrClearancePassFindingsByPath -Findings @($a, $b, $c))
Assert-Equal 2 $groups.Count 'two paths'
$foo = @($groups | Where-Object { $_.Path -eq 'src/foo.cs' })[0]
Assert-Equal 2 @($foo.Issues).Count 'Foo.cs has two issues'

$mixedThrew = $false
try {
    $null = Invoke-PrClearanceSpecialist -Path 'src/Foo.cs' -Issues @($a, $b) -PullRequestId 1
} catch { $mixedThrew = $true }
Assert-True $mixedThrew 'mixed Path issues throw'

Reset-PrClearanceRegistry
Import-PrClearanceBindForTest -Config ([pscustomobject]@{
    review = 'codeant-triage'; findings = 'codeant-triage'; forge = 'ado-core'; vcs = 'git-core'; specialist = 'codeant-triage'
})
Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Invoke-Specialist' = {
        param($Path, $Issues, $PullRequestId, $WorkspaceRoot)
        return [pscustomobject]@{
            results = @($Issues | ForEach-Object {
                [pscustomobject]@{
                    Id = $_.Id; Number = $_.Number; disposition = 'fixed'; reason = 'applied'
                    already = $false
                    report = [pscustomobject]@{ issue = $_.Comment; change = 'one line'; justification = 'nit' }
                }
            })
            paths = @($Path)
        }
    }
} -Load {}
$got = Invoke-PrClearanceSpecialist -Path 'src/Foo.cs' -Issues @($a, $c) -PullRequestId 9
Assert-Equal 2 @($got.results).Count 'one result per issue'
Assert-Equal 'src/Foo.cs' @($got.paths)[0] 'paths from specialist'
$reply = Get-PrClearanceSpecialistReply -Result $got.results[0]
Assert-True ($reply -match 'Issue') 'reply uses report.issue'
Assert-True ($reply -match 'one line') 'reply uses report.change'
Assert-True ($reply -match 'nit') 'fixed reply includes specialist justification'
Assert-True ($reply -notmatch '(?i)specialist') 'public reply does not expose specialist workflow'

$thin = Get-PrClearanceSpecialistReply -Result ([pscustomobject]@{ reason = 'left as-is'; report = $null })
Assert-True ($thin -match 'left as-is') 'missing report falls back to reason'

$wontFix = Get-PrClearanceSpecialistReply -Result ([pscustomobject]@{
    disposition = 'dismissed'
    reason = 'This is only a style preference and leaves no defect or exploitable behaviour.'
    report = [pscustomobject]@{ issue = 'Prefer a narrower command example'; change = ''; justification = '' }
})
Assert-True ($wontFix -match '\*\*WontFix Reason:\*\*') 'dismissed reply labels the WontFix reason'
Assert-True ($wontFix -notmatch '\*\*Fix:\*\*') 'dismissed reply never labels its reason as a fix'

$policyWontFix = Get-PrClearanceDismissedReply -Finding ([pscustomobject]@{
    Comment = '**Suggestion:** Prefer a narrower command example.'
}) -Reason 'This is only a documentation preference with no security or correctness impact.'
Assert-True ($policyWontFix -match '\*\*Issue:\*\* Prefer a narrower command example\.') 'non-specialist dismiss preserves the finding'
Assert-True ($policyWontFix -match '\*\*WontFix Reason:\*\* This is only a documentation preference') 'non-specialist dismiss labels its rationale'
Assert-True ($policyWontFix -notmatch '\*\*Fix:\*\*') 'non-specialist dismiss never uses a Fix label'

Reset-PrClearanceRegistry
Import-PrClearanceBindForTest -Config ([pscustomobject]@{
    review = 'codeant-triage'; findings = 'codeant-triage'; forge = 'ado-core'; vcs = 'git-core'; specialist = 'codeant-triage'
})
$script:capturedPrepared = $null
Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Invoke-Specialist' = {
        param($Path, $Issues, $PullRequestId, $WorkspaceRoot, $PreparedResults)
        $script:capturedPrepared = $PreparedResults
        return [pscustomobject]@{
            results = @($PreparedResults)
            paths = @($Path)
        }
    }
} -Load {}
$preset = @(
    [pscustomobject]@{
        Id = '1'; Number = 1; disposition = 'fixed'; reason = 'applied'
        already = $false
        report = [pscustomobject]@{ issue = 'a'; change = 'one line'; justification = 'nit' }
    }
)
$gotPrep = Invoke-PrClearanceSpecialist -Path 'src/Foo.cs' -Issues @($a) -PullRequestId 9 -PreparedResults $preset
Assert-True ($null -ne $script:capturedPrepared) 'PreparedResults is forwarded to Invoke-Specialist'
Assert-Equal '1' @($script:capturedPrepared)[0].Id 'PreparedResults Id forwarded'
Assert-Equal 'fixed' $gotPrep.results[0].disposition 'prepared disposition returned'

$absThrew = $false
try {
    $null = Invoke-PrClearanceSpecialist -Path 'C:\Windows\win.ini' -Issues @([pscustomobject]@{ Id = '9'; Number = 9; Path = 'C:\Windows\win.ini'; Line = '1'; Comment = 'x' }) -PullRequestId 1 -WorkspaceRoot $scriptDir
} catch { $absThrew = $true }
Assert-True $absThrew 'absolute specialist Path is rejected'

$dotThrew = $false
try {
    $null = Invoke-PrClearanceSpecialist -Path '../secret.txt' -Issues @([pscustomobject]@{ Id = '8'; Number = 8; Path = '../secret.txt'; Line = '1'; Comment = 'x' }) -PullRequestId 1 -WorkspaceRoot $scriptDir
} catch { $dotThrew = $true }
Assert-True $dotThrew 'parent-directory specialist Path is rejected'

$script:capturedSafePath = $null
Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Invoke-Specialist' = {
        param($Path, $Issues, $PullRequestId, $WorkspaceRoot, $PreparedResults)
        $script:capturedSafePath = $Path
        return [pscustomobject]@{ results = @(); paths = @($Path) }
    }
} -Load {}
$safeRoot = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-spec-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $safeRoot | Out-Null
try {
    $null = Invoke-PrClearanceSpecialist -Path 'src/Foo.cs' -Issues @($a) -PullRequestId 1 -WorkspaceRoot $safeRoot
    Assert-Equal 'src/Foo.cs' $script:capturedSafePath 'validated relative Path is still dispatched'
} finally {
    Remove-Item -LiteralPath $safeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) {
    Write-Error ('Test-PrClearanceSpecialist FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
    exit 1
}
Write-Output 'OK: pr-clearance-specialist'
exit 0
