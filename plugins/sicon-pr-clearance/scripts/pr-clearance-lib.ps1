#Requires -Version 5.1
Set-StrictMode -Version Latest

$script:PrClearanceMaxActBatches = 10
$script:PrClearanceFingerprintFixLimit = 2
$script:PrClearanceFingerprintCap = 32
$script:PrClearancePathConsecutiveFixLimit = 3
$script:PrClearancePathAmendLimit = 5
$script:PrClearanceWaitTimeoutSeconds = 600
$script:PrClearanceTools = @{}
$script:PrClearanceBind = $null
$script:PrClearanceInstalledScriptCache = @{}

$script:PrClearanceAllowed = @{
    review    = @('codeant-triage')
    findings  = @('codeant-triage')
    forge     = @('ado-core')
    vcs       = @('git-core')
    specialist = @('codeant-triage')
}

function Reset-PrClearanceRegistry {
    $script:PrClearanceTools = @{}
    $script:PrClearanceBind = $null
    $script:PrClearanceInstalledScriptCache = @{}
}

function Register-PrClearanceTool {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ToolId,

        [Parameter(Mandatory = $true)]
        [hashtable]$Operations,

        [scriptblock]$Load
    )

    $script:PrClearanceTools[$ToolId] = @{
        Operations = $Operations
        Load       = $Load
    }
}

function Import-PrClearanceBindForTest {
    param(
        [Parameter(Mandatory = $true)]
        $Config
    )
    $script:PrClearanceBind = $Config
}

function Get-PrClearancePackRootFromLib {
    return (Split-Path -Parent $PSScriptRoot)
}

function Read-PrClearanceBindJson {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Test-PrClearanceToolIdValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Key,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $trimmed = $Value.Trim()
    if ($trimmed -match '\.ps1' -or $trimmed -match '[\\/]' -or $trimmed -match '^Get-' -or $trimmed -match '^Request-' -or $trimmed -match '^Complete-' -or $trimmed -match '^Wait-' -or $trimmed -match '^Test-') {
        throw "Unsupported tool id for ${Key}: value must be a tool id (not a script path or command name)."
    }
    $allowed = @($script:PrClearanceAllowed[$Key])
    if ($allowed -notcontains $trimmed) {
        throw "Unsupported tool id for ${Key}: '$trimmed'."
    }
    return $trimmed
}

function Get-PrClearanceBindConfig {
    param(
        [string]$PackRoot = '',
        [string]$UserConfigPath = ''
    )

    if ([string]::IsNullOrWhiteSpace($PackRoot)) {
        $PackRoot = Get-PrClearancePackRootFromLib
    }
    $packFile = Join-Path $PackRoot 'content\bind-config.json'
    if (-not (Test-Path -LiteralPath $packFile -PathType Leaf)) {
        $packFile = Join-Path $PackRoot 'bind-config.json'
    }
    $pack = Read-PrClearanceBindJson -Path $packFile
    if (-not $pack) {
        throw "Missing bind config. Install the pr-clearance plugin."
    }

    if ([string]::IsNullOrWhiteSpace($UserConfigPath)) {
        $UserConfigPath = Join-Path $env:USERPROFILE '.cursor\pr-clearance\bind-config.json'
    }
    $user = $null
    if ($UserConfigPath -and (Test-Path -LiteralPath $UserConfigPath -PathType Leaf)) {
        $user = Read-PrClearanceBindJson -Path $UserConfigPath
    }

    $merged = [ordered]@{
        review    = $null
        findings  = $null
        forge     = $null
        vcs       = $null
        specialist = $null
    }
    foreach ($key in @('review', 'findings', 'forge', 'vcs', 'specialist')) {
        $value = $null
        if ($user -and $user.PSObject.Properties.Name -contains $key -and -not [string]::IsNullOrWhiteSpace([string]$user.$key)) {
            $value = [string]$user.$key
        }
        else {
            $value = [string]$pack.$key
        }
        $merged[$key] = Test-PrClearanceToolIdValue -Key $key -Value $value
    }

    return [pscustomobject]$merged
}

function Get-PrClearancePolicyMarkdownPath {
    param([string]$InstallRoot = '')

    if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $InstallRoot = Get-PrClearancePackRootFromLib
    }
    foreach ($rel in @('content\policy\pr-clearance-policy.md', 'policy\pr-clearance-policy.md')) {
        $candidate = Join-Path $InstallRoot $rel
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }
    }
    throw "Missing policy markdown. Install the pr-clearance plugin."
}

function Resolve-PrClearanceSelfScriptsRoot {
    param([string]$ProfileRoot = '')

    if ([string]::IsNullOrWhiteSpace($ProfileRoot)) {
        $ProfileRoot = Join-Path $env:USERPROFILE '.cursor'
    }

    $hits = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $pluginRoot = Join-Path $ProfileRoot 'plugins'
    $direct = Join-Path $pluginRoot 'sicon-pr-clearance\scripts\pr-clearance-lib.ps1'
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        [void]$hits.Add((Get-Item -LiteralPath $direct))
    }
    $cacheRoot = Join-Path $pluginRoot 'cache'
    $cached = Resolve-PrClearancePluginCacheScriptPath -CacheRoot $cacheRoot -PackId 'pr-clearance' -FileName 'pr-clearance-lib.ps1'
    if ($cached) {
        [void]$hits.Add((Get-Item -LiteralPath $cached))
    }
    if ($hits.Count -gt 0) {
        return @($hits | Sort-Object LastWriteTime -Descending)[0].DirectoryName
    }

    $packScripts = Join-Path $ProfileRoot 'packs\pr-clearance\scripts'
    $packLib = Join-Path $packScripts 'pr-clearance-lib.ps1'
    if (Test-Path -LiteralPath $packLib -PathType Leaf) {
        return $packScripts
    }
    return $null
}

function Resolve-PrClearancePluginCacheScriptPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CacheRoot,

        [Parameter(Mandatory = $true)]
        [string]$PackId,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if (-not (Test-Path -LiteralPath $CacheRoot -PathType Container)) {
        return $null
    }
    $pluginToken = "sicon-$PackId"
    $hits = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    foreach ($publisher in @(Get-ChildItem -LiteralPath $CacheRoot -Directory -ErrorAction SilentlyContinue)) {
        $packDir = Join-Path $publisher.FullName $pluginToken
        if (-not (Test-Path -LiteralPath $packDir -PathType Container)) {
            continue
        }
        $direct = Join-Path $packDir (Join-Path 'scripts' $FileName)
        if (Test-Path -LiteralPath $direct -PathType Leaf) {
            [void]$hits.Add((Get-Item -LiteralPath $direct))
        }
        foreach ($version in @(Get-ChildItem -LiteralPath $packDir -Directory -ErrorAction SilentlyContinue)) {
            $candidate = Join-Path $version.FullName (Join-Path 'scripts' $FileName)
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                [void]$hits.Add((Get-Item -LiteralPath $candidate))
            }
        }
    }
    if ($hits.Count -eq 0) {
        return $null
    }
    return @($hits | Sort-Object LastWriteTime -Descending)[0].FullName
}

function Resolve-PrClearanceInstalledScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackId,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    if ($null -eq $script:PrClearanceInstalledScriptCache) {
        $script:PrClearanceInstalledScriptCache = @{}
    }
    $cacheKey = "$PackId|$FileName"
    if ($script:PrClearanceInstalledScriptCache.ContainsKey($cacheKey)) {
        return $script:PrClearanceInstalledScriptCache[$cacheKey]
    }

    $profileScript = Join-Path $env:USERPROFILE ".cursor\packs\$PackId\scripts\$FileName"
    if (Test-Path -LiteralPath $profileScript -PathType Leaf) {
        $script:PrClearanceInstalledScriptCache[$cacheKey] = $profileScript
        return $profileScript
    }

    $pluginRoot = Join-Path $env:USERPROFILE '.cursor\plugins'
    $pluginToken = "sicon-$PackId"
    if (Test-Path -LiteralPath $pluginRoot) {
        $pluginScript = Join-Path $pluginRoot "$pluginToken\scripts\$FileName"
        if (Test-Path -LiteralPath $pluginScript -PathType Leaf) {
            $script:PrClearanceInstalledScriptCache[$cacheKey] = $pluginScript
            return $pluginScript
        }
        $cacheRoot = Join-Path $pluginRoot 'cache'
        if (Test-Path -LiteralPath $cacheRoot) {
            $pluginScript = Resolve-PrClearancePluginCacheScriptPath -CacheRoot $cacheRoot -PackId $PackId -FileName $FileName
            if ($pluginScript) {
                $script:PrClearanceInstalledScriptCache[$cacheKey] = $pluginScript
                return $pluginScript
            }
        }
    }
    return $null
}

function Import-PrClearanceInstalledPack {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackId,

        [Parameter(Mandatory = $true)]
        [string]$FileName
    )

    $path = Resolve-PrClearanceInstalledScript -PackId $PackId -FileName $FileName
    if (-not $path) {
        throw "Tool '$PackId' is not installed. Install that tool, then retry /pr-clearance."
    }
    return $path
}

function Import-PrClearanceScriptToSession {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $before = @{}
    Get-ChildItem Function: | ForEach-Object { $before[$_.Name] = $_.ScriptBlock }
    . $Path
    Get-ChildItem Function: | ForEach-Object {
        $name = $_.Name
        $updated = -not $before.ContainsKey($name)
        if (-not $updated) {
            $updated = -not [object]::ReferenceEquals($before[$name], $_.ScriptBlock)
        }
        if ($updated) {
            Set-Item -Path "Function:global:$name" -Value $_.ScriptBlock
        }
    }
}

function Initialize-PrClearanceDefaultTools {
    if (-not $script:PrClearanceTools.ContainsKey('codeant-triage')) {
        Register-PrClearanceTool -ToolId 'codeant-triage' -Load {
            $path = Import-PrClearanceInstalledPack -PackId 'codeant-triage' -FileName 'codeant-triage-lib.ps1'
            Import-PrClearanceScriptToSession -Path $path
            if (-not (Get-Command -Name Invoke-CodeAntSilentTriage -ErrorAction SilentlyContinue)) {
                $silentPath = Resolve-PrClearanceInstalledScript -PackId 'codeant-triage' -FileName 'codeant-silent-triage.ps1'
                if ($silentPath) {
                    Import-PrClearanceScriptToSession -Path $silentPath
                }
            }
            foreach ($name in @('Get-CodeAntReviewState', 'Request-CodeAntReview', 'Get-CodeAntReviewFindings', 'Complete-CodeAntReviewFinding', 'Clear-CodeAntReviewRequests', 'Invoke-CodeAntSilentTriage')) {
                if (-not (Get-Command -Name $name -ErrorAction SilentlyContinue)) {
                    throw "Tool 'codeant-triage' is installed but missing $name. Upgrade the codeant-triage tool, then retry /pr-clearance."
                }
            }
        } -Operations @{
            'Get-ReviewState'        = { param($PullRequestId, $Sha, $WorkspaceRoot) Get-CodeAntReviewState -PullRequestId $PullRequestId -Sha $Sha -WorkspaceRoot $WorkspaceRoot }
            'Request-Review'         = { param($PullRequestId, $WorkspaceRoot) Request-CodeAntReview -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot }
            'Clear-ReviewRequests'   = { param($PullRequestId, $WorkspaceRoot) Clear-CodeAntReviewRequests -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot }
            'Get-ReviewFindings'     = { param($PullRequestId, $WorkspaceRoot) Get-CodeAntReviewFindings -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot }
            'Complete-ReviewFinding' = { param($Finding, $Disposition, $Reply, $PullRequestId, $WorkspaceRoot) Complete-CodeAntReviewFinding -Finding $Finding -Disposition $Disposition -Reply $Reply -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot }
            'Invoke-Specialist'        = {
                param($Path, $Issues, $PullRequestId, $WorkspaceRoot, $PreparedResults)
                if (-not (Get-Command -Name Invoke-CodeAntSilentTriage -ErrorAction SilentlyContinue)) {
                    throw "Tool 'codeant-triage' is installed but missing Invoke-CodeAntSilentTriage. Upgrade the codeant-triage tool, then retry /pr-clearance."
                }
                Invoke-CodeAntSilentTriage -Path $Path -Issues $Issues -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot -PreparedResults $PreparedResults
            }
        }
    }

    if (-not $script:PrClearanceTools.ContainsKey('ado-core')) {
        Register-PrClearanceTool -ToolId 'ado-core' -Load {
            $path = Import-PrClearanceInstalledPack -PackId 'ado-core' -FileName 'ado-core.ps1'
            Import-PrClearanceScriptToSession -Path $path
        } -Operations @{
            TryGetPullRequest = {
                param($RepoRoot, $PullRequestId)
                try {
                    $endpoints = Resolve-AdoCoreEndpoints -WorkspaceRoot $RepoRoot
                }
                catch {
                    return $null
                }
                try {
                    $pr = Get-AdoCorePullRequest -PullRequestId $PullRequestId -ApiBase $endpoints.ApiBase
                    $url = Get-AdoCorePullRequestWebUrl -Endpoints $endpoints -PullRequestId $PullRequestId
                    return [pscustomobject]@{
                        RepoRoot    = $RepoRoot
                        PullRequest = $pr
                        Endpoints   = $endpoints
                        PrUrl       = $url
                    }
                }
                catch {
                    return $null
                }
            }
        }
    }

    if (-not $script:PrClearanceTools.ContainsKey('git-core')) {
        Register-PrClearanceTool -ToolId 'git-core' -Load {
            $path = Import-PrClearanceInstalledPack -PackId 'git-core' -FileName 'git-core.ps1'
            Import-PrClearanceScriptToSession -Path $path
        } -Operations @{}
    }
}

function Import-PrClearanceTools {
    param($Config)

    if (-not $Config) {
        $Config = Get-PrClearanceBindConfig
    }
    $script:PrClearanceBind = $Config
    Initialize-PrClearanceDefaultTools

    $needed = @($Config.review, $Config.findings, $Config.forge, $Config.vcs, $Config.specialist) | Select-Object -Unique
    foreach ($id in $needed) {
        if (-not $script:PrClearanceTools.ContainsKey($id)) {
            throw "Unsupported tool id: '$id'."
        }
        $entry = $script:PrClearanceTools[$id]
        if ($entry.Load) {
            & $entry.Load
        }
    }
}

function Get-PrClearanceBoundTool {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('review', 'findings', 'forge', 'vcs', 'specialist')]
        [string]$Port
    )

    if (-not $script:PrClearanceBind) {
        throw 'Bind config is not loaded.'
    }
    $id = [string]$script:PrClearanceBind.$Port
    if (-not $script:PrClearanceTools.ContainsKey($id)) {
        throw "Tool '$id' is not registered."
    }
    return $script:PrClearanceTools[$id]
}

function Invoke-PrClearanceOperation {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Port,

        [Parameter(Mandatory = $true)]
        [string]$Operation
    )

    $tool = Get-PrClearanceBoundTool -Port $Port
    $ops = $tool.Operations
    if (-not $ops.ContainsKey($Operation)) {
        throw "Tool '$($script:PrClearanceBind.$Port)' does not implement $Operation."
    }
    return $ops[$Operation]
}

function Get-ReviewState {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [string]$Sha,

        [string]$WorkspaceRoot = ''
    )

    $op = Invoke-PrClearanceOperation -Port review -Operation 'Get-ReviewState'
    return & $op $PullRequestId $Sha $WorkspaceRoot
}

function Request-Review {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = ''
    )

    $op = Invoke-PrClearanceOperation -Port review -Operation 'Request-Review'
    return & $op $PullRequestId $WorkspaceRoot
}

function Clear-ReviewRequests {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = ''
    )

    try {
        $op = Invoke-PrClearanceOperation -Port review -Operation 'Clear-ReviewRequests'
        $result = & $op $PullRequestId $WorkspaceRoot
        if ($null -eq $result) {
            return [pscustomobject]@{
                PullRequestId = $PullRequestId
                ResolvedCount = 0
                ThreadIds     = @()
                Warnings      = @()
            }
        }
        return $result
    }
    catch {
        return [pscustomobject]@{
            PullRequestId = $PullRequestId
            ResolvedCount = 0
            ThreadIds     = @()
            Warnings      = @([string]$_.Exception.Message)
        }
    }
}

function Get-ReviewFindings {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = ''
    )

    $op = Invoke-PrClearanceOperation -Port findings -Operation 'Get-ReviewFindings'
    return @(& $op $PullRequestId $WorkspaceRoot)
}

function Complete-ReviewFinding {
    param(
        [Parameter(Mandatory = $true)]
        $Finding,

        [Parameter(Mandatory = $true)]
        [ValidateSet('fixed', 'dismissed')]
        [string]$Disposition,

        [Parameter(Mandatory = $true)]
        [string]$Reply,

        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [string]$WorkspaceRoot = ''
    )

    $op = Invoke-PrClearanceOperation -Port findings -Operation 'Complete-ReviewFinding'
    return & $op $Finding $Disposition $Reply $PullRequestId $WorkspaceRoot
}

function Test-PrClearanceHttpNotFound {
    param($ErrorRecord)

    if ($null -eq $ErrorRecord) { return $false }
    $ex = $ErrorRecord.Exception
    while ($null -ne $ex) {
        if ($ex.PSObject.Properties.Name -contains 'Response' -and $ex.Response) {
            try {
                if ([int]$ex.Response.StatusCode -eq 404) { return $true }
            }
            catch {
            }
        }
        $ex = $ex.InnerException
    }
    return $false
}

function Resolve-PrClearanceFindingPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$Path = ''
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $raw = $Path.Trim()
    if ($raw -match '^[A-Za-z]:' -or $raw.StartsWith('\\')) {
        throw "Finding path is outside the repository: $Path"
    }
    $parts = $raw.TrimStart('/').TrimStart('\').Split([char[]]@('/', '\'))
    if ($parts -contains '..') {
        throw "Finding path is outside the repository: $Path"
    }
    $relative = [string]::Join([string][IO.Path]::DirectorySeparatorChar, $parts)
    $rootFull = [IO.Path]::GetFullPath($RepoRoot)
    if (-not $rootFull.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [IO.Path]::DirectorySeparatorChar
    }
    $full = [IO.Path]::GetFullPath((Join-Path $RepoRoot $relative))
    if (-not (Test-PrClearancePathUnderRoot -FullPath $full -RootFull $rootFull)) {
        throw "Finding path is outside the repository: $Path"
    }

    $cursor = [IO.Path]::GetFullPath($RepoRoot)
    foreach ($part in $parts) {
        $cursor = [IO.Path]::GetFullPath((Join-Path $cursor $part))
        if (-not (Test-Path -LiteralPath $cursor)) { break }
        $resolved = Get-PrClearanceResolvedPath -Path $cursor
        if ($resolved -and -not (Test-PrClearancePathUnderRoot -FullPath $resolved -RootFull $rootFull)) {
            throw "Finding path is outside the repository: $Path"
        }
    }
    if (Test-Path -LiteralPath $full) {
        $resolvedFull = Get-PrClearanceResolvedPath -Path $full
        if ($resolvedFull -and -not (Test-PrClearancePathUnderRoot -FullPath $resolvedFull -RootFull $rootFull)) {
            throw "Finding path is outside the repository: $Path"
        }
        if ($resolvedFull) {
            return $resolvedFull
        }
    }
    return $full
}

function Test-PrClearancePathUnderRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FullPath,

        [Parameter(Mandatory = $true)]
        [string]$RootFull
    )

    $candidate = $FullPath
    if (-not $candidate.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $asDir = $candidate + [IO.Path]::DirectorySeparatorChar
        return $candidate.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $asDir.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase)
    }
    return $candidate.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase)
}

function Get-PrClearanceResolvedPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $item = Get-Item -LiteralPath $Path -Force
    $guard = 0
    while ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $guard -lt 8) {
        $guard++
        $target = $item.Target
        if (-not $target) { break }
        $targetPath = if ($target -is [System.Array]) { [string]$target[0] } else { [string]$target }
        if ([string]::IsNullOrWhiteSpace($targetPath)) { break }
        if (-not [IO.Path]::IsPathRooted($targetPath)) {
            $parent = Split-Path -Parent $item.FullName
            $targetPath = Join-Path $parent $targetPath
        }
        if (-not (Test-Path -LiteralPath $targetPath)) { break }
        $item = Get-Item -LiteralPath $targetPath -Force
    }
    if ($item) { return $item.FullName }
    return $null
}

function Test-PrClearanceQuiet {
    param(
        [string]$State = '',
        $Findings = $null,
        [int]$PullRequestId = 0,
        [string]$Sha = '',
        [string]$WorkspaceRoot = ''
    )

    $mustFetchState = [string]::IsNullOrWhiteSpace($State)
    $mustFetchFindings = -not $PSBoundParameters.ContainsKey('Findings')
    if ($mustFetchState -or $mustFetchFindings) {
        if ($PullRequestId -le 0 -or [string]::IsNullOrWhiteSpace($Sha)) {
            throw 'Test-PrClearanceQuiet requires -State and -Findings, or -PullRequestId and -Sha.'
        }
        if ($mustFetchState) {
            $review = Get-ReviewState -PullRequestId $PullRequestId -Sha $Sha -WorkspaceRoot $WorkspaceRoot
            $State = [string]$review.state
        }
        if ($mustFetchFindings) {
            $Findings = Get-ReviewFindings -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot
        }
    }

    $items = @($Findings | Where-Object { $null -ne $_ })
    return (($State -eq 'finished_this_sha') -and ($items.Count -eq 0))
}

function Wait-ReviewFinished {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [string]$Sha,

        [int]$TimeoutSeconds = 0,
        [int]$PollMilliseconds = 5000,
        [string]$WorkspaceRoot = ''
    )

    if ($TimeoutSeconds -le 0) {
        $TimeoutSeconds = $script:PrClearanceWaitTimeoutSeconds
    }

    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $last = $null
    do {
        $last = Get-ReviewState -PullRequestId $PullRequestId -Sha $Sha -WorkspaceRoot $WorkspaceRoot
        $state = [string]$last.state
        if ($state -eq 'finished_this_sha' -or $state -eq 'finished_stale_sha') {
            return [pscustomobject]@{
                state       = $state
                timedOut    = $false
                tipSha      = $last.tipSha
                reviewedSha = $(if ($last.PSObject.Properties.Name -contains 'reviewedSha') { $last.reviewedSha } else { $null })
                startedUtc  = $(if ($last.PSObject.Properties.Name -contains 'startedUtc') { $last.startedUtc } else { $null })
                finishedUtc = $(if ($last.PSObject.Properties.Name -contains 'finishedUtc') { $last.finishedUtc } else { $null })
            }
        }
        if ([datetime]::UtcNow -ge $deadline) { break }
        if ($PollMilliseconds -le 0) {
            $PollMilliseconds = 5000
        }
        Start-Sleep -Milliseconds $PollMilliseconds
    } while ([datetime]::UtcNow -lt $deadline)

    return [pscustomobject]@{
        state       = $(if ($last) { [string]$last.state } else { 'none' })
        timedOut    = $true
        tipSha      = $(if ($last) { $last.tipSha } else { $Sha })
        reviewedSha = $null
        startedUtc  = $null
        finishedUtc = $null
    }
}

function Get-PrClearanceNextAction {
    param(
        [string]$State = '',
        [switch]$Quiet,
        [int]$ActBatchCount = 0,
        [switch]$LastWaitTimedOut,
        [switch]$AfterPush,
        [switch]$FirstInteraction,
        [int]$FindingCount = -1,
        [int]$PullRequestId = 0,
        [string]$Sha = '',
        [string]$WorkspaceRoot = ''
    )

    $quietValue = [bool]$Quiet
    if ($LastWaitTimedOut) {
        return [pscustomobject]@{ action = 'finalize_timeout' }
    }
    if ($AfterPush) {
        return [pscustomobject]@{ action = 'request_and_wait' }
    }

    if ([string]::IsNullOrWhiteSpace($State)) {
        if ($PullRequestId -le 0 -or [string]::IsNullOrWhiteSpace($Sha)) {
            throw 'Get-PrClearanceNextAction requires -State or -PullRequestId and -Sha.'
        }
        $review = Get-ReviewState -PullRequestId $PullRequestId -Sha $Sha -WorkspaceRoot $WorkspaceRoot
        $State = [string]$review.state
        if ($FindingCount -lt 0) {
            $fetchedFindings = Get-ReviewFindings -PullRequestId $PullRequestId -WorkspaceRoot $WorkspaceRoot
            $FindingCount = @($fetchedFindings).Count
            if ($State -eq 'finished_this_sha') {
                $quietValue = Test-PrClearanceQuiet -State $State -Findings $fetchedFindings
            }
            else {
                $quietValue = $false
            }
        }
        elseif ($State -eq 'finished_this_sha') {
            $quietValue = ($FindingCount -eq 0)
        }
        else {
            $quietValue = $false
        }
    }

    if ($FindingCount -ge 0 -and $FirstInteraction) {
        if ($FindingCount -gt 0) {
            if ($ActBatchCount -ge $script:PrClearanceMaxActBatches) {
                return [pscustomobject]@{ action = 'finalize_max_batches' }
            }
            return [pscustomobject]@{ action = 'act' }
        }
        switch ($State) {
            'in_flight' { return [pscustomobject]@{ action = 'wait' } }
            'finished_this_sha' { return [pscustomobject]@{ action = 'finalize_quiet' } }
            'none' { return [pscustomobject]@{ action = 'request_and_wait' } }
            'finished_stale_sha' { return [pscustomobject]@{ action = 'request_and_wait' } }
            default { throw "Unknown review state: $State" }
        }
    }

    if ($FindingCount -ge 0) {
        if ($FindingCount -eq 0) {
            return [pscustomobject]@{ action = 'finalize_quiet' }
        }
        if ($ActBatchCount -ge $script:PrClearanceMaxActBatches) {
            return [pscustomobject]@{ action = 'finalize_max_batches' }
        }
        return [pscustomobject]@{ action = 'act' }
    }

    switch ($State) {
        'none' { return [pscustomobject]@{ action = 'request_and_wait' } }
        'in_flight' { return [pscustomobject]@{ action = 'wait' } }
        'finished_stale_sha' { return [pscustomobject]@{ action = 'request_and_wait' } }
        'finished_this_sha' {
            if ($quietValue) { return [pscustomobject]@{ action = 'finalize_quiet' } }
            if ($ActBatchCount -ge $script:PrClearanceMaxActBatches) {
                return [pscustomobject]@{ action = 'finalize_max_batches' }
            }
            return [pscustomobject]@{ action = 'act' }
        }
        default { throw "Unknown review state: $State" }
    }
}

function Get-PrClearanceNormalizedPath {
    param($Path)
    $p = ([string]$Path).Trim().Replace('\', '/')
    while ($p.StartsWith('/')) {
        $p = $p.Substring(1)
    }
    return $p.ToLowerInvariant()
}

function Group-PrClearancePassFindingsByPath {
    param([Parameter(Mandatory = $true)]$Findings)
    $map = @{}
    foreach ($f in @($Findings)) {
        $key = Get-PrClearanceNormalizedPath -Path $f.Path
        if ([string]::IsNullOrWhiteSpace($key)) { continue }
        if (-not $map.ContainsKey($key)) {
            $map[$key] = [pscustomobject]@{ Path = $key; Issues = New-Object 'System.Collections.Generic.List[object]' }
        }
        [void]$map[$key].Issues.Add($f)
    }
    return @($map.Values | ForEach-Object {
        [pscustomobject]@{ Path = $_.Path; Issues = $_.Issues.ToArray() }
    })
}

function Invoke-PrClearanceSpecialist {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Issues,
        [Parameter(Mandatory = $true)][int]$PullRequestId,
        [string]$WorkspaceRoot = '',
        $PreparedResults = $null
    )
    $want = Get-PrClearanceNormalizedPath -Path $Path
    foreach ($i in @($Issues)) {
        if ((Get-PrClearanceNormalizedPath -Path $i.Path) -ne $want) {
            throw "Specialist issues must share Path '$Path'."
        }
    }
    $root = $WorkspaceRoot
    if ([string]::IsNullOrWhiteSpace($root)) {
        $root = [IO.Path]::GetFullPath((Get-Location).Path)
    }
    $null = Resolve-PrClearanceFindingPath -RepoRoot $root -Path $Path
    $op = Invoke-PrClearanceOperation -Port specialist -Operation 'Invoke-Specialist'
    return & $op $Path @($Issues) $PullRequestId $root $PreparedResults
}

function Get-PrClearanceDismissedReply {
    param(
        [Parameter(Mandatory = $true)]$Finding,
        [Parameter(Mandatory = $true)][string]$Reason
    )
    $comment = if ($Finding.PSObject.Properties.Name -contains 'Comment') { [string]$Finding.Comment } else { '' }
    $issue = $comment
    if ($comment -match '(?s)\*\*Suggestion:\*\*\s*(.+)$') {
        $issue = [string]$Matches[1]
    }
    $issue = (($issue -split '[\r\n]+')[0] -replace '<[^>]+>', '' -replace '\s*\[[^\]]+\]\s*$', '').Trim()
    if ([string]::IsNullOrWhiteSpace($issue)) {
        $issue = 'The review flagged this code.'
    }
    return "**Issue:** $issue`n**WontFix Reason:** $($Reason.Trim())"
}

function Get-PrClearanceSpecialistReply {
    param([Parameter(Mandatory = $true)]$Result)
    $issue = ''
    $change = ''
    $justification = ''
    if ($Result.PSObject.Properties.Name -contains 'report' -and $null -ne $Result.report) {
        if ($Result.report.PSObject.Properties.Name -contains 'issue') { $issue = [string]$Result.report.issue }
        if ($Result.report.PSObject.Properties.Name -contains 'change') { $change = [string]$Result.report.change }
        if ($Result.report.PSObject.Properties.Name -contains 'justification') { $justification = [string]$Result.report.justification }
    }
    if ([string]::IsNullOrWhiteSpace($issue)) {
        $issue = 'The review flagged this code.'
    }
    $reason = if ($Result.PSObject.Properties.Name -contains 'reason') { [string]$Result.reason } else { '' }
    $disposition = if ($Result.PSObject.Properties.Name -contains 'disposition') { [string]$Result.disposition } else { 'fixed' }
    if ($disposition -eq 'dismissed') {
        $wontFixReason = $reason
        if ([string]::IsNullOrWhiteSpace($wontFixReason)) { $wontFixReason = $justification }
        if ([string]::IsNullOrWhiteSpace($wontFixReason)) { $wontFixReason = $change }
        return "**Issue:** $issue`n**WontFix Reason:** $wontFixReason"
    }
    if ([string]::IsNullOrWhiteSpace($change)) { $change = $reason }
    $fix = $change.Trim()
    if (-not [string]::IsNullOrWhiteSpace($justification)) {
        if ($fix.Length -gt 0 -and $fix[-1] -notin @('.', '!', '?')) { $fix += '.' }
        $fix += " $($justification.Trim())"
    }
    return "**Issue:** $issue`n**Fix:** $($fix.Trim())"
}

function Get-PrClearanceFindingFingerprint {
    param(
        [Parameter(Mandatory = $true)]
        $Finding
    )
    $path = Get-PrClearanceNormalizedPath -Path $Finding.Path
    $comment = [string]$Finding.Comment
    $suggestion = ''
    if ($comment -match '(?s)\*\*Suggestion:\*\*\s*(.+)$') {
        $suggestion = [string]$Matches[1]
    }
    $first = (($suggestion -split '[\r\n]+')[0])
    if ([string]::IsNullOrWhiteSpace($first)) {
        $flat = ($comment -replace '\s+', ' ').Trim()
        if ($flat.Length -gt 200) {
            $flat = $flat.Substring(0, 200)
        }
        $first = $flat
    }
    $norm = ($first -replace '\s+', ' ').Trim().ToLowerInvariant()
    return "$path|$norm"
}

function Get-PrClearanceActRegisterPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [int]$PullRequestId
    )
    $root = [IO.Path]::GetFullPath($RepoRoot)
    return (Join-Path $root (Join-Path '.tmp' (Join-Path 'pr-clearance' ("act-register-$PullRequestId.json"))))
}

function New-PrClearanceActRegister {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId
    )
    return [pscustomobject]@{
        schemaVersion          = 1
        pullRequestId          = $PullRequestId
        fingerprints           = @()
        pathBatches            = @()
        changedPaths           = @()
        changedPathsFrozen     = $false
        clearancePaths         = @()
        clearancePathsFrozen   = $false
        joinedPaths            = @()
        hunkBatches            = @()
    }
}

function Read-PrClearanceActRegister {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [int]$PullRequestId
    )
    $path = Get-PrClearanceActRegisterPath -RepoRoot $RepoRoot -PullRequestId $PullRequestId
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return (New-PrClearanceActRegister -PullRequestId $PullRequestId)
    }
    $obj = (Get-Content -LiteralPath $path -Raw -Encoding UTF8) | ConvertFrom-Json
    $fps = @()
    if ($obj.PSObject.Properties.Name -contains 'fingerprints' -and $null -ne $obj.fingerprints) {
        $fps = @($obj.fingerprints)
    }
    $batches = @()
    if ($obj.PSObject.Properties.Name -contains 'pathBatches' -and $null -ne $obj.pathBatches) {
        $batches = @($obj.pathBatches)
    }
    $id = $PullRequestId
    if ($obj.PSObject.Properties.Name -contains 'pullRequestId' -and $null -ne $obj.pullRequestId) {
        $id = [int]$obj.pullRequestId
    }
    $changed = @()
    if ($obj.PSObject.Properties.Name -contains 'changedPaths' -and $null -ne $obj.changedPaths) {
        $changed = @($obj.changedPaths)
    }
    $clearance = @()
    if ($obj.PSObject.Properties.Name -contains 'clearancePaths' -and $null -ne $obj.clearancePaths) {
        $clearance = @($obj.clearancePaths)
    }
    $changedFrozen = $false
    if ($obj.PSObject.Properties.Name -contains 'changedPathsFrozen') {
        $changedFrozen = [bool]$obj.changedPathsFrozen
    }
    $clearanceFrozen = $false
    if ($obj.PSObject.Properties.Name -contains 'clearancePathsFrozen') {
        $clearanceFrozen = [bool]$obj.clearancePathsFrozen
    }
    $joined = @()
    if ($obj.PSObject.Properties.Name -contains 'joinedPaths' -and $null -ne $obj.joinedPaths) {
        $joined = @($obj.joinedPaths)
    }
    $hunks = @()
    if ($obj.PSObject.Properties.Name -contains 'hunkBatches' -and $null -ne $obj.hunkBatches) {
        $hunks = @($obj.hunkBatches)
    }
    return [pscustomobject]@{
        schemaVersion        = 1
        pullRequestId        = $id
        fingerprints         = $fps
        pathBatches          = $batches
        changedPaths         = $changed
        changedPathsFrozen   = $changedFrozen
        clearancePaths       = $clearance
        clearancePathsFrozen = $clearanceFrozen
        joinedPaths          = $joined
        hunkBatches          = $hunks
    }
}

function Save-PrClearanceActRegister {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        $Register
    )
    $path = Get-PrClearanceActRegisterPath -RepoRoot $RepoRoot -PullRequestId ([int]$Register.pullRequestId)
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    $tmp = "$path.tmp"
    ($Register | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-PrClearanceUniqueNormalizedPaths {
    param([string[]]$Paths = @())
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    $ordered = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in @($Paths)) {
        $n = Get-PrClearanceNormalizedPath -Path $p
        if ([string]::IsNullOrWhiteSpace($n)) {
            continue
        }
        if ($seen.Add($n)) {
            [void]$ordered.Add($n)
        }
    }
    return $ordered.ToArray()
}

function Set-PrClearanceChangedPaths {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [string[]]$ChangedPaths = @()
    )
    if ([bool]$Register.changedPathsFrozen) {
        return $Register
    }
    $unique = @(Get-PrClearanceUniqueNormalizedPaths -Paths $ChangedPaths)
    if ($unique.Count -eq 0) {
        return $Register
    }
    $Register.changedPaths = $unique
    $Register.changedPathsFrozen = $true
    return $Register
}

function Set-PrClearanceFindingPathSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        $Findings,

        [string[]]$ChangedPaths
    )
    if ([bool]$Register.clearancePathsFrozen) {
        return $Register
    }
    $list = @($Findings)
    if ($list.Count -eq 0) {
        return $Register
    }
    $scope = $null
    if ($PSBoundParameters.ContainsKey('ChangedPaths') -and $null -ne $ChangedPaths) {
        $scope = @($ChangedPaths)
    }
    elseif ([bool]$Register.changedPathsFrozen) {
        $scope = @($Register.changedPaths)
    }
    $kept = New-Object 'System.Collections.Generic.List[string]'
    foreach ($f in $list) {
        $path = [string]$f.Path
        if ($null -ne $scope) {
            if (-not (Test-PrClearanceFindingInPrScope -Path $path -ChangedPaths $scope)) {
                continue
            }
        }
        $n = Get-PrClearanceNormalizedPath -Path $path
        if (-not [string]::IsNullOrWhiteSpace($n)) {
            [void]$kept.Add($n)
        }
    }
    $Register.clearancePaths = @(Get-PrClearanceUniqueNormalizedPaths -Paths @($kept.ToArray()))
    if (@($Register.clearancePaths).Count -eq 0) {
        return $Register
    }
    $Register.clearancePathsFrozen = $true
    return $Register
}

function Test-PrClearanceFindingInClearanceSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    if (-not [bool]$Register.clearancePathsFrozen) {
        return $true
    }
    $norm = Get-PrClearanceNormalizedPath -Path $Path
    foreach ($p in @($Register.clearancePaths)) {
        if ((Get-PrClearanceNormalizedPath -Path $p) -eq $norm) {
            return $true
        }
    }
    return $false
}

function Get-PrClearanceHardStopReply {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('max_batches', 'timeout')]
        [string]$Reason
    )
    if ($Reason -eq 'timeout') {
        return "**Issue:** still open when the review wait timed out.`n**WontFix Reason:** closed without a fix because the wait limit was reached."
    }
    return "**Issue:** still open when clearance hit the Act-batch limit.`n**WontFix Reason:** closed without a fix because the batch cap was reached."
}

function Get-PrClearanceReviewRequestClearNotes {
    param($Result)

    $notes = New-Object 'System.Collections.Generic.List[string]'
    $count = 0
    if ($null -ne $Result -and ($Result.PSObject.Properties.Name -contains 'ResolvedCount') -and $null -ne $Result.ResolvedCount) {
        $count = [int]$Result.ResolvedCount
    }
    if ($count -gt 0) {
        [void]$notes.Add("Cleared $count leftover review-request thread(s).")
    }
    $warnings = @()
    if ($null -ne $Result -and ($Result.PSObject.Properties.Name -contains 'Warnings') -and $null -ne $Result.Warnings) {
        $warnings = @($Result.Warnings)
    }
    foreach ($w in $warnings) {
        $text = [string]$w
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            [void]$notes.Add($text)
        }
    }
    return @($notes)
}

function Get-PrClearanceRegisterFingerprintEntry {
    param($Register, [string]$Key)
    foreach ($e in @($Register.fingerprints)) {
        if ([string]$e.key -eq $Key) {
            return $e
        }
    }
    return $null
}

function Add-PrClearanceActRegisterFix {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [Parameter(Mandatory = $true)]
        $Finding,

        [string]$Sha = ''
    )
    $key = Get-PrClearanceFindingFingerprint -Finding $Finding
    $entry = Get-PrClearanceRegisterFingerprintEntry -Register $Register -Key $key
    if ($null -eq $entry) {
        $entry = [pscustomobject]@{
            key                    = $key
            hits                   = 1
            lastSha                = $Sha
            lastDisposition        = 'fixed'
            dismissedBecauseRepeat = $false
        }
        $fps = [System.Collections.Generic.List[object]]@($Register.fingerprints)
        $fps.Add($entry)
        while ($fps.Count -gt $script:PrClearanceFingerprintCap) {
            $fps.RemoveAt(0)
        }
        $Register.fingerprints = $fps.ToArray()
    }
    else {
        $entry.hits = [int]$entry.hits + 1
        $entry.lastSha = $Sha
        $entry.lastDisposition = 'fixed'
    }
    return $Register
}

function Add-PrClearanceActRegisterPathBatch {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [string[]]$Paths = @(),

        [int]$Batch = 0
    )
    $norm = @(
        $Paths |
            ForEach-Object { Get-PrClearanceNormalizedPath -Path $_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $Register.pathBatches = @($Register.pathBatches) + [pscustomobject]@{
        batch = $Batch
        paths = $norm
    }
    if (@($Register.pathBatches).Count -gt $script:PrClearanceMaxActBatches) {
        $Register.pathBatches = @($Register.pathBatches | Select-Object -Last $script:PrClearanceMaxActBatches)
    }
    return $Register
}

function Get-PrClearanceFindingLineSpan {
    param(
        [Parameter(Mandatory = $true)]
        $Finding
    )
    $raw = ''
    if ($Finding.PSObject.Properties.Name -contains 'Line') {
        $raw = [string]$Finding.Line
    }
    $raw = $raw.Trim()
    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $null
    }
    if ($raw -match '^(\d+):(\d+)$') {
        $start = [int]$Matches[1]
        $end = [int]$Matches[2]
        if ($end -lt $start) {
            $tmp = $start
            $start = $end
            $end = $tmp
        }
        return [pscustomobject]@{ start = $start; end = $end }
    }
    if ($raw -match '^(\d+)$') {
        $n = [int]$Matches[1]
        return [pscustomobject]@{ start = $n; end = $n }
    }
    return $null
}

function Test-PrClearanceLineOverlapsHunks {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Start,

        [Parameter(Mandatory = $true)]
        [int]$End,

        $Hunks
    )
    foreach ($h in @($Hunks)) {
        $hs = [int]$h.start
        $he = [int]$h.end
        if ($Start -le $he -and $End -ge $hs) {
            return $true
        }
    }
    return $false
}

function Test-PrClearanceFindingInJoinedPaths {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $norm = Get-PrClearanceNormalizedPath -Path $Path
    foreach ($p in @($Register.joinedPaths)) {
        if ((Get-PrClearanceNormalizedPath -Path $p) -eq $norm) {
            return $true
        }
    }
    return $false
}

function Get-PrClearanceRegisterHunkRanges {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $norm = Get-PrClearanceNormalizedPath -Path $Path
    $ranges = New-Object 'System.Collections.Generic.List[object]'
    foreach ($batch in @($Register.hunkBatches)) {
        foreach ($hunk in @($batch.hunks)) {
            if ((Get-PrClearanceNormalizedPath -Path ([string]$hunk.path)) -ne $norm) {
                continue
            }
            foreach ($r in @($hunk.ranges)) {
                [void]$ranges.Add([pscustomobject]@{
                        start = [int]$r.start
                        end   = [int]$r.end
                    })
            }
        }
    }
    return $ranges.ToArray()
}

function Add-PrClearanceActRegisterJoin {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [string[]]$Paths = @(),

        $Hunks,

        [string]$Sha = '',

        [int]$Batch = 0
    )
    $toJoin = New-Object 'System.Collections.Generic.List[string]'
    foreach ($p in @($Paths)) {
        $n = Get-PrClearanceNormalizedPath -Path $p
        if ([string]::IsNullOrWhiteSpace($n)) {
            continue
        }
        if (Test-PrClearanceFindingInClearanceSnapshot -Register $Register -Path $n) {
            continue
        }
        if (-not (Test-PrClearanceFindingInJoinedPaths -Register $Register -Path $n)) {
            [void]$toJoin.Add($n)
        }
    }
    if ($toJoin.Count -gt 0) {
        $Register.joinedPaths = @(Get-PrClearanceUniqueNormalizedPaths -Paths (@($Register.joinedPaths) + @($toJoin.ToArray())))
    }

    $normHunks = New-Object 'System.Collections.Generic.List[object]'
    foreach ($h in @($Hunks)) {
        $path = Get-PrClearanceNormalizedPath -Path ([string]$h.path)
        if ([string]::IsNullOrWhiteSpace($path)) {
            continue
        }
        if (Test-PrClearanceFindingInClearanceSnapshot -Register $Register -Path $path) {
            continue
        }
        $ranges = New-Object 'System.Collections.Generic.List[object]'
        foreach ($r in @($h.ranges)) {
            [void]$ranges.Add([pscustomobject]@{
                    start = [int]$r.start
                    end   = [int]$r.end
                })
        }
        [void]$normHunks.Add([pscustomobject]@{
                path   = $path
                ranges = @($ranges.ToArray())
            })
    }
    $Register.hunkBatches = @($Register.hunkBatches) + [pscustomobject]@{
        batch = $Batch
        sha   = $Sha
        hunks = @($normHunks.ToArray())
    }
    if (@($Register.hunkBatches).Count -gt $script:PrClearanceMaxActBatches) {
        $Register.hunkBatches = @($Register.hunkBatches | Select-Object -Last $script:PrClearanceMaxActBatches)
    }
    return $Register
}

function Test-PrClearanceFingerprintExhausted {
    param($Register, $Finding)
    $key = Get-PrClearanceFindingFingerprint -Finding $Finding
    $entry = Get-PrClearanceRegisterFingerprintEntry -Register $Register -Key $key
    if ($null -eq $entry) {
        return $false
    }
    return ([int]$entry.hits -ge $script:PrClearanceFingerprintFixLimit)
}

function Test-PrClearancePathExhausted {
    param($Register, [string]$Path)
    $norm = Get-PrClearanceNormalizedPath -Path $Path
    $batches = @($Register.pathBatches)
    if ($batches.Count -lt $script:PrClearancePathConsecutiveFixLimit) {
        return $false
    }
    $tail = @($batches | Select-Object -Last $script:PrClearancePathConsecutiveFixLimit)
    foreach ($b in $tail) {
        $hit = $false
        foreach ($p in @($b.paths)) {
            if ((Get-PrClearanceNormalizedPath -Path $p) -eq $norm) {
                $hit = $true
                break
            }
        }
        if (-not $hit) {
            return $false
        }
    }
    return $true
}

function Get-PrClearancePathAmendCount {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $norm = Get-PrClearanceNormalizedPath -Path $Path
    $n = 0
    foreach ($b in @($Register.pathBatches)) {
        foreach ($p in @($b.paths)) {
            if ((Get-PrClearanceNormalizedPath -Path $p) -eq $norm) {
                $n++
                break
            }
        }
    }
    return $n
}

function Test-PrClearancePathAmendExhausted {
    param($Register, [string]$Path)
    return ((Get-PrClearancePathAmendCount -Register $Register -Path $Path) -ge $script:PrClearancePathAmendLimit)
}

function Test-PrClearanceFindingInPrScope {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [string[]]$ChangedPaths
    )
    if (-not $PSBoundParameters.ContainsKey('ChangedPaths')) {
        return $true
    }
    if ($null -eq $ChangedPaths) {
        return $true
    }
    $norm = Get-PrClearanceNormalizedPath -Path $Path
    foreach ($p in @($ChangedPaths)) {
        if ((Get-PrClearanceNormalizedPath -Path $p) -eq $norm) {
            return $true
        }
    }
    return $false
}

function Get-PrClearancePolicyOverride {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        [Parameter(Mandatory = $true)]
        $Finding,

        [string[]]$ChangedPaths
    )
    $path = [string]$Finding.Path
    if ([bool]$Register.clearancePathsFrozen) {
        if (-not (Test-PrClearanceFindingInClearanceSnapshot -Register $Register -Path $path)) {
            if (Test-PrClearanceFindingInJoinedPaths -Register $Register -Path $path) {
                $span = Get-PrClearanceFindingLineSpan -Finding $Finding
                if ($null -ne $span) {
                    $ranges = @(Get-PrClearanceRegisterHunkRanges -Register $Register -Path $path)
                    if (-not (Test-PrClearanceLineOverlapsHunks -Start $span.start -End $span.end -Hunks $ranges)) {
                        return 'dismiss'
                    }
                }
            }
            else {
                return 'dismiss'
            }
        }
    }
    elseif ($PSBoundParameters.ContainsKey('ChangedPaths') -and $null -ne $ChangedPaths) {
        if (-not (Test-PrClearanceFindingInPrScope -Path $path -ChangedPaths $ChangedPaths)) {
            return 'dismiss'
        }
    }
    if (Test-PrClearanceFingerprintExhausted -Register $Register -Finding $Finding) {
        $key = Get-PrClearanceFindingFingerprint -Finding $Finding
        $entry = Get-PrClearanceRegisterFingerprintEntry -Register $Register -Key $key
        if ($null -ne $entry) {
            if ($entry.PSObject.Properties.Name -contains 'dismissedBecauseRepeat') {
                $entry.dismissedBecauseRepeat = $true
            }
            else {
                $entry | Add-Member -NotePropertyName dismissedBecauseRepeat -NotePropertyValue $true -Force
            }
        }
        return 'dismiss'
    }
    if (Test-PrClearancePathExhausted -Register $Register -Path ([string]$Finding.Path)) {
        return 'dismiss'
    }
    if (Test-PrClearancePathAmendExhausted -Register $Register -Path ([string]$Finding.Path)) {
        return 'dismiss'
    }
    return $null
}

function Test-PrClearanceAllFindingsExhausted {
    param(
        [Parameter(Mandatory = $true)]
        $Register,

        $Findings,

        [string[]]$ChangedPaths
    )
    $list = @($Findings)
    if ($list.Count -eq 0) {
        return $false
    }
    $overrideArgs = @{ Register = $Register }
    if ($PSBoundParameters.ContainsKey('ChangedPaths')) {
        $overrideArgs.ChangedPaths = $ChangedPaths
    }
    foreach ($f in $list) {
        if ($null -eq (Get-PrClearancePolicyOverride @overrideArgs -Finding $f)) {
            return $false
        }
    }
    return $true
}

function Test-PrClearanceShouldKickAfterAct {
    param([switch]$CodeChanged)
    return [bool]$CodeChanged
}

function Get-PrClearanceRepeatedReport {
    param(
        [Parameter(Mandatory = $true)]
        $Register
    )
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in @($Register.fingerprints)) {
        if ([int]$e.hits -lt $script:PrClearanceFingerprintFixLimit) {
            continue
        }
        $flag = $true
        if ($e.PSObject.Properties.Name -contains 'dismissedBecauseRepeat') {
            $flag = [bool]$e.dismissedBecauseRepeat -or ([int]$e.hits -ge $script:PrClearanceFingerprintFixLimit)
        }
        [void]$out.Add([pscustomobject]@{
                fingerprint            = [string]$e.key
                hits                   = [int]$e.hits
                dismissedBecauseRepeat = $flag
            })
    }
    return $out.ToArray()
}

function Resolve-PrClearanceRepoRoot {
    param(
        [Parameter(Mandatory = $true)]
        [int]$PullRequestId,

        [Parameter(Mandatory = $true)]
        [string[]]$WorkspaceRoots
    )

    Initialize-PrClearanceDefaultTools
    if (-not $script:PrClearanceTools.ContainsKey('ado-core')) {
        throw "Tool 'ado-core' is not registered."
    }
    $ops = $script:PrClearanceTools['ado-core'].Operations
    if (-not $ops.ContainsKey('TryGetPullRequest')) {
        throw "Tool 'ado-core' does not implement TryGetPullRequest."
    }
    $probe = $ops['TryGetPullRequest']

    $hits = New-Object 'System.Collections.Generic.List[object]'
    foreach ($root in @($WorkspaceRoots)) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $hit = & $probe $root $PullRequestId
        if ($hit) { [void]$hits.Add($hit) }
    }

    if ($hits.Count -eq 0) {
        return [pscustomobject]@{
            Status   = 'none'
            RepoRoot = $null
            Roots    = @()
            Hits     = @()
        }
    }
    if ($hits.Count -eq 1) {
        return [pscustomobject]@{
            Status   = 'one'
            RepoRoot = [string]$hits[0].RepoRoot
            Roots    = @([string]$hits[0].RepoRoot)
            Hits     = @($hits[0])
        }
    }
    return [pscustomobject]@{
        Status   = 'several'
        RepoRoot = $null
        Roots    = @($hits | ForEach-Object { [string]$_.RepoRoot })
        Hits     = @($hits.ToArray())
    }
}

function Get-PrClearanceCurrentBranch {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $result = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
    if (-not $result.ok) {
        throw $result.output
    }
    return ([string]$result.output).Trim()
}

function Test-PrClearanceWorkingTreeClean {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $result = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('status', '--porcelain')
    if (-not $result.ok) {
        throw $result.output
    }
    return [string]::IsNullOrWhiteSpace([string]$result.output)
}

function Get-PrClearancePrChangedPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$TargetRef
    )
    $branch = ConvertTo-PrClearanceBranchName -SourceRefName $TargetRef
    if ([string]::IsNullOrWhiteSpace($branch)) {
        throw 'Get-PrClearancePrChangedPaths requires the PR target branch.'
    }
    $originRef = 'refs/remotes/origin/' + $branch
    $null = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('fetch', 'origin', $branch, '--')
    $originOk = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('rev-parse', '--verify', $originRef)
    if ($originOk.ok) {
        $result = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('diff', '--name-only', ('origin/' + $branch + '...HEAD'))
        if (-not $result.ok) {
            throw $result.output
        }
    }
    else {
        $result = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('diff', '--name-only', ($branch + '...HEAD'))
        if (-not $result.ok) {
            throw $result.output
        }
    }
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in @(([string]$result.output) -split '[\r\n]+')) {
        $n = Get-PrClearanceNormalizedPath -Path $line
        if (-not [string]::IsNullOrWhiteSpace($n)) {
            [void]$names.Add($n)
        }
    }
    return $names.ToArray()
}

function ConvertTo-PrClearanceBranchName {
    param([string]$SourceRefName)
    $name = [string]$SourceRefName
    if ($name.StartsWith('refs/heads/')) {
        return $name.Substring('refs/heads/'.Length)
    }
    return $name
}
