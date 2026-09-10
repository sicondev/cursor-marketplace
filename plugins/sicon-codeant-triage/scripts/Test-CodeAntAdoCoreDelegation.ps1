#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$adoCoreFunctions = @(
    'New-AdoCorePullRequestThread'
    'Get-AdoCorePullRequestThreads'
    'Add-AdoCorePullRequestThreadComment'
    'Set-AdoCorePullRequestThreadStatus'
)
$originalAdoCoreFunctions = @{}
foreach ($name in $adoCoreFunctions) {
    $existing = Get-Command -Name $name -CommandType Function -ErrorAction SilentlyContinue
    if ($existing) {
        $originalAdoCoreFunctions[$name] = $existing.ScriptBlock
        Remove-Item -Path "Function:global:$name" -ErrorAction SilentlyContinue
    }
}
. (Join-Path $scriptDir 'codeant-triage-lib.ps1')

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

$loaderFunctions = @(
    'Resolve-CodeAntAdoCoreScriptPath'
    'Test-CodeAntAdoCoreExports'
    'Import-CodeAntAdoCore'
)
foreach ($name in $loaderFunctions) {
    Assert-True ($null -ne (Get-Command -Name $name -ErrorAction SilentlyContinue)) "$name is defined"
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codeant-ado-core-' + [guid]::NewGuid().ToString('N'))
try {
    if ($null -ne (Get-Command -Name Resolve-CodeAntAdoCoreScriptPath -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
        $missingThrew = $false
        try {
            Resolve-CodeAntAdoCoreScriptPath -ProfileRoot $tempRoot | Out-Null
        }
        catch {
            $missingThrew = $true
        }
        Assert-True $missingThrew 'missing ado-core installation throws'

        $packScript = Join-Path $tempRoot '.cursor\packs\ado-core\scripts\ado-core.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $packScript) -Force | Out-Null
        $adoCoreStub = @'
function New-AdoCorePullRequestThread {
    param(
        [int]$PullRequestId, [string]$Content, [string]$WorkspaceRoot = '',
        [string]$Collection = '', [string]$Project = '', [string]$Repository = '',
        [string]$ServerUrl = ''
    )
}
function Get-AdoCorePullRequestThreads {
    param(
        [int]$PullRequestId, [string]$WorkspaceRoot = '', [string]$Collection = '',
        [string]$Project = '', [string]$Repository = '', [string]$ServerUrl = ''
    )
    return @()
}
function Add-AdoCorePullRequestThreadComment {
    param(
        [int]$PullRequestId, [int]$ThreadId, [int]$ParentCommentId, [string]$Content,
        [string]$WorkspaceRoot = '', [string]$Collection = '', [string]$Project = '',
        [string]$Repository = '', [string]$ServerUrl = ''
    )
    $global:CodeAntDelegatedComment = [pscustomobject]@{
        PullRequestId = $PullRequestId
        ThreadId = $ThreadId
        ParentCommentId = $ParentCommentId
        Content = $Content
        Collection = $Collection
        Project = $Project
        Repository = $Repository
        ServerUrl = $ServerUrl
    }
    return [pscustomobject]@{ CommentId = 77 }
}
function Set-AdoCorePullRequestThreadStatus {
    param(
        [int]$PullRequestId, [int]$ThreadId, [string]$Status,
        [string]$WorkspaceRoot = '', [string]$Collection = '', [string]$Project = '',
        [string]$Repository = '', [string]$ServerUrl = ''
    )
    $global:CodeAntDelegatedStatus = [pscustomobject]@{
        PullRequestId = $PullRequestId
        ThreadId = $ThreadId
        Status = $Status
    }
}
function Resolve-AdoCoreEndpoints {
    param(
        [string]$WorkspaceRoot = '', [string]$Collection = '', [string]$Project = '',
        [string]$Repository = '', [string]$ServerUrl = ''
    )
    return @{ ApiBase = 'https://tfs.sicon.co.uk/ignored' }
}
function Assert-AdoCoreTrustedApiBase {
    param([Parameter(Mandatory = $true)][string]$ApiBase, [string]$Name = 'ApiBase')
}
'@
        $adoCoreStub | Set-Content -LiteralPath $packScript -Encoding UTF8
        Assert-Equal $packScript (Resolve-CodeAntAdoCoreScriptPath -ProfileRoot $tempRoot) 'user-pack ado-core is the fallback'

        $pluginScript = Join-Path $tempRoot '.cursor\plugins\sicon-ado-core\scripts\ado-core.ps1'
        New-Item -ItemType Directory -Path (Split-Path -Parent $pluginScript) -Force | Out-Null
        @'
function New-AdoCorePullRequestThread { }
function Get-AdoCorePullRequestThreads { }
function Add-AdoCorePullRequestThreadComment { }
function Set-AdoCorePullRequestThreadStatus { }
'@ | Set-Content -LiteralPath $pluginScript -Encoding UTF8
        Assert-Equal $pluginScript (Resolve-CodeAntAdoCoreScriptPath -ProfileRoot $tempRoot) 'marketplace ado-core is preferred'
    }

    $global:CodeAntDelegatedComment = $null
    $global:CodeAntDelegatedStatus = $null
    if ($null -ne (Get-Command -Name Import-CodeAntAdoCore -ErrorAction SilentlyContinue)) {
        Import-CodeAntAdoCore -ProfileRoot $tempRoot | Out-Null
    }

    $addCommand = Get-Command -Name Add-AdoCorePullRequestThreadComment -ErrorAction SilentlyContinue
    $compatibleApi = $null -ne $addCommand -and $addCommand.Parameters.ContainsKey('Content')
    Assert-True $compatibleApi 'incompatible marketplace API falls back to the compatible user pack'
    if ($null -ne (Get-Command -Name Test-CodeAntAdoCoreExports -ErrorAction SilentlyContinue)) {
        Assert-True (Test-CodeAntAdoCoreExports) 'ado-core export check accepts the complete API'
    }

    $postScript = Join-Path $scriptDir 'Post-CodeAntPrThreadReply.ps1'
    $postRaw = Get-Content -LiteralPath $postScript -Raw
    if (
        $compatibleApi -and
        $null -ne (Get-Command -Name Import-CodeAntAdoCore -ErrorAction SilentlyContinue) -and
        $postRaw -match 'Add-AdoCorePullRequestThreadComment'
    ) {
        $output = @(. $postScript -PullRequestId 12 -ThreadId 34 -ParentCommentId 5 `
                -Reply 'Issue`nFix' -Resolve -Collection 'Collection' -Project 'Project' `
                -Repository 'Repo' -ServerUrl 'https://tfs.sicon.co.uk:8443')
        Assert-Equal 12 $global:CodeAntDelegatedComment.PullRequestId 'reply forwards pull request id'
        Assert-Equal 34 $global:CodeAntDelegatedComment.ThreadId 'reply forwards thread id'
        Assert-Equal 5 $global:CodeAntDelegatedComment.ParentCommentId 'reply forwards parent comment id'
        Assert-Equal 'Issue`nFix' $global:CodeAntDelegatedComment.Content 'reply content is delegated to ado-core'
        Assert-Equal 'Fixed' $global:CodeAntDelegatedStatus.Status 'Resolve maps to Fixed'
        Assert-True (($output -join "`n") -match 'comment 77') 'reply output includes the ado-core comment id'
        Assert-True (($output -join "`n") -match 'Thread 34 marked Fixed') 'reply output reports the delegated status'

        . (Join-Path $scriptDir 'codeant-review-state.ps1')
        function Get-CodeAntReviewThreadById {
            param(
                [int]$PullRequestId, $ThreadId, [string]$WorkspaceRoot = '',
                [string]$Collection = '', [string]$Project = '',
                [string]$Repository = '', [string]$ServerUrl = ''
            )
            return [pscustomobject]@{
                id = 34
                status = 'active'
                comments = @([pscustomobject]@{ id = 5; content = 'Same reply' })
            }
        }
        $commentBefore = $global:CodeAntDelegatedComment
        $duplicateResult = Complete-CodeAntReviewFinding `
            -Finding ([pscustomobject]@{ ThreadId = 34; ParentCommentId = 5 }) `
            -Disposition fixed -Reply 'Same reply' -PullRequestId 12
        Assert-True ([object]::ReferenceEquals($commentBefore, $global:CodeAntDelegatedComment)) `
            'an already-posted reply does not call ado-core comment creation again'
        Assert-True ($null -eq $duplicateResult.CommentId) 'an already-posted reply returns no new comment id'
        Assert-Equal 'Fixed' $duplicateResult.Status 'an already-posted reply still updates thread status'
    }
    else {
        [void]$failures.Add('standalone reply delegates through the shared ado-core importer')
    }

    foreach ($fileName in @('codeant-triage-lib.ps1', 'codeant-review-state.ps1', 'Post-CodeAntPrThreadReply.ps1')) {
        $raw = Get-Content -LiteralPath (Join-Path $scriptDir $fileName) -Raw
        Assert-True (-not ($raw -match '(?is)Invoke-(RestMethod|WebRequest).{0,300}-Method\s+(Post|Patch)')) `
            "$fileName contains no direct ADO POST/PATCH write"
    }
}
finally {
    foreach ($name in $adoCoreFunctions) {
        Remove-Item -Path "Function:global:$name" -ErrorAction SilentlyContinue
        if ($originalAdoCoreFunctions.ContainsKey($name)) {
            Set-Item -Path "Function:global:$name" -Value $originalAdoCoreFunctions[$name]
        }
    }
    Remove-Variable -Name CodeAntDelegatedComment -Scope Global -ErrorAction SilentlyContinue
    Remove-Variable -Name CodeAntDelegatedStatus -Scope Global -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $tempRoot) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    Write-Error ('Test-CodeAntAdoCoreDelegation FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join $sep))
    exit 1
}

Write-Output 'OK: CodeAnt delegates ADO writes to ado-core'
exit 0
