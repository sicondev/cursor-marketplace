#Requires -Version 5.1
<#
.SYNOPSIS
  Live ADO checks for build timeline and log reads. Needs default credentials to tfs.sicon.co.uk.
.EXAMPLE
  & "$PSScriptRoot\Test-AdoCoreBuildRead.ps1"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'ado-core.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}

function Get-ThrownError {
    param([Parameter(Mandatory = $true)][scriptblock]$Script)
    try {
        & $Script | Out-Null
        return $null
    }
    catch {
        return $_
    }
}

$repoRoot = ''
try {
    $repoRoot = [string](& git -C $scriptDir rev-parse --show-toplevel)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($repoRoot)) {
        throw 'git rev-parse failed'
    }
    $repoRoot = $repoRoot.Trim()

    Assert-True ((Get-AdoCoreLibraryVersion) -eq [version]'0.10.0') 'library version is 0.10.0'
    Assert-True ($null -ne (Get-Command Get-AdoCoreBuildTimeline -ErrorAction SilentlyContinue)) 'Get-AdoCoreBuildTimeline is defined'
    Assert-True ($null -ne (Get-Command Get-AdoCoreBuildLog -ErrorAction SilentlyContinue)) 'Get-AdoCoreBuildLog is defined'
    Assert-True ($null -ne (Get-Command Get-AdoCoreBuildLogs -ErrorAction SilentlyContinue)) 'Get-AdoCoreBuildLogs is defined'

    $base = [string](Get-AdoCoreBuildApiBase -WorkspaceRoot $repoRoot).BuildApiBase
    $listUri = "$base/builds?`$top=20&statusFilter=completed&queryOrder=finishTimeDescending&api-version=7.0"
    $list = Invoke-RestMethod -Uri $listUri -Method Get -UseDefaultCredentials
    $knownResults = @(
        'succeeded', 'succeededWithIssues', 'failed', 'canceled', 'abandoned', 'skipped'
    )

    $fixture = $null
    foreach ($build in @($list.value)) {
        $timeline = Get-AdoCoreBuildTimeline -BuildId ([int]$build.id) -WorkspaceRoot $repoRoot
        foreach ($record in @($timeline.records)) {
            $type = ''
            $name = ''
            $result = ''
            $logId = 0
            if ($record.PSObject.Properties.Name -contains 'type') { $type = [string]$record.type }
            if ($record.PSObject.Properties.Name -contains 'name') { $name = [string]$record.name }
            if ($record.PSObject.Properties.Name -contains 'result' -and $null -ne $record.result) {
                $result = [string]$record.result
            }
            $hasLog = $record.PSObject.Properties.Name -contains 'log' -and $null -ne $record.log -and
                $record.log.PSObject.Properties.Name -contains 'id' -and $null -ne $record.log.id
            if ($hasLog) { $logId = [int]$record.log.id }
            if ($type -eq 'Task' -and -not [string]::IsNullOrWhiteSpace($name) -and
                ($knownResults -contains $result) -and $logId -gt 0) {
                $fixture = [pscustomobject]@{
                    BuildId  = [int]$build.id
                    LogId    = $logId
                    Name     = $name
                    Result   = $result
                    Timeline = $timeline
                }
                break
            }
        }
        if ($null -ne $fixture) { break }
    }

    Assert-True ($null -ne $fixture) 'a completed build has a Task record with type, name, result, and log.id'
    if ($null -ne $fixture) {
        Assert-True ($fixture.Timeline.count -eq @($fixture.Timeline.records).Count) 'timeline count matches records'
        Assert-True ($fixture.Timeline.count -gt 0) 'timeline count is positive'
        $viaBase = Get-AdoCoreBuildTimeline -BuildId $fixture.BuildId -BuildApiBase $base
        Assert-True ($viaBase.count -eq $fixture.Timeline.count) 'BuildApiBase string matches WorkspaceRoot timeline'

        $text = Get-AdoCoreBuildLog -BuildId $fixture.BuildId -LogId $fixture.LogId -WorkspaceRoot $repoRoot
        Assert-True ($text -is [string]) 'task log is a string'
        Assert-True (-not [string]::IsNullOrWhiteSpace($text)) "task log $($fixture.LogId) on build $($fixture.BuildId) is non-empty"

        $emptyLog = Get-AdoCoreBuildLog -BuildId $fixture.BuildId -LogId 2147483646 -WorkspaceRoot $repoRoot
        Assert-True (($emptyLog -is [string]) -and ($emptyLog -eq '')) 'unknown log id on a real build is an empty string, not not-found'

        $logList = Get-AdoCoreBuildLogs -BuildId $fixture.BuildId -WorkspaceRoot $repoRoot
        Assert-True ($logList.count -eq @($logList.logs).Count) 'log list count matches logs'
        $entry = @($logList.logs | Where-Object { [int]$_.id -eq $fixture.LogId }) | Select-Object -First 1
        Assert-True ($null -ne $entry) "log list includes log $($fixture.LogId)"
        if ($null -ne $entry) {
            Assert-True ([int]$entry.lineCount -gt 0) "log $($fixture.LogId) lineCount is positive"
        }

        $fullLines = @($text -split "`r?`n" | Where-Object { $_ -ne '' })
        $head = Get-AdoCoreBuildLog -BuildId $fixture.BuildId -LogId $fixture.LogId -WorkspaceRoot $repoRoot -StartLine 1 -EndLine 2
        $headLines = @($head -split "`r?`n" | Where-Object { $_ -ne '' })
        Assert-True ($headLines.Count -eq [Math]::Min(2, $fullLines.Count)) "StartLine 1 EndLine 2 returned $($headLines.Count) line(s)"
        Assert-True ($headLines.Count -ge 1 -and $headLines[0] -eq $fullLines[0]) 'bounded first line matches full log'

        if ($fullLines.Count -ge 2) {
            $second = Get-AdoCoreBuildLog -BuildId $fixture.BuildId -LogId $fixture.LogId -WorkspaceRoot $repoRoot -StartLine 2 -EndLine 2
            Assert-True ((($second -split "`r?`n") | Where-Object { $_ -ne '' } | Select-Object -First 1) -eq $fullLines[1]) 'StartLine 2 EndLine 2 is the second line (1-based, inclusive)'
        }

        $past = Get-AdoCoreBuildLog -BuildId $fixture.BuildId -LogId $fixture.LogId -WorkspaceRoot $repoRoot -StartLine 2000000000
        Assert-True (($past -is [string]) -and ($past -eq '')) 'StartLine past the end returns an empty string'

        $inverted = Get-ThrownError -Script {
            Get-AdoCoreBuildLog -BuildId $fixture.BuildId -LogId $fixture.LogId -WorkspaceRoot $repoRoot -StartLine 5 -EndLine 2
        }
        Assert-True ($null -ne $inverted) 'EndLine before StartLine throws'
    }

    $missingBuildId = 2147483646
    $missingTimeline = Get-ThrownError -Script {
        Get-AdoCoreBuildTimeline -BuildId $missingBuildId -WorkspaceRoot $repoRoot
    }
    Assert-True ($null -ne $missingTimeline) 'missing build timeline throws under default ErrorPolicy'
    if ($null -ne $missingTimeline) {
        Assert-True ($missingTimeline.FullyQualifiedErrorId -like 'AdoCoreResourceNotFound*') `
            "missing timeline ErrorId was $($missingTimeline.FullyQualifiedErrorId)"
        Assert-True ($missingTimeline.Exception.Message -eq "ADO build $missingBuildId was not found.") `
            "missing timeline message was $($missingTimeline.Exception.Message)"
        Assert-True ([string]$missingTimeline.CategoryInfo.Category -eq 'ObjectNotFound') `
            "missing timeline category was $($missingTimeline.CategoryInfo.Category)"
    }

    $explicitFail = Get-ThrownError -Script {
        Get-AdoCoreBuildTimeline -BuildId $missingBuildId -WorkspaceRoot $repoRoot -ErrorPolicy Fail
    }
    Assert-True ($null -ne $explicitFail -and $explicitFail.Exception.Message -eq "ADO build $missingBuildId was not found.") `
        'ErrorPolicy Fail matches the default not-found error'

    $omittedTimeline = Get-AdoCoreBuildTimeline -BuildId $missingBuildId -WorkspaceRoot $repoRoot -ErrorPolicy Omit
    Assert-True ($null -eq $omittedTimeline) 'ErrorPolicy Omit returns null for a missing build timeline'

    $missingLog = Get-ThrownError -Script {
        Get-AdoCoreBuildLog -BuildId $missingBuildId -LogId 1 -WorkspaceRoot $repoRoot -ErrorPolicy Fail
    }
    Assert-True ($null -ne $missingLog) 'missing build log throws under ErrorPolicy Fail'
    if ($null -ne $missingLog) {
        Assert-True ($missingLog.FullyQualifiedErrorId -like 'AdoCoreResourceNotFound*') `
            "missing log ErrorId was $($missingLog.FullyQualifiedErrorId)"
        Assert-True ($missingLog.Exception.Message -eq "ADO build $missingBuildId log 1 was not found.") `
            "missing log message was $($missingLog.Exception.Message)"
    }

    $omittedLog = Get-AdoCoreBuildLog -BuildId $missingBuildId -LogId 1 -WorkspaceRoot $repoRoot -ErrorPolicy Omit
    Assert-True ($null -eq $omittedLog) 'ErrorPolicy Omit returns null for a missing build log'

    $missingLogList = Get-ThrownError -Script {
        Get-AdoCoreBuildLogs -BuildId $missingBuildId -WorkspaceRoot $repoRoot
    }
    Assert-True ($null -ne $missingLogList -and $missingLogList.FullyQualifiedErrorId -like 'AdoCoreResourceNotFound*') `
        'missing build log list throws AdoCoreResourceNotFound under default ErrorPolicy'
    $omittedLogList = Get-AdoCoreBuildLogs -BuildId $missingBuildId -WorkspaceRoot $repoRoot -ErrorPolicy Omit
    Assert-True ($null -eq $omittedLogList) 'ErrorPolicy Omit returns null for a missing build log list'
}
catch {
    [void]$failures.Add("unhandled: $($_.Exception.Message)")
}

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    Write-Error ('Test-AdoCoreBuildRead FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join $sep))
    exit 1
}

Write-Output 'OK: ado-core build timeline and log'
exit 0
