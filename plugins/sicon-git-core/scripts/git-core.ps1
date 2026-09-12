#Requires -Version 5.1
Set-StrictMode -Version Latest

function Invoke-GitCore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string[]]$GitArgs
    )

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = $null
    $code = -1
    try {
        $output = & git -C $RepoRoot @GitArgs 2>&1
        if ($null -ne $LASTEXITCODE) {
            $code = [int]$LASTEXITCODE
        }
    } catch {
        $output = $_
        $code = 1
    } finally {
        $ErrorActionPreference = $prevEap
    }

    return [pscustomobject]@{
        ok     = ($code -eq 0)
        output = ($output | ForEach-Object { "$_" }) -join "`n"
        code   = $code
    }
}

function Get-GitCoreFailureMessage {
    param($Result)
    $msg = [string]$Result.output
    if ([string]::IsNullOrWhiteSpace($msg)) {
        $msg = "git failed with exit code $($Result.code)"
    }
    return $msg
}

function Get-GitCoreHeadSha {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot
    )

    $result = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('rev-parse', 'HEAD')
    if (-not $result.ok) {
        throw (Get-GitCoreFailureMessage -Result $result)
    }
    return ([string]$result.output).Trim()
}

function New-GitCoreCommit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string[]]$Path
    )

    $addArgs = @('add', '--') + @($Path)
    $add = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs $addArgs
    if (-not $add.ok) {
        throw (Get-GitCoreFailureMessage -Result $add)
    }

    $commitArgs = @('commit', '-m', $Message, '--') + @($Path)
    $commit = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs $commitArgs
    if (-not $commit.ok) {
        throw (Get-GitCoreFailureMessage -Result $commit)
    }
}

function Assert-GitCoreRefName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Kind
    )

    $trimmed = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('-')) {
        throw "$Kind must not start with - and must not be empty: $Name"
    }
    return $trimmed
}

function Push-GitCore {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [string]$Remote = 'origin',

        [string]$Branch = ''
    )

    $Remote = Assert-GitCoreRefName -Name $Remote -Kind 'Remote'
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        $current = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')
        if (-not $current.ok) {
            throw (Get-GitCoreFailureMessage -Result $current)
        }
        $Branch = ([string]$current.output).Trim()
    }
    $Branch = Assert-GitCoreRefName -Name $Branch -Kind 'Branch'

    $push = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('push', '--', $Remote, $Branch)
    if (-not $push.ok) {
        throw (Get-GitCoreFailureMessage -Result $push)
    }
}

function Get-GitCoreDiffHunks {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Range
    )

    $trimmed = $Range.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed.StartsWith('-')) {
        throw "Range must not start with - and must not be empty: $Range"
    }

    $result = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('diff', '-U0', $trimmed)
    if (-not $result.ok) {
        throw (Get-GitCoreFailureMessage -Result $result)
    }

    $byPath = [ordered]@{}
    $currentPath = ''
    foreach ($raw in @(([string]$result.output) -split '[\r\n]+')) {
        $line = [string]$raw
        if ($line -match '^diff --git a/.+ b/(.+)$') {
            $currentPath = [string]$Matches[1]
            if (-not $byPath.Contains($currentPath)) {
                $byPath[$currentPath] = New-Object 'System.Collections.Generic.List[object]'
            }
            continue
        }
        if ($line -match '^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@') {
            if ([string]::IsNullOrWhiteSpace($currentPath)) {
                continue
            }
            $start = [int]$Matches[1]
            $count = 1
            if ($Matches.Count -gt 2 -and -not [string]::IsNullOrWhiteSpace([string]$Matches[2])) {
                $count = [int]$Matches[2]
            }
            if ($count -le 0) {
                continue
            }
            [void]$byPath[$currentPath].Add([pscustomobject]@{
                    start = $start
                    end   = ($start + $count - 1)
                })
        }
    }

    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in $byPath.Keys) {
        [void]$out.Add([pscustomobject]@{
                path   = $path
                ranges = @($byPath[$path].ToArray())
            })
    }
    return $out.ToArray()
}

function Get-GitCoreDiffHunkHeaders {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$FromRef,

        [Parameter(Mandatory = $true)]
        [string]$ToRef,

        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $from = Assert-GitCoreRefName -Name $FromRef -Kind 'FromRef'
    $to = Assert-GitCoreRefName -Name $ToRef -Kind 'ToRef'
    $pathTrim = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($pathTrim) -or $pathTrim.StartsWith('-')) {
        throw "Path must not start with - and must not be empty: $Path"
    }

    $range = "$from..$to"
    $result = Invoke-GitCore -RepoRoot $RepoRoot -GitArgs @('diff', '-U0', $range, '--', ":(literal)$pathTrim")
    if (-not $result.ok) {
        throw (Get-GitCoreFailureMessage -Result $result)
    }

    $headers = New-Object 'System.Collections.Generic.List[object]'
    foreach ($raw in @(([string]$result.output) -split '[\r\n]+')) {
        $line = [string]$raw
        if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
            $oldStart = [int]$Matches[1]
            $oldCount = 1
            if ($Matches.Count -gt 2 -and -not [string]::IsNullOrWhiteSpace([string]$Matches[2])) {
                $oldCount = [int]$Matches[2]
            }
            $newStart = [int]$Matches[3]
            $newCount = 1
            if ($Matches.Count -gt 4 -and -not [string]::IsNullOrWhiteSpace([string]$Matches[4])) {
                $newCount = [int]$Matches[4]
            }
            [void]$headers.Add([pscustomobject]@{
                    oldStart = $oldStart
                    oldCount = $oldCount
                    newStart = $newStart
                    newCount = $newCount
                })
        }
    }
    return $headers.ToArray()
}

function Move-GitCoreLineNumber {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Line,

        $HunkHeaders
    )

    # Map a 1-based line in the FromRef file to ToRef. Returns $null if deleted.
    # Walk hunks in old-file order; delta is the net (new - old) applied to lines after each hunk.
    $delta = 0
    foreach ($h in @($HunkHeaders)) {
        $oldStart = [int]$h.oldStart
        $oldCount = [int]$h.oldCount
        $newCount = [int]$h.newCount

        if ($oldCount -eq 0) {
            # Insert after oldStart: lines 1..oldStart unchanged (plus prior delta); later lines +newCount.
            if ($Line -le $oldStart) {
                return ($Line + $delta)
            }
            $delta += $newCount
            continue
        }

        $oldEndExclusive = $oldStart + $oldCount
        if ($Line -lt $oldStart) {
            return ($Line + $delta)
        }
        if ($Line -lt $oldEndExclusive) {
            return $null
        }
        $delta += ($newCount - $oldCount)
    }
    return ($Line + $delta)
}

# Internal: remap one inclusive old-line range through hunk headers in a single ordered pass
# (same insert/delete/replace semantics as Move-GitCoreLineNumber). Returns coalesced @{start;end}[].
function Convert-GitCoreLineRangeThroughHunks {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Start,

        [Parameter(Mandatory = $true)]
        [int]$End,

        $HunkHeaders
    )

    $segments = New-Object 'System.Collections.Generic.List[object]'
    $delta = 0
    $cursor = $Start

    foreach ($h in @($HunkHeaders)) {
        if ($cursor -gt $End) {
            break
        }

        $oldStart = [int]$h.oldStart
        $oldCount = [int]$h.oldCount
        $newCount = [int]$h.newCount

        if ($oldCount -eq 0) {
            # Insert: lines <= oldStart keep current delta; later lines pick up +newCount.
            $stableEnd = $oldStart
            if ($stableEnd -gt $End) {
                $stableEnd = $End
            }
            if ($cursor -le $stableEnd) {
                [void]$segments.Add([pscustomobject]@{
                        start = ($cursor + $delta)
                        end   = ($stableEnd + $delta)
                    })
                $cursor = $stableEnd + 1
            }
            $delta += $newCount
            continue
        }

        $oldEndExclusive = $oldStart + $oldCount
        $beforeEnd = $oldStart - 1
        if ($beforeEnd -gt $End) {
            $beforeEnd = $End
        }
        if ($cursor -le $beforeEnd) {
            [void]$segments.Add([pscustomobject]@{
                    start = ($cursor + $delta)
                    end   = ($beforeEnd + $delta)
                })
            $cursor = $beforeEnd + 1
        }

        if ($cursor -lt $oldEndExclusive) {
            $cursor = $oldEndExclusive
        }

        $delta += ($newCount - $oldCount)
    }

    if ($cursor -le $End) {
        [void]$segments.Add([pscustomobject]@{
                start = ($cursor + $delta)
                end   = ($End + $delta)
            })
    }

    if ($segments.Count -eq 0) {
        return @()
    }

    $mapped = New-Object 'System.Collections.Generic.List[object]'
    $runStart = [int]$segments[0].start
    $runEnd = [int]$segments[0].end
    for ($i = 1; $i -lt $segments.Count; $i++) {
        $segStart = [int]$segments[$i].start
        $segEnd = [int]$segments[$i].end
        if ($segStart -eq ($runEnd + 1)) {
            $runEnd = $segEnd
            continue
        }
        [void]$mapped.Add([pscustomobject]@{ start = $runStart; end = $runEnd })
        $runStart = $segStart
        $runEnd = $segEnd
    }
    [void]$mapped.Add([pscustomobject]@{ start = $runStart; end = $runEnd })
    return $mapped.ToArray()
}

function Move-GitCoreLineRanges {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RepoRoot,

        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$FromRef,

        [Parameter(Mandatory = $true)]
        [string]$ToRef,

        $Ranges
    )

    $headers = @(Get-GitCoreDiffHunkHeaders -RepoRoot $RepoRoot -FromRef $FromRef -ToRef $ToRef -Path $Path)
    $mapped = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in @($Ranges)) {
        $start = [int]$r.start
        $end = [int]$r.end
        if ($end -lt $start) {
            $tmp = $start
            $start = $end
            $end = $tmp
        }
        foreach ($run in @(Convert-GitCoreLineRangeThroughHunks -Start $start -End $end -HunkHeaders $headers)) {
            [void]$mapped.Add($run)
        }
    }
    return $mapped.ToArray()
}
