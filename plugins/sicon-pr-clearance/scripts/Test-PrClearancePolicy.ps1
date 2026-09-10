#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'pr-clearance-lib.ps1')
. (Join-Path $scriptDir 'pr-clearance-policy.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { [void]$failures.Add($Message) } }
function Assert-Equal { param($Expected, $Actual, [string]$Message) if ("$Expected" -ne "$Actual") { [void]$failures.Add("$Message (expected '$Expected', got '$Actual')") } }

$reg = New-PrClearanceActRegister -PullRequestId 1
$onPr = [pscustomobject]@{ Id = 't1'; Number = 1; Path = 'src/Foo.cs'; Line = '10'; Comment = 'nit' }
$offPr = [pscustomobject]@{ Id = 't2'; Number = 2; Path = 'other/Bar.cs'; Line = '1'; Comment = 'nope' }
$prPaths = @('src/Foo.cs')

$in = Get-PrClearancePolicyDecision -Finding $onPr -Register $reg -ChangedPaths $prPaths
Assert-Equal 'continue' $in.action 'in-PR finding is continue for agent judgment'
Assert-Equal $false $in.already 'continue is not already'

$out = Get-PrClearancePolicyDecision -Finding $offPr -Register $reg -ChangedPaths $prPaths
Assert-Equal 'dismiss' $out.action 'out-of-PR finding is dismiss'
Assert-True (-not [string]::IsNullOrWhiteSpace([string]$out.reason)) 'fuse dismiss has a reason'
Assert-True ([string]$out.reason -match 'not a file') 'out-of-PR reason is everyday language'
Assert-True ([string]$out.reason -notmatch 'UAP|CAP-|codeant') 'reason has no catalog jargon'

$snap = New-PrClearanceActRegister -PullRequestId 2
$snap = Set-PrClearanceFindingPathSnapshot -Register $snap -Findings @([pscustomobject]@{ Path = 'src/Foo.cs' }) -ChangedPaths @('src/Foo.cs')
$later = [pscustomobject]@{ Id = 't3'; Number = 3; Path = 'src/New.cs'; Line = '1'; Comment = 'late' }
$late = Get-PrClearancePolicyDecision -Finding $later -Register $snap -ChangedPaths @('src/Foo.cs', 'src/New.cs')
Assert-Equal 'dismiss' $late.action 'path not in first-findings snapshot is dismiss'

$policyPath = Get-PrClearancePolicyMarkdownPath -InstallRoot (Split-Path -Parent $scriptDir)
Assert-True (Test-Path -LiteralPath $policyPath -PathType Leaf) 'policy markdown exists'
if (Test-Path -LiteralPath $policyPath -PathType Leaf) {
    $policyMd = Get-Content -LiteralPath $policyPath -Raw
    Assert-True ($policyMd -match 'contrib-managed:') 'policy has contrib-managed header'
    Assert-True ($policyMd -notmatch 'until specialist port') 'policy does not say implement until specialist port'
    Assert-True ($policyMd -match 'hand to the specialist') 'pass means hand to the specialist'
    Assert-True ($policyMd -match '(?i)preference-only') 'policy auto-dismisses preference-only findings'
    Assert-True ($policyMd -match '(?i)security.+exploitation.+correctness.+bug') 'policy protects concrete risk categories'
    Assert-True ($policyMd -match '(?i)bounded.+low-risk') 'policy passes bounded low-risk fixes'
    Assert-True ($policyMd -match '(?i)product choice alone') 'product-choice wording alone does not cause a human bounce'
}

if ($failures.Count -gt 0) {
    Write-Error ('Test-PrClearancePolicy FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
    exit 1
}
Write-Output 'OK: pr-clearance-policy'
exit 0
