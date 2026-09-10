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
