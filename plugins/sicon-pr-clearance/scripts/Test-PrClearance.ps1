#Requires -Version 5.1
<#
.SYNOPSIS
  Isolated pr-clearance coordinator checks (fixtures; no network).
.EXAMPLE
  & "$PSScriptRoot\Test-PrClearance.ps1"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$packRoot = Split-Path -Parent $scriptDir
. (Join-Path $scriptDir 'pr-clearance-lib.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Message)
    if ("$Expected" -ne "$Actual") {
        [void]$failures.Add("$Message (expected '$Expected', got '$Actual')")
    }
}

Reset-PrClearanceRegistry

# --- 1. Bind config ---
$cfg = Get-PrClearanceBindConfig -PackRoot $packRoot
Assert-Equal 'codeant-triage' $cfg.review 'default review tool id'
Assert-Equal 'codeant-triage' $cfg.findings 'default findings tool id'
Assert-Equal 'ado-core' $cfg.forge 'default forge tool id'
Assert-Equal 'git-core' $cfg.vcs 'default vcs tool id'
Assert-Equal 'codeant-triage' $cfg.specialist 'default specialist tool id'
Assert-True (@($cfg.PSObject.Properties.Name | Where-Object { $_ -in @('review', 'findings', 'forge', 'vcs', 'specialist') }).Count -eq 5) 'shipped config has the five keys'

$badDir = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-bad-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $badDir | Out-Null
try {
    $badGet = Join-Path $badDir 'bind-config.json'
    Set-Content -LiteralPath $badGet -Value '{"review":"Get-CodeAntReviewState","findings":"codeant-triage","forge":"ado-core","vcs":"git-core"}' -Encoding UTF8
    $threwGet = $false
    try {
        $null = Get-PrClearanceBindConfig -PackRoot $badDir
    } catch {
        $threwGet = $true
        Assert-True ([string]$_.Exception.Message -match 'tool id') 'Get* config error mentions tool id'
        Assert-True ([string]$_.Exception.Message -notmatch '\.ps1') 'Get* config error does not name a script'
    }
    Assert-True $threwGet 'config with a Get* value is rejected'

    $badPath = Join-Path $badDir 'path-config.json'
    Set-Content -LiteralPath $badPath -Value '{"review":"packs/review-codeant/scripts/review-codeant.ps1","findings":"codeant-triage","forge":"ado-core","vcs":"git-core"}' -Encoding UTF8
    # validate via user override so pack default stays valid
    $userDir = Join-Path $badDir 'user'
    New-Item -ItemType Directory -Force -Path $userDir | Out-Null
    $userCfg = Join-Path $userDir 'bind-config.json'
    Set-Content -LiteralPath $userCfg -Value '{"review":"C:\\temp\\foo.ps1"}' -Encoding UTF8
    $threwPath = $false
    try {
        $null = Get-PrClearanceBindConfig -PackRoot $packRoot -UserConfigPath $userCfg
    } catch {
        $threwPath = $true
        Assert-True ([string]$_.Exception.Message -match 'tool id') 'script-path config error mentions tool id'
    }
    Assert-True $threwPath 'config with a script path is rejected'

    $unknown = Join-Path $userDir 'unknown.json'
    Set-Content -LiteralPath $unknown -Value '{"review":"not-a-tool"}' -Encoding UTF8
    $threwUnknown = $false
    try {
        $null = Get-PrClearanceBindConfig -PackRoot $packRoot -UserConfigPath $unknown
    } catch {
        $threwUnknown = $true
        Assert-True ([string]$_.Exception.Message -match 'not-a-tool') 'unknown tool id is named in the error'
    }
    Assert-True $threwUnknown 'unknown tool id is rejected'
}
finally {
    Remove-Item -LiteralPath $badDir -Recurse -Force -ErrorAction SilentlyContinue
}

# Plugin layout: bind-config and policy live under content/, not pack-root.
$pluginShape = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-plugin-' + [guid]::NewGuid().ToString('n'))
try {
    $pluginContent = Join-Path $pluginShape 'content'
    $pluginPolicyDir = Join-Path $pluginContent 'policy'
    New-Item -ItemType Directory -Force -Path $pluginPolicyDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $packRoot 'bind-config.json') -Destination (Join-Path $pluginContent 'bind-config.json')
    if (-not (Test-Path -LiteralPath (Join-Path $pluginContent 'bind-config.json'))) {
        Copy-Item -LiteralPath (Join-Path $packRoot 'content\bind-config.json') -Destination (Join-Path $pluginContent 'bind-config.json')
    }
    $srcPolicy = Join-Path (Split-Path -Parent $scriptDir) 'policy\pr-clearance-policy.md'
    if (-not (Test-Path -LiteralPath $srcPolicy)) {
        $srcPolicy = Join-Path $packRoot 'policy\pr-clearance-policy.md'
    }
    Copy-Item -LiteralPath $srcPolicy -Destination (Join-Path $pluginPolicyDir 'pr-clearance-policy.md')
    $pluginCfg = Get-PrClearanceBindConfig -PackRoot $pluginShape
    Assert-Equal 'codeant-triage' $pluginCfg.review 'plugin content/bind-config.json loads'
    $pluginPolicy = Get-PrClearancePolicyMarkdownPath -InstallRoot $pluginShape
    Assert-True ($pluginPolicy -match [regex]::Escape((Join-Path 'content' 'policy'))) 'plugin policy is content/policy'
    Assert-True (Test-Path -LiteralPath $pluginPolicy -PathType Leaf) 'plugin policy file exists'
}
finally {
    Remove-Item -LiteralPath $pluginShape -Recurse -Force -ErrorAction SilentlyContinue
}

$packPolicy = Get-PrClearancePolicyMarkdownPath -InstallRoot (Split-Path -Parent $scriptDir)
Assert-True (Test-Path -LiteralPath $packPolicy -PathType Leaf) 'pack/contrib policy markdown resolves'

$dualProfile = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-dual-' + [guid]::NewGuid().ToString('n'))
try {
    $packScripts = Join-Path $dualProfile 'packs\pr-clearance\scripts'
    $pluginScripts = Join-Path $dualProfile 'plugins\sicon-pr-clearance\scripts'
    New-Item -ItemType Directory -Force -Path $packScripts | Out-Null
    New-Item -ItemType Directory -Force -Path $pluginScripts | Out-Null
    Set-Content -LiteralPath (Join-Path $packScripts 'pr-clearance-lib.ps1') -Value '# pack' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $pluginScripts 'pr-clearance-lib.ps1') -Value '# plugin' -Encoding UTF8
    $selfRoot = Resolve-PrClearanceSelfScriptsRoot -ProfileRoot $dualProfile
    Assert-Equal ([IO.Path]::GetFullPath($pluginScripts)) ([IO.Path]::GetFullPath($selfRoot)) 'self scripts prefer plugin over user pack'
}
finally {
    Remove-Item -LiteralPath $dualProfile -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 2. NextAction matrix ---
Assert-Equal 'request_and_wait' (Get-PrClearanceNextAction -State none -Quiet:$false -ActBatchCount 0).action 'none → request_and_wait'
Assert-Equal 'wait' (Get-PrClearanceNextAction -State in_flight -Quiet:$false -ActBatchCount 0).action 'in_flight → wait'
Assert-Equal 'request_and_wait' (Get-PrClearanceNextAction -State finished_stale_sha -Quiet:$false -ActBatchCount 0).action 'stale → request_and_wait'
Assert-Equal 'finalize_quiet' (Get-PrClearanceNextAction -State finished_this_sha -Quiet -ActBatchCount 0).action 'quiet → finalize_quiet'
Assert-Equal 'act' (Get-PrClearanceNextAction -State finished_this_sha -Quiet:$false -ActBatchCount 0).action 'not quiet count 0 → act'
Assert-Equal 'act' (Get-PrClearanceNextAction -State finished_this_sha -Quiet:$false -ActBatchCount 5).action 'count 5 is still act (cap is 10)'
Assert-Equal 'act' (Get-PrClearanceNextAction -State finished_this_sha -Quiet:$false -ActBatchCount 9).action 'count 9 → act'
Assert-Equal 'finalize_max_batches' (Get-PrClearanceNextAction -State finished_this_sha -Quiet:$false -ActBatchCount 10).action 'count 10 → finalize_max_batches'
Assert-Equal 'finalize_timeout' (Get-PrClearanceNextAction -State none -Quiet:$false -ActBatchCount 0 -LastWaitTimedOut).action 'timeout wins'
Assert-Equal 'request_and_wait' (Get-PrClearanceNextAction -State in_flight -Quiet:$false -ActBatchCount 0 -AfterPush).action 'after push kicks even if leftover in_flight'
Assert-Equal 'finalize_timeout' (Get-PrClearanceNextAction -State in_flight -Quiet:$false -ActBatchCount 0 -AfterPush -LastWaitTimedOut).action 'timeout still wins over after push'
Assert-Equal 'act' (Get-PrClearanceNextAction -State none -FirstInteraction -FindingCount 2 -ActBatchCount 0).action 'first pass with findings acts without a kick'
Assert-Equal 'act' (Get-PrClearanceNextAction -State in_flight -FirstInteraction -FindingCount 1 -ActBatchCount 0).action 'first pass findings win over leftover in_flight'
Assert-Equal 'request_and_wait' (Get-PrClearanceNextAction -State none -FirstInteraction -FindingCount 0 -ActBatchCount 0).action 'first pass empty findings kicks once'
Assert-Equal 'wait' (Get-PrClearanceNextAction -State in_flight -FirstInteraction -FindingCount 0 -ActBatchCount 0).action 'first pass empty + in_flight waits'
Assert-Equal 'finalize_quiet' (Get-PrClearanceNextAction -State finished_this_sha -FirstInteraction -FindingCount 0 -ActBatchCount 0).action 'first pass already quiet stays quiet'
Assert-Equal 'finalize_quiet' (Get-PrClearanceNextAction -State none -FindingCount 0 -ActBatchCount 0).action 'later empty findings is completion'
Assert-Equal 'finalize_quiet' (Get-PrClearanceNextAction -State in_flight -FindingCount 0 -ActBatchCount 1).action 'later empty findings completes even if leftover in_flight'
Assert-Equal 'act' (Get-PrClearanceNextAction -State none -FindingCount 1 -ActBatchCount 1).action 'later findings still act'
Assert-Equal 'request_and_wait' (Get-PrClearanceNextAction -State none -FindingCount 0 -ActBatchCount 1 -AfterPush).action 'after push still kicks on a new tip'

# --- 3. Composed quiet ---
$empty = @()
$one = @([pscustomobject]@{ Id = '1'; Number = 1; Path = 'a.cs'; Line = '1'; Comment = 'x' })
Assert-True (Test-PrClearanceQuiet -State finished_this_sha -Findings $empty) 'finished_this_sha + empty is quiet'
Assert-True (-not (Test-PrClearanceQuiet -State finished_this_sha -Findings $one)) 'finished_this_sha + finding is not quiet'
Assert-True (-not (Test-PrClearanceQuiet -State none -Findings $empty)) 'none + empty is not quiet'
Assert-True (-not (Test-PrClearanceQuiet -State finished_stale_sha -Findings $empty)) 'stale + empty is not quiet'
$quietThrew = $false
try {
    $null = Test-PrClearanceQuiet -State finished_this_sha
}
catch {
    $quietThrew = $true
    Assert-True ([string]$_.Exception.Message -match 'Findings') 'State without Findings names Findings in the error'
}
Assert-True $quietThrew 'State without Findings does not assume quiet'

$pluginCache = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-plugincache-' + [guid]::NewGuid().ToString('n'))
try {
    $noise = Join-Path $pluginCache 'noise\scripts'
    New-Item -ItemType Directory -Force -Path $noise | Out-Null
    Set-Content -LiteralPath (Join-Path $noise 'git-core.ps1') -Value '# noise' -Encoding UTF8
    $packScripts = Join-Path $pluginCache 'publisher\sicon-git-core\abc123\scripts'
    New-Item -ItemType Directory -Force -Path $packScripts | Out-Null
    $wanted = Join-Path $packScripts 'git-core.ps1'
    Set-Content -LiteralPath $wanted -Value '# pack' -Encoding UTF8
    $resolved = Resolve-PrClearancePluginCacheScriptPath -CacheRoot $pluginCache -PackId 'git-core' -FileName 'git-core.ps1'
    Assert-Equal ([IO.Path]::GetFullPath($wanted)) ([IO.Path]::GetFullPath($resolved)) 'plugin cache resolves the pack script, not a recursive noise hit'
}
finally {
    Remove-Item -LiteralPath $pluginCache -Recurse -Force -ErrorAction SilentlyContinue
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-path-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $root | Out-Null
try {
    $ok = Resolve-PrClearanceFindingPath -RepoRoot $root -Path '/contrib/ado-core/content/scripts/ado-core.ps1'
    Assert-True $ok.StartsWith([IO.Path]::GetFullPath($root)) 'finding path stays under the repo root'
    $absThrew = $false
    try { $null = Resolve-PrClearanceFindingPath -RepoRoot $root -Path 'C:\Windows\win.ini' } catch { $absThrew = $true }
    Assert-True $absThrew 'absolute finding path is rejected'
    $dotThrew = $false
    try { $null = Resolve-PrClearanceFindingPath -RepoRoot $root -Path '../secret.txt' } catch { $dotThrew = $true }
    Assert-True $dotThrew 'parent-directory finding path is rejected'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

$notFound = [System.Net.WebException]::new('not found', [System.Net.WebExceptionStatus]::ProtocolError)
# WebException without a 404 response is not treated as not-found
$fakeRecord = [System.Management.Automation.ErrorRecord]::new($notFound, 'x', [System.Management.Automation.ErrorCategory]::InvalidResult, $null)
Assert-True (-not (Test-PrClearanceHttpNotFound -ErrorRecord $fakeRecord)) 'WebException without 404 is not a miss'

# --- 4. Fixture kick (no thread create) ---
Reset-PrClearanceRegistry
$script:kickCalls = 0
Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Get-ReviewState'     = { param($PullRequestId, $Sha) [pscustomobject]@{ state = 'none'; tipSha = $Sha } }
    'Request-Review'      = { param($PullRequestId) $script:kickCalls++; [pscustomobject]@{ PullRequestId = $PullRequestId } }
    'Get-ReviewFindings'  = { param($PullRequestId) @() }
    'Complete-ReviewFinding' = { param($Finding, $Disposition, $Reply, $PullRequestId) }
}
Import-PrClearanceBindForTest -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
$null = Request-Review -PullRequestId 42
Assert-Equal 1 $script:kickCalls 'Request-Review dispatched to the Review tool'
Assert-True ($null -eq (Get-Command -Name New-AdoCorePullRequestThread -ErrorAction SilentlyContinue)) 'kick does not define New-AdoCorePullRequestThread'

# --- 4b. Fixture Clear-ReviewRequests (warn, do not throw) ---
Reset-PrClearanceRegistry
$script:clearCalls = 0
Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Get-ReviewState'        = { param($PullRequestId, $Sha) [pscustomobject]@{ state = 'finished_this_sha'; tipSha = $Sha } }
    'Request-Review'         = { param($PullRequestId) }
    'Clear-ReviewRequests'   = {
        param($PullRequestId)
        $script:clearCalls++
        [pscustomobject]@{
            PullRequestId = $PullRequestId
            ResolvedCount = 2
            ThreadIds     = @(11, 12)
            Warnings      = @()
        }
    }
    'Get-ReviewFindings'     = { param($PullRequestId) @() }
    'Complete-ReviewFinding' = { param($Finding, $Disposition, $Reply, $PullRequestId) }
}
Import-PrClearanceBindForTest -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
$cleared = Clear-ReviewRequests -PullRequestId 42
Assert-Equal 1 $script:clearCalls 'Clear-ReviewRequests dispatched to the Review tool'
Assert-Equal 2 $cleared.ResolvedCount 'clear result exposes ResolvedCount'
$okNotes = @(Get-PrClearanceReviewRequestClearNotes -Result $cleared)
Assert-Equal 1 $okNotes.Count 'cleared threads produce one note'
Assert-True ($okNotes[0] -match '2 leftover') 'clear note names the count'

Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Get-ReviewState'        = { param($PullRequestId, $Sha) [pscustomobject]@{ state = 'finished_this_sha'; tipSha = $Sha } }
    'Request-Review'         = { param($PullRequestId) }
    'Clear-ReviewRequests'   = { param($PullRequestId) throw 'ADO down' }
    'Get-ReviewFindings'     = { param($PullRequestId) @() }
    'Complete-ReviewFinding' = { param($Finding, $Disposition, $Reply, $PullRequestId) }
}
Import-PrClearanceBindForTest -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
$clearFailed = Clear-ReviewRequests -PullRequestId 42
Assert-Equal 0 $clearFailed.ResolvedCount 'throwing clear returns ResolvedCount 0'
Assert-True (@($clearFailed.Warnings).Count -ge 1) 'throwing clear becomes Warnings'
$failNotes = @(Get-PrClearanceReviewRequestClearNotes -Result $clearFailed)
Assert-True ($failNotes.Count -ge 1) 'warnings become finalize notes'
$emptyNotes = @(Get-PrClearanceReviewRequestClearNotes -Result ([pscustomobject]@{ ResolvedCount = 0; Warnings = @() }))
Assert-Equal 0 $emptyNotes.Count 'zero cleared with no warnings is silent'

# --- 5. Fixture dismiss ---
$script:completed = @()
Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Get-ReviewState'     = { param($PullRequestId, $Sha) [pscustomobject]@{ state = 'finished_this_sha'; tipSha = $Sha } }
    'Request-Review'      = { param($PullRequestId) }
    'Get-ReviewFindings'  = { param($PullRequestId) @([pscustomobject]@{ Id = 't1'; Number = 1; Path = 'a.cs'; Line = '2'; Comment = 'nits' }) }
    'Complete-ReviewFinding' = {
        param($Finding, $Disposition, $Reply, $PullRequestId)
        $script:completed += [pscustomobject]@{ Id = $Finding.Id; Disposition = $Disposition; Reply = $Reply }
    }
}
Import-PrClearanceBindForTest -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
$finding = @(Get-ReviewFindings -PullRequestId 7)[0]
Complete-ReviewFinding -Finding $finding -Disposition dismissed -Reply '**Issue:** nits`n**Fix:** out of scope' -PullRequestId 7
Assert-Equal 1 @($script:completed).Count 'one complete call'
Assert-Equal 'dismissed' $script:completed[0].Disposition 'dismissed disposition'
Assert-True ($null -eq (Get-Command -Name New-GitCoreCommit -ErrorAction SilentlyContinue)) 'dismiss does not load Vcs commit'

# --- 6. Fixture fix + temp git-core repo ---
$gitCoreCandidates = @(
    (Join-Path $env:USERPROFILE '.cursor\packs\git-core\scripts\git-core.ps1'),
    (Join-Path $packRoot '..\..\git-core\content\scripts\git-core.ps1'),
    (Join-Path (Split-Path -Parent (Split-Path -Parent $packRoot)) 'git-core\content\scripts\git-core.ps1')
)
$gitCoreSrc = $null
foreach ($candidate in $gitCoreCandidates) {
    $full = [IO.Path]::GetFullPath($candidate)
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $gitCoreSrc = $full
        break
    }
}
Assert-True (Test-Path -LiteralPath $gitCoreSrc) 'git-core source is available for the Vcs fixture'
. $gitCoreSrc

$repo = $null
$script:prevGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$script:prevGitConfigNosystem = $env:GIT_CONFIG_NOSYSTEM
try {
    $repo = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $repo | Out-Null
    $emptyConfig = Join-Path $repo 'empty.gitconfig'
    New-Item -ItemType File -Force -Path $emptyConfig | Out-Null
    $env:GIT_CONFIG_GLOBAL = $emptyConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    & git -C $repo init | Out-Null
    & git -C $repo symbolic-ref HEAD refs/heads/main
    & git -C $repo config user.email 'pr-clearance-test@example.com'
    & git -C $repo config user.name 'pr-clearance-test'
    & git -C $repo config commit.gpgsign false
    Set-Content -LiteralPath (Join-Path $repo 'seed.txt') -Value 'seed' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $repo -Message 'seed' -Path @('seed.txt')
    $bare = Join-Path $repo 'bare.git'
    & git init --bare $bare | Out-Null
    & git --git-dir $bare symbolic-ref HEAD refs/heads/main
    $null = Invoke-GitCore -RepoRoot $repo -GitArgs @('remote', 'add', 'origin', $bare)

    $script:completedFix = $null
    Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
        'Get-ReviewState' = { param($PullRequestId, $Sha) [pscustomobject]@{ state = 'finished_this_sha'; tipSha = $Sha } }
        'Request-Review' = { param($PullRequestId) }
        'Get-ReviewFindings' = { param($PullRequestId) @([pscustomobject]@{ Id = 't2'; Number = 1; Path = 'fix.txt'; Line = '1'; Comment = 'add file' }) }
        'Complete-ReviewFinding' = {
            param($Finding, $Disposition, $Reply, $PullRequestId)
            $script:completedFix = [pscustomobject]@{ Disposition = $Disposition; Id = $Finding.Id }
        }
    }
    Import-PrClearanceBindForTest -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
    Set-Content -LiteralPath (Join-Path $repo 'fix.txt') -Value 'fixed' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $repo -Message "fix: clear review findings on PR #9`n`nAdd fix.txt" -Path @('fix.txt')
    Push-GitCore -RepoRoot $repo
    Complete-ReviewFinding -Finding ([pscustomobject]@{ Id = 't2'; Number = 1; Path = 'fix.txt'; Line = '1'; Comment = 'add file' }) `
        -Disposition fixed -Reply '**Issue:** add file`n**Fix:** added' -PullRequestId 9
    Assert-Equal 'fixed' $script:completedFix.Disposition 'fix completed as fixed'
    $bareHead = Invoke-GitCore -RepoRoot $repo -GitArgs @('--git-dir', $bare, 'rev-parse', 'HEAD')
    Assert-True $bareHead.ok 'pushed to temp remote'
}
finally {
    if ($null -ne $script:prevGitConfigGlobal) { $env:GIT_CONFIG_GLOBAL = $script:prevGitConfigGlobal } else { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
    if ($null -ne $script:prevGitConfigNosystem) { $env:GIT_CONFIG_NOSYSTEM = $script:prevGitConfigNosystem } else { Remove-Item Env:GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue }
    if ($repo) { Remove-Item -LiteralPath $repo -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Changed paths prefer origin/target over a stale local target ---
$pathsRepo = $null
$script:prevGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$script:prevGitConfigNosystem = $env:GIT_CONFIG_NOSYSTEM
try {
    $pathsRepo = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-paths-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $pathsRepo | Out-Null
    $emptyConfig = Join-Path $pathsRepo 'empty.gitconfig'
    New-Item -ItemType File -Force -Path $emptyConfig | Out-Null
    $env:GIT_CONFIG_GLOBAL = $emptyConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    & git -C $pathsRepo init | Out-Null
    & git -C $pathsRepo symbolic-ref HEAD refs/heads/dev
    & git -C $pathsRepo config user.email 'pr-clearance-test@example.com'
    & git -C $pathsRepo config user.name 'pr-clearance-test'
    & git -C $pathsRepo config commit.gpgsign false
    Set-Content -LiteralPath (Join-Path $pathsRepo 'seed.txt') -Value 'seed' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $pathsRepo -Message 'seed' -Path @('seed.txt')
    $staleDev = ([string](Invoke-GitCore -RepoRoot $pathsRepo -GitArgs @('rev-parse', 'HEAD')).output).Trim()
    Set-Content -LiteralPath (Join-Path $pathsRepo 'extra.txt') -Value 'landed on target' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $pathsRepo -Message 'extra on current target' -Path @('extra.txt')
    $bare = Join-Path $pathsRepo 'bare.git'
    & git init --bare $bare | Out-Null
    & git --git-dir $bare symbolic-ref HEAD refs/heads/dev
    $null = Invoke-GitCore -RepoRoot $pathsRepo -GitArgs @('remote', 'add', 'origin', $bare)
    Push-GitCore -RepoRoot $pathsRepo
    $null = Invoke-GitCore -RepoRoot $pathsRepo -GitArgs @('checkout', '-b', 'feature')
    Set-Content -LiteralPath (Join-Path $pathsRepo 'pr-only.txt') -Value 'this pr' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $pathsRepo -Message 'pr change' -Path @('pr-only.txt')
    $null = Invoke-GitCore -RepoRoot $pathsRepo -GitArgs @('branch', '-f', 'dev', $staleDev)

    $changed = @(Get-PrClearancePrChangedPaths -RepoRoot $pathsRepo -TargetRef 'refs/heads/dev')
    Assert-True ($changed -contains 'pr-only.txt') 'PR file is in the origin/target change set'
    Assert-True (-not ($changed -contains 'extra.txt')) 'files already on origin/target are not treated as this PR'
    Assert-Equal 1 $changed.Count 'stale local target does not widen the allowlist to the whole tree'

    $null = Invoke-GitCore -RepoRoot $pathsRepo -GitArgs @('update-ref', '-d', 'refs/remotes/origin/dev')
    $refetched = @(Get-PrClearancePrChangedPaths -RepoRoot $pathsRepo -TargetRef 'refs/heads/dev')
    Assert-True ($refetched -contains 'pr-only.txt') 'fetch restores origin/target before the allowlist'
    Assert-True (-not ($refetched -contains 'extra.txt')) 'refreshed origin/target is not the stale local branch'

    $null = Invoke-GitCore -RepoRoot $pathsRepo -GitArgs @('remote', 'remove', 'origin')
    $null = Invoke-GitCore -RepoRoot $pathsRepo -GitArgs @('update-ref', '-d', 'refs/remotes/origin/dev')
    $localOnly = @(Get-PrClearancePrChangedPaths -RepoRoot $pathsRepo -TargetRef 'refs/heads/dev')
    Assert-True ($localOnly -contains 'pr-only.txt') 'local target is used when origin/target is missing'
    Assert-True ($localOnly -contains 'extra.txt') 'local-only fallback diffs against the stale local target'
}
finally {
    if ($null -ne $script:prevGitConfigGlobal) { $env:GIT_CONFIG_GLOBAL = $script:prevGitConfigGlobal } else { Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue }
    if ($null -ne $script:prevGitConfigNosystem) { $env:GIT_CONFIG_NOSYSTEM = $script:prevGitConfigNosystem } else { Remove-Item Env:GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue }
    if ($pathsRepo) { Remove-Item -LiteralPath $pathsRepo -Recurse -Force -ErrorAction SilentlyContinue }
}

# --- Repo root from PR ---
Reset-PrClearanceRegistry
Register-PrClearanceTool -ToolId 'ado-core' -Operations @{
    TryGetPullRequest = {
        param($RepoRoot, $PullRequestId)
        if ($RepoRoot -eq 'C:\Repos\approvals') {
            return [pscustomobject]@{ RepoRoot = $RepoRoot; PullRequest = [pscustomobject]@{ sourceRefName = 'refs/heads/feat' } }
        }
        return $null
    }
}
$oneHit = Resolve-PrClearanceRepoRoot -PullRequestId 12 -WorkspaceRoots @('C:\Repos\ai-devtools', 'C:\Repos\approvals')
Assert-Equal 'one' $oneHit.Status 'one matching remote is chosen'
Assert-Equal 'C:\Repos\approvals' $oneHit.RepoRoot 'chosen root is the PR hit, not the first folder'

Register-PrClearanceTool -ToolId 'ado-core' -Operations @{
    TryGetPullRequest = {
        param($RepoRoot, $PullRequestId)
        return [pscustomobject]@{ RepoRoot = $RepoRoot; PullRequest = [pscustomobject]@{ sourceRefName = 'refs/heads/feat' } }
    }
}
$several = Resolve-PrClearanceRepoRoot -PullRequestId 12 -WorkspaceRoots @('C:\Repos\a', 'C:\Repos\b')
Assert-Equal 'several' $several.Status 'several hits stay ambiguous'
Assert-True (@($several.Roots).Count -eq 2) 'several returns both roots'

Register-PrClearanceTool -ToolId 'ado-core' -Operations @{
    TryGetPullRequest = { param($RepoRoot, $PullRequestId) $null }
}
$none = Resolve-PrClearanceRepoRoot -PullRequestId 12 -WorkspaceRoots @('C:\Repos\ai-devtools')
Assert-Equal 'none' $none.Status 'no hit does not default a folder'

# --- Fetched NextAction uses composed quiet ---
Reset-PrClearanceRegistry
Register-PrClearanceTool -ToolId 'codeant-triage' -Operations @{
    'Get-ReviewState' = { param($PullRequestId, $Sha) [pscustomobject]@{ state = 'finished_this_sha'; tipSha = $Sha } }
    'Get-ReviewFindings' = { param($PullRequestId) @() }
    'Request-Review' = { param($PullRequestId) }
    'Complete-ReviewFinding' = { param($Finding, $Disposition, $Reply, $PullRequestId) }
}
Import-PrClearanceBindForTest -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
$fetched = Get-PrClearanceNextAction -PullRequestId 3 -Sha 'abc' -ActBatchCount 0
Assert-Equal 'finalize_quiet' $fetched.action 'fetched finished_this_sha + empty findings is finalize_quiet'

# --- Pack load stays in the caller session ---
Reset-PrClearanceRegistry
$probeDir = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-load-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $probeDir | Out-Null
$probeScript = Join-Path $probeDir 'probe.ps1'
Set-Content -LiteralPath $probeScript -Value 'function Get-PrClearanceSessionProbe { "ok" }' -Encoding UTF8
if (Get-Command -Name Get-PrClearanceSessionProbe -ErrorAction SilentlyContinue) {
    Remove-Item -Path Function:Get-PrClearanceSessionProbe -ErrorAction SilentlyContinue
    Remove-Item -Path Function:global:Get-PrClearanceSessionProbe -ErrorAction SilentlyContinue
}
try {
    Register-PrClearanceTool -ToolId 'codeant-triage' -Load {
        Import-PrClearanceScriptToSession -Path $probeScript
    } -Operations @{
        'Get-ReviewState'        = { }
        'Request-Review'         = { }
        'Get-ReviewFindings'     = { }
        'Complete-ReviewFinding' = { }
    }
    Register-PrClearanceTool -ToolId 'ado-core' -Load { } -Operations @{
        TryGetPullRequest = { $null }
    }
    Register-PrClearanceTool -ToolId 'git-core' -Load { } -Operations @{}
    Import-PrClearanceTools -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
    Assert-True ($null -ne (Get-Command -Name Get-PrClearanceSessionProbe -ErrorAction SilentlyContinue)) 'dotted pack functions remain after Import-PrClearanceTools'
}
finally {
    Remove-Item -LiteralPath $probeDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path Function:Get-PrClearanceSessionProbe -ErrorAction SilentlyContinue
    Remove-Item -Path Function:global:Get-PrClearanceSessionProbe -ErrorAction SilentlyContinue
}

Reset-PrClearanceRegistry
foreach ($n in @('Get-CodeAntReviewState', 'Request-CodeAntReview', 'Get-CodeAntReviewFindings', 'Complete-CodeAntReviewFinding', 'Clear-CodeAntReviewRequests', 'Invoke-CodeAntSilentTriage')) {
    if (Get-Command -Name $n -ErrorAction SilentlyContinue) {
        Remove-Item -Path "Function:$n" -ErrorAction SilentlyContinue
        Remove-Item -Path "Function:global:$n" -ErrorAction SilentlyContinue
    }
}
$triageLibCandidates = @(
    (Join-Path (Split-Path -Parent (Split-Path -Parent $packRoot)) 'codeant-triage\content\scripts\codeant-triage-lib.ps1'),
    (Join-Path $env:USERPROFILE '.cursor\packs\codeant-triage\scripts\codeant-triage-lib.ps1')
)
$triageLib = $null
foreach ($candidate in $triageLibCandidates) {
    $full = [IO.Path]::GetFullPath($candidate)
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        $triageLib = $full
        break
    }
}
Assert-True ($null -ne $triageLib) 'codeant-triage lib is available to import'
Register-PrClearanceTool -ToolId 'codeant-triage' -Load {
    Import-PrClearanceScriptToSession -Path $triageLib
} -Operations @{
    'Get-ReviewState'        = { }
    'Request-Review'         = { }
    'Clear-ReviewRequests'   = { }
    'Get-ReviewFindings'     = { }
    'Complete-ReviewFinding' = { }
}
Import-PrClearanceTools -Config (Get-PrClearanceBindConfig -PackRoot $packRoot)
foreach ($n in @('Get-CodeAntReviewState', 'Request-CodeAntReview', 'Get-CodeAntReviewFindings', 'Complete-CodeAntReviewFinding', 'Clear-CodeAntReviewRequests', 'Invoke-CodeAntSilentTriage')) {
    Assert-True ($null -ne (Get-Command -Name $n -ErrorAction SilentlyContinue)) "$n is visible after Import-PrClearanceTools"
}

# --- 8. Act register (repo scratch, fuse, no kick without code change) ---
$regRoot = Join-Path ([IO.Path]::GetTempPath()) ('pr-clearance-reg-' + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Force -Path $regRoot | Out-Null
try {
    $regPath = Get-PrClearanceActRegisterPath -RepoRoot $regRoot -PullRequestId 30128
    Assert-True ($regPath -match '[\\/]\.tmp[\\/]pr-clearance[\\/]act-register-30128\.json$') 'register lives under repo .tmp/pr-clearance'
    Assert-True ($regPath.StartsWith([IO.Path]::GetFullPath($regRoot))) 'register stays under the repo root'
    Assert-True ($regPath -notmatch [regex]::Escape((Join-Path $env:USERPROFILE '.cursor'))) 'register is not under the user .cursor profile'

    $a = [pscustomobject]@{
        Id = 'thread-1'; Number = 1; Path = '/contrib/Foo.ps1'; Line = '10'
        Comment = "**Suggestion:** Do not retain the cache.`nMore prose."
    }
    $b = [pscustomobject]@{
        Id = 'thread-99'; Number = 9; Path = 'contrib\foo.ps1'; Line = '10'
        Comment = "**Suggestion:** Do not retain the cache.`nDifferent thread."
    }
    $fpA = Get-PrClearanceFindingFingerprint -Finding $a
    $fpB = Get-PrClearanceFindingFingerprint -Finding $b
    Assert-Equal $fpA $fpB 'fingerprint ignores Id and path slash/case'

    $reg = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 30128
    Assert-Equal 30128 $reg.pullRequestId 'empty register remembers the PR id'
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $reg -Finding $a) 'fresh fingerprint is not exhausted'

    $reg = Add-PrClearanceActRegisterFix -Register $reg -Finding $a -Sha 'aaa111'
    $reg = Add-PrClearanceActRegisterFix -Register $reg -Finding $b -Sha 'bbb222'
    Save-PrClearanceActRegister -RepoRoot $regRoot -Register $reg
    Assert-True (Test-Path -LiteralPath $regPath -PathType Leaf) 'save writes the scratch file'

    $reloaded = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 30128
    $third = [pscustomobject]@{
        Id = 'thread-new'; Number = 3; Path = 'contrib/foo.ps1'; Line = '44'
        Comment = "**Suggestion:** Do not retain the cache."
    }
    Assert-Equal 'dismiss' (Get-PrClearancePolicyOverride -Register $reloaded -Finding $third) 'third same suggestion is dismiss'

    $pathFinding = [pscustomobject]@{
        Id = 'other'; Number = 4; Path = 'contrib/bar.ps1'; Line = '1'
        Comment = '**Suggestion:** brand new note'
    }
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $reloaded -Finding $pathFinding) 'new suggestion on another path is not fingerprint-exhausted'

    $pathReg = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 7
    $pathReg = Add-PrClearanceActRegisterPathBatch -Register $pathReg -Paths @('contrib/bar.ps1') -Batch 1
    $pathReg = Add-PrClearanceActRegisterPathBatch -Register $pathReg -Paths @('contrib/bar.ps1') -Batch 2
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $pathReg -Finding $pathFinding) 'two consecutive path fixes are not enough'
    $pathReg = Add-PrClearanceActRegisterPathBatch -Register $pathReg -Paths @('contrib/bar.ps1') -Batch 3
    Assert-Equal 'dismiss' (Get-PrClearancePolicyOverride -Register $pathReg -Finding $pathFinding) 'third consecutive path fix exhausts that path'

    Assert-True (-not (Test-PrClearanceShouldKickAfterAct -CodeChanged:$false)) 'no product-code change -> do not kick'
    Assert-True (Test-PrClearanceShouldKickAfterAct -CodeChanged) 'product-code change -> kick'

    $allDismiss = @(
        $third,
        [pscustomobject]@{ Id = 'x'; Number = 5; Path = 'contrib/foo.ps1'; Line = '2'; Comment = '**Suggestion:** Do not retain the cache.' }
    )
    Assert-True (Test-PrClearanceAllFindingsExhausted -Register $reloaded -Findings $allDismiss) 'all remaining same-fingerprint findings are exhausted'

    $report = @(Get-PrClearanceRepeatedReport -Register $reloaded)
    Assert-True ($report.Count -ge 1) 'repeated report is non-empty after two fixes'
    Assert-True ([int]$report[0].hits -ge 2) 'repeated report includes hit count'
    Assert-True ([bool]$report[0].dismissedBecauseRepeat) 'repeated report marks dismiss-because-repeat once the fuse trips'

    $amendReg = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 88
    $amendFinding = [pscustomobject]@{
        Id = 'a1'; Number = 1; Path = 'legacy/Widget.cs'; Line = '1'
        Comment = '**Suggestion:** unused import'
    }
    $otherFinding = [pscustomobject]@{
        Id = 'b1'; Number = 2; Path = 'legacy/Other.cs'; Line = '1'
        Comment = '**Suggestion:** unused import'
    }
    foreach ($n in 1..4) {
        $amendReg = Add-PrClearanceActRegisterPathBatch -Register $amendReg -Paths @('legacy/Widget.cs') -Batch ((2 * $n) - 1)
        $amendReg = Add-PrClearanceActRegisterPathBatch -Register $amendReg -Paths @('legacy/Other.cs') -Batch (2 * $n)
    }
    Assert-Equal 4 (Get-PrClearancePathAmendCount -Register $amendReg -Path 'legacy/Widget.cs') 'four interleaved amends on Widget'
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $amendReg -Finding $amendFinding) 'four amends do not cap the file'
    $amendReg = Add-PrClearanceActRegisterPathBatch -Register $amendReg -Paths @('legacy/Widget.cs') -Batch 9
    Assert-Equal 5 (Get-PrClearancePathAmendCount -Register $amendReg -Path 'legacy/Widget.cs') 'fifth amend is recorded'
    Assert-Equal 'dismiss' (Get-PrClearancePolicyOverride -Register $amendReg -Finding $amendFinding) 'fifth amend caps that file for this clearance'
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $amendReg -Finding $otherFinding) 'other file is not capped by Widget amends'

    $prPaths = @('contrib/foo.ps1', 'contrib/bar.ps1')
    $onPr = [pscustomobject]@{
        Id = 'p1'; Number = 1; Path = '/contrib/Foo.ps1'; Line = '3'
        Comment = '**Suggestion:** narrow hole'
    }
    $offPr = [pscustomobject]@{
        Id = 'p2'; Number = 2; Path = 'legacy/OldService.cs'; Line = '80'
        Comment = '**Suggestion:** extract a helper and clean surrounding style'
    }
    Assert-True (Test-PrClearanceFindingInPrScope -Path $onPr.Path -ChangedPaths $prPaths) 'PR file is in scope'
    Assert-True (-not (Test-PrClearanceFindingInPrScope -Path $offPr.Path -ChangedPaths $prPaths)) 'file not on the PR is out of scope'
    Assert-True (Test-PrClearanceFindingInPrScope -Path $offPr.Path) 'missing change-set does not invent a block'
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $reg -Finding $onPr -ChangedPaths $prPaths) 'in-scope finding is not forced dismiss'
    Assert-Equal 'dismiss' (Get-PrClearancePolicyOverride -Register $reg -Finding $offPr -ChangedPaths $prPaths) 'out-of-PR finding is dismissed'
    Assert-True (Test-PrClearanceAllFindingsExhausted -Register $reg -Findings @($offPr) -ChangedPaths $prPaths) 'all out-of-PR leftovers are exhausted'

    $snap = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 42
    $snap = Set-PrClearanceChangedPaths -Register $snap -ChangedPaths $prPaths
    $firstBatch = @(
        $onPr,
        [pscustomobject]@{ Id = 'p3'; Number = 3; Path = 'contrib/bar.ps1'; Line = '1'; Comment = '**Suggestion:** first-batch hole' }
    )
    $snap = Set-PrClearanceFindingPathSnapshot -Register $snap -Findings $firstBatch -ChangedPaths $prPaths
    $laterSame = [pscustomobject]@{
        Id = 'new-thread'; Number = 9; Path = 'contrib/foo.ps1'; Line = '20'
        Comment = '**Suggestion:** a different hole on a first-batch file'
    }
    $laterNewFile = [pscustomobject]@{
        Id = 'creep'; Number = 10; Path = 'contrib/pr-clearance-lib.ps1'; Line = '4'
        Comment = '**Suggestion:** also tidy this neighbouring pack file'
    }
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $snap -Finding $laterSame -ChangedPaths $prPaths) 'new suggestion on a first-batch file stays in scope'
    $farOnFirst = [pscustomobject]@{
        Id = 'far'; Number = 11; Path = 'contrib/foo.ps1'; Line = '400'
        Comment = '**Suggestion:** any line on a first-findings file'
    }
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $snap -Finding $farOnFirst -ChangedPaths $prPaths) 'first-findings file stays whole-file'
    Assert-Equal 'dismiss' (Get-PrClearancePolicyOverride -Register $snap -Finding $laterNewFile -ChangedPaths @($prPaths + 'contrib/pr-clearance-lib.ps1')) 'later-batch file is dismissed even if git change-set grew'

    $joined = Add-PrClearanceActRegisterJoin -Register $snap -Paths @('legacy/Helper.cs') -Sha 'abc' -Batch 1 -Hunks @(
        [pscustomobject]@{
            path   = 'legacy/Helper.cs'
            ranges = @([pscustomobject]@{ start = 20; end = 35 })
        }
    )
    $onHunk = [pscustomobject]@{
        Id = 'join-in'; Number = 12; Path = 'legacy/Helper.cs'; Line = '22:24'
        Comment = '**Suggestion:** the extracted helper'
    }
    $offHunk = [pscustomobject]@{
        Id = 'join-out'; Number = 13; Path = 'legacy/Helper.cs'; Line = '200'
        Comment = '**Suggestion:** old method in the helper class'
    }
    $fileLevel = [pscustomobject]@{
        Id = 'join-file'; Number = 14; Path = 'legacy/Helper.cs'; Line = ''
        Comment = '**Suggestion:** file-level note on the helper'
    }
    Assert-True (Test-PrClearanceFindingInJoinedPaths -Register $joined -Path 'legacy/Helper.cs') 'Act helper is joined'
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $joined -Finding $onHunk -ChangedPaths $prPaths) 'joined helper line in Act hunks stays in scope'
    Assert-Equal 'dismiss' (Get-PrClearancePolicyOverride -Register $joined -Finding $offHunk -ChangedPaths $prPaths) 'joined helper line outside Act hunks is dismissed'
    Assert-Equal $null (Get-PrClearancePolicyOverride -Register $joined -Finding $fileLevel -ChangedPaths $prPaths) 'file-level comment on a joined helper stays in scope'
    $snapAgain = Set-PrClearanceFindingPathSnapshot -Register $snap -Findings @($laterNewFile) -ChangedPaths @($prPaths + 'contrib/pr-clearance-lib.ps1')
    Assert-True (-not (@($snapAgain.clearancePaths) -contains (Get-PrClearanceNormalizedPath -Path 'contrib/pr-clearance-lib.ps1'))) 'snapshot does not grow after it is frozen'

    $fpCap = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 46
    foreach ($n in 1..40) {
        $fpCap = Add-PrClearanceActRegisterFix -Register $fpCap -Finding ([pscustomobject]@{
                Id = "t$n"; Number = $n; Path = "contrib/foo.ps1"; Line = '1'
                Comment = "**Suggestion:** unique $n"
            })
    }
    Assert-True (@($fpCap.fingerprints).Count -le 32) 'fingerprints stay bounded'

    $unique = @(Get-PrClearanceUniqueNormalizedPaths -Paths @('A/B.ps1', 'a/b.ps1', 'A/B.ps1', ''))
    Assert-Equal 1 $unique.Count 'duplicate paths collapse to one normalized entry'

    $emptyAllow = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 43
    $emptyAllow = Set-PrClearanceChangedPaths -Register $emptyAllow -ChangedPaths @()
    Assert-True (-not [bool]$emptyAllow.changedPathsFrozen) 'empty change-set does not freeze an allowlist'

    $emptySnap = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 44
    $emptySnap = Set-PrClearanceFindingPathSnapshot -Register $emptySnap -Findings @($offPr) -ChangedPaths $prPaths
    Assert-True (-not [bool]$emptySnap.clearancePathsFrozen) 'out-of-scope-only first batch does not freeze an empty snapshot'

    $boundReg = Read-PrClearanceActRegister -RepoRoot $regRoot -PullRequestId 45
    foreach ($n in 1..15) {
        $boundReg = Add-PrClearanceActRegisterPathBatch -Register $boundReg -Paths @("f$n.ps1") -Batch $n
    }
    Assert-True (@($boundReg.pathBatches).Count -le 10) 'pathBatches keeps only recent history'

    $readmePath = Join-Path $packRoot 'content\README.md'
    if (-not (Test-Path -LiteralPath $readmePath -PathType Leaf)) {
        $readmePath = Join-Path $packRoot 'README.md'
    }
    $readme = Get-Content -LiteralPath $readmePath -Raw
    Assert-True ($readme -notmatch '(?m)^\s*"git"\s*,?\s*$') 'readme allowlist has no bare git prefix'
    Assert-True ($readme -notmatch '"git -C "') 'readme allowlist has no generic git -C prefix'
    Assert-True ($readme -match '"git status"') 'readme allowlist names git status'
    Assert-True ($readme -match '"git commit"') 'readme allowlist names git commit'
    Assert-True ($readme -match '"git push"') 'readme allowlist names git push'

    $commandCandidates = @(
        (Join-Path (Split-Path -Parent $packRoot) 'adapters\cursor\commands\pr-clearance.md'),
        (Join-Path $packRoot 'adapters\cursor\commands\pr-clearance.md'),
        (Join-Path (Split-Path -Parent (Split-Path -Parent $packRoot)) 'commands\pr-clearance.md')
    )
    $commandPath = $commandCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    Assert-True ($null -ne $commandPath) 'slash command file exists for explain-block check'
    if ($null -ne $commandPath) {
        $commandText = Get-Content -LiteralPath $commandPath -Raw
        foreach ($marker in @('Review said', 'Why this needs a human', 'Proposed change', 'Finding #N of M')) {
            Assert-True ($commandText.Contains($marker)) "interim explain includes $marker"
        }
        Assert-True ($commandText -match '(?i)never show only the question card') 'human bounce always includes finding details'
        Assert-True ($commandText -match '(?i)product choice alone') 'command does not bounce merely for product flavour'
        Assert-True ($commandText -match '(?i)justification') 'fixed public replies preserve specialist reasoning'
        Assert-True ($commandText.Contains('pr-clearance-policy.md')) 'command names pr-clearance-policy.md'
        Assert-True ($commandText.Contains('sicon-pr-clearance')) 'command probes the marketplace plugin id'
        $pluginIdx = $commandText.IndexOf('sicon-pr-clearance')
        $packIdx = $commandText.IndexOf('.cursor\packs\pr-clearance\scripts')
        Assert-True ($pluginIdx -ge 0) 'plugin token is present for index check'
        Assert-True ($packIdx -gt $pluginIdx) 'command prefers plugin scripts before user-pack scripts'
        Assert-True ($commandText.Contains('Get-PrClearancePolicyDecision')) 'command names Get-PrClearancePolicyDecision'
        Assert-True (-not $commandText.Contains('Return `{ action: fix | dismiss | ask, reason }`')) 'command no longer returns fix|dismiss|ask'
        Assert-True ($commandText.Contains('Invoke-PrClearanceSpecialist')) 'command names Invoke-PrClearanceSpecialist'
        Assert-True ($commandText.Contains('Group-PrClearancePassFindingsByPath')) 'command names Group-PrClearancePassFindingsByPath'
        Assert-True ($commandText.Contains('PreparedResults')) 'command names PreparedResults'
        Assert-True ($commandText.Contains('codeant-silent-triage.md')) 'command names codeant-silent-triage.md'
        Assert-True ($commandText -match '(?i)not a finished Act') 'command says a bare port call is not a finished Act'
        Assert-True ($commandText -match '(?i)specialist needs a decision') 'specialist ask prompt is not Policy could not decide'
        Assert-True (-not $commandText.Contains('Each `fix`: implement if needed')) 'command no longer says Each `fix`: implement if needed'
        Assert-True ($commandText.Contains('one specialist')) 'command states one specialist per Act'
        Assert-True ($commandText -match '(?i)serial') 'command states serial Path'
        Assert-True ($commandText -match '(?i)dispose') 'command states dispose at Act end'
    }

    $stopReply = Get-PrClearanceHardStopReply -Reason max_batches
    Assert-True ($stopReply -match 'without a fix') 'hard-stop reply says closed without a fix'
    Assert-True ($stopReply -match 'batch') 'hard-stop reply names the batch cap'
    Assert-True ($stopReply -match '\*\*WontFix Reason:\*\*') 'batch hard-stop uses WontFix reply shape'
    Assert-True ($stopReply -notmatch '\*\*Closed:\*\*') 'batch hard-stop does not invent a third reply label'
    $timeReply = Get-PrClearanceHardStopReply -Reason timeout
    Assert-True ($timeReply -match 'without a fix') 'timeout reply says closed without a fix'
    Assert-True ($timeReply -match '\*\*WontFix Reason:\*\*') 'timeout hard-stop uses WontFix reply shape'
}
finally {
    Remove-Item -LiteralPath $regRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# --- 7. Forbidden surface (production files only) ---
$needles = @(
    'Review Status',
    '@codeant-ai',
    '#codeant-ai',
    'review-codeant',
    'sicon-review-codeant',
    'Fetch-CodeAnt',
    'Post-CodeAnt',
    'Clear-CodeAntRetrigger',
    'Get-AdoCorePullRequestThreads',
    'New-AdoCorePullRequestThread',
    'Add-AdoCorePullRequestThreadComment',
    'Set-AdoCorePullRequestThreadStatus'
)
$scanRoots = @(
    (Join-Path $scriptDir 'pr-clearance-lib.ps1'),
    (Join-Path $packRoot 'bind-config.json'),
    (Join-Path $packRoot 'adapters\cursor\commands\pr-clearance.md'),
    (Join-Path $packRoot 'README.md'),
    (Join-Path $packRoot 'adapters\cursor\plugin-README.md')
)
# Source-tree paths (contrib layout)
$scanRoots += @(
    (Join-Path $packRoot 'content\bind-config.json'),
    (Join-Path (Split-Path -Parent $packRoot) 'adapters\cursor\commands\pr-clearance.md'),
    (Join-Path $packRoot 'content\README.md'),
    (Join-Path (Split-Path -Parent $packRoot) 'adapters\cursor\plugin-README.md')
)
$seen = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($path in $scanRoots) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
    $full = [IO.Path]::GetFullPath($path)
    if (-not $seen.Add($full)) { continue }
    $text = Get-Content -LiteralPath $full -Raw -ErrorAction Stop
    foreach ($needle in $needles) {
        if ($text.Contains($needle)) {
            [void]$failures.Add("forbidden '$needle' in $full")
        }
    }
}

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    Write-Error ('Test-PrClearance FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join $sep))
    exit 1
}

Write-Output 'OK: pr-clearance'
exit 0
