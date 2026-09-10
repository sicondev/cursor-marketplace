#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-CodeAntSilentTriageNormalizedPath {
    param($Path)
    $p = ([string]$Path).Trim().Replace('\', '/')
    while ($p.StartsWith('/')) { $p = $p.Substring(1) }
    return $p.ToLowerInvariant()
}

function Assert-CodeAntSilentTriageIssues {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $Issues
    )
    $want = Get-CodeAntSilentTriageNormalizedPath -Path $Path
    foreach ($i in @($Issues)) {
        if ((Get-CodeAntSilentTriageNormalizedPath -Path $i.Path) -ne $want) {
            throw "Specialist issues must share Path '$Path'."
        }
    }
}

function ConvertTo-CodeAntSilentTriageAlready {
    param($Value)
    if ($Value -is [bool]) { return [bool]$Value }
    $s = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($s)) { return $false }
    if ($s -eq 'false' -or $s -eq '0') { return $false }
    if ($s -eq 'true' -or $s -eq '1') { return $true }
    throw "Prepared specialist already value '$s' is not true, false, 1, or 0."
}

function Get-CodeAntSilentTriageResolvedPath {
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

function Test-CodeAntSilentTriagePathUnderRoot {
    param(
        [Parameter(Mandatory = $true)][string]$FullPath,
        [Parameter(Mandatory = $true)][string]$RootFull
    )

    $candidate = $FullPath
    if (-not $candidate.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $asDir = $candidate + [IO.Path]::DirectorySeparatorChar
        return $candidate.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase) -or
            $asDir.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase)
    }
    return $candidate.StartsWith($RootFull, [StringComparison]::OrdinalIgnoreCase)
}

function Assert-CodeAntSilentTriageReportPath {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$WorkspaceRoot = ''
    )
    $raw = $Path.Trim()
    if ([IO.Path]::IsPathRooted($raw) -or $raw -match '^[A-Za-z]:' -or $raw.StartsWith('\\')) {
        throw "Prepared specialist report path is outside the repository: $Path"
    }
    $parts = $raw.TrimStart('/').TrimStart('\').Split([char[]]@('/', '\'))
    if ($parts -contains '..') {
        throw "Prepared specialist report path is outside the repository: $Path"
    }
    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        return
    }
    $relative = [string]::Join([string][IO.Path]::DirectorySeparatorChar, $parts)
    $rootFull = [IO.Path]::GetFullPath($WorkspaceRoot)
    if (-not $rootFull.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [IO.Path]::DirectorySeparatorChar
    }
    $full = [IO.Path]::GetFullPath((Join-Path $WorkspaceRoot $relative))
    if (-not (Test-CodeAntSilentTriagePathUnderRoot -FullPath $full -RootFull $rootFull)) {
        throw "Prepared specialist report path is outside the repository: $Path"
    }

    $cursor = [IO.Path]::GetFullPath($WorkspaceRoot)
    foreach ($part in $parts) {
        $cursor = [IO.Path]::GetFullPath((Join-Path $cursor $part))
        if (-not (Test-Path -LiteralPath $cursor)) { break }
        $resolved = Get-CodeAntSilentTriageResolvedPath -Path $cursor
        if ($resolved -and -not (Test-CodeAntSilentTriagePathUnderRoot -FullPath $resolved -RootFull $rootFull)) {
            throw "Prepared specialist report path is outside the repository: $Path"
        }
    }
    if (Test-Path -LiteralPath $full) {
        $resolvedFull = Get-CodeAntSilentTriageResolvedPath -Path $full
        if ($resolvedFull -and -not (Test-CodeAntSilentTriagePathUnderRoot -FullPath $resolvedFull -RootFull $rootFull)) {
            throw "Prepared specialist report path is outside the repository: $Path"
        }
    }
}

function New-CodeAntSilentTriageResult {
    param(
        [Parameter(Mandatory = $true)]$Issue,
        [Parameter(Mandatory = $true)][ValidateSet('fixed', 'dismissed', 'ask')][string]$Disposition,
        [Parameter(Mandatory = $true)][string]$Reason,
        [bool]$Already = $false,
        $Report = $null,
        $Explain = $null
    )
    return [pscustomobject]@{
        Id           = $Issue.Id
        Number       = $Issue.Number
        disposition  = $Disposition
        reason       = $Reason
        already      = [bool]$Already
        report       = $Report
        explain      = $Explain
    }
}

function Invoke-CodeAntSilentTriage {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Issues,
        [Parameter(Mandatory = $true)][int]$PullRequestId,
        [string]$WorkspaceRoot = '',
        $PreparedResults = $null
    )
    $list = @($Issues)
    Assert-CodeAntSilentTriageIssues -Path $Path -Issues $list
    if ($list.Count -eq 0) {
        return [pscustomobject]@{ results = @(); paths = @() }
    }
    if ($null -eq $PreparedResults) {
        $pending = New-Object 'System.Collections.Generic.List[object]'
        foreach ($issue in $list) {
            [void]$pending.Add((New-CodeAntSilentTriageResult -Issue $issue -Disposition ask -Reason 'Awaiting specialist apply'))
        }
        return [pscustomobject]@{ results = @($pending.ToArray()); paths = @() }
    }
    $prepared = @($PreparedResults)
    $byId = @{}
    foreach ($r in $prepared) {
        $preparedId = [string]$r.Id
        if ($byId.ContainsKey($preparedId)) {
            throw "Prepared specialist results have duplicate Id '$preparedId'."
        }
        $byId[$preparedId] = $r
    }
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($issue in $list) {
        $id = [string]$issue.Id
        if (-not $byId.ContainsKey($id)) {
            throw "Prepared specialist results missing Id '$id'."
        }
        $row = $byId[$id]
        $disposition = [string]$row.disposition
        if ($disposition -notin @('fixed', 'dismissed', 'ask')) {
            throw "Prepared specialist result Id '$id' has invalid disposition '$disposition'."
        }
        $reason = [string]$row.reason
        if ([string]::IsNullOrWhiteSpace($reason)) {
            throw "Prepared specialist result Id '$id' has a blank reason."
        }
        [void]$out.Add([pscustomobject]@{
            Id          = $issue.Id
            Number      = $issue.Number
            disposition = $disposition
            reason      = $reason
            already     = ConvertTo-CodeAntSilentTriageAlready -Value $(if ($row.PSObject.Properties.Name -contains 'already') { $row.already } else { $false })
            report      = $(if ($row.PSObject.Properties.Name -contains 'report') { $row.report } else { $null })
            explain     = $(if ($row.PSObject.Properties.Name -contains 'explain') { $row.explain } else { $null })
        })
    }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    [void]$paths.Add($Path)
    foreach ($r in $out) {
        if ($r.report -and $r.report.PSObject.Properties.Name -contains 'paths') {
            foreach ($p in @($r.report.paths)) {
                $candidate = [string]$p
                if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
                $relative = $candidate.Trim()
                Assert-CodeAntSilentTriageReportPath -Path $relative -WorkspaceRoot $WorkspaceRoot
                [void]$paths.Add($relative)
            }
        }
    }
    return [pscustomobject]@{
        results = @($out.ToArray())
        paths   = @($paths | Select-Object -Unique)
    }
}
