#Requires -Version 5.1
<#
.SYNOPSIS
  Isolated git-core library checks (temp repo; no network required).
.EXAMPLE
  & "$PSScriptRoot\Test-GitCore.ps1"
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $scriptDir 'git-core.ps1')

$failures = New-Object 'System.Collections.Generic.List[string]'

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { [void]$failures.Add($Message) }
}

function New-GitCoreTestRepo {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('git-core-' + [guid]::NewGuid().ToString('n'))
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $emptyConfig = Join-Path $root 'empty.gitconfig'
    New-Item -ItemType File -Force -Path $emptyConfig | Out-Null
    $script:prevGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
    $script:prevGitConfigNosystem = $env:GIT_CONFIG_NOSYSTEM
    $env:GIT_CONFIG_GLOBAL = $emptyConfig
    $env:GIT_CONFIG_NOSYSTEM = '1'
    & git -C $root init | Out-Null
    & git -C $root symbolic-ref HEAD refs/heads/main
    & git -C $root config user.email 'git-core-test@example.com'
    & git -C $root config user.name 'git-core-test'
    & git -C $root config commit.gpgsign false
    return $root
}

function Restore-GitCoreTestEnv {
    param([string]$Root)
    if ($null -ne $script:prevGitConfigGlobal) {
        $env:GIT_CONFIG_GLOBAL = $script:prevGitConfigGlobal
    } else {
        Remove-Item Env:GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
    }
    if ($null -ne $script:prevGitConfigNosystem) {
        $env:GIT_CONFIG_NOSYSTEM = $script:prevGitConfigNosystem
    } else {
        Remove-Item Env:GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue
    }
    if ($Root) {
        Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$repo = $null
try {
    $repo = New-GitCoreTestRepo

    $okStatus = Invoke-GitCore -RepoRoot $repo -GitArgs @('status', '--porcelain')
    Assert-True ($okStatus.ok -eq $true) 'Invoke-GitCore status is ok'
    Assert-True ($okStatus.code -eq 0) 'Invoke-GitCore status code is 0'
    Assert-True ($okStatus.PSObject.Properties.Name -contains 'output') 'Invoke-GitCore returns output'
    Assert-True ($okStatus.PSObject.Properties.Name -contains 'code') 'Invoke-GitCore returns code'

    $threw = $false
    try {
        $null = Invoke-GitCore -RepoRoot $repo -GitArgs @('rev-parse', 'NOT_A_REF')
    } catch {
        $threw = $true
    }
    Assert-True (-not $threw) 'Invoke-GitCore does not throw on non-zero git'
    $bad = Invoke-GitCore -RepoRoot $repo -GitArgs @('rev-parse', 'NOT_A_REF')
    Assert-True ($bad.ok -eq $false) 'failed rev-parse ok is false'
    Assert-True ($bad.code -ne 0) 'failed rev-parse code is nonzero'
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$bad.output)) 'failed rev-parse output has git text'

    Assert-True ($null -ne (Get-Command -Name Get-GitCoreHeadSha -ErrorAction SilentlyContinue)) 'Get-GitCoreHeadSha is defined'

    $notRepo = Join-Path $repo 'not-a-repo'
    New-Item -ItemType Directory -Force -Path $notRepo | Out-Null
    $shaThrew = $false
    try {
        $null = Get-GitCoreHeadSha -RepoRoot $notRepo
    } catch {
        $shaThrew = $true
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$_.Exception.Message)) 'Get-GitCoreHeadSha throw includes git text'
    }
    Assert-True $shaThrew 'Get-GitCoreHeadSha throws outside a git repo'

    $file1 = Join-Path $repo 'one.txt'
    Set-Content -LiteralPath $file1 -Value 'first' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $repo -Message 'git-core: first' -Path @('one.txt')
    $sha1 = Get-GitCoreHeadSha -RepoRoot $repo
    Assert-True ($sha1 -match '^[0-9a-f]{40}$') 'first HEAD is a SHA'

    $file2 = Join-Path $repo 'two.txt'
    Set-Content -LiteralPath $file2 -Value 'second' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $repo -Message 'git-core: second' -Path @('two.txt')
    $sha2 = Get-GitCoreHeadSha -RepoRoot $repo
    Assert-True ($sha2 -match '^[0-9a-f]{40}$') 'second HEAD is a SHA'
    Assert-True ($sha1 -ne $sha2) 'Get-GitCoreHeadSha changed after New-GitCoreCommit'

    $nothingThrew = $false
    try {
        New-GitCoreCommit -RepoRoot $repo -Message 'git-core: empty' -Path @('two.txt')
    } catch {
        $nothingThrew = $true
        Assert-True (-not [string]::IsNullOrWhiteSpace([string]$_.Exception.Message)) 'nothing-to-commit throw includes git text'
    }
    Assert-True $nothingThrew 'New-GitCoreCommit throws when there is nothing to commit'

    $extra = Join-Path $repo 'staged-extra.txt'
    Set-Content -LiteralPath $extra -Value 'should stay uncommitted' -Encoding UTF8
    $stageExtra = Invoke-GitCore -RepoRoot $repo -GitArgs @('add', '--', 'staged-extra.txt')
    Assert-True $stageExtra.ok 'staged extra file'
    $only = Join-Path $repo 'only.txt'
    Set-Content -LiteralPath $only -Value 'only this path' -Encoding UTF8
    New-GitCoreCommit -RepoRoot $repo -Message 'git-core: only path' -Path @('only.txt')
    $shaOnly = Get-GitCoreHeadSha -RepoRoot $repo
    Assert-True ($shaOnly -ne $sha2) 'path-limited commit changed HEAD'
    $names = Invoke-GitCore -RepoRoot $repo -GitArgs @('show', '--name-only', '--pretty=format:', 'HEAD')
    Assert-True $names.ok 'show HEAD names'
    $nameText = [string]$names.output
    Assert-True ($nameText -match 'only\.txt') 'commit includes only.txt'
    Assert-True ($nameText -notmatch 'staged-extra\.txt') 'commit does not include unrelated staged file'

    $bare = Join-Path $repo 'bare.git'
    & git init --bare $bare | Out-Null
    & git --git-dir $bare symbolic-ref HEAD refs/heads/main
    $addRemote = Invoke-GitCore -RepoRoot $repo -GitArgs @('remote', 'add', 'origin', $bare)
    Assert-True $addRemote.ok 'temp origin added'
    Push-GitCore -RepoRoot $repo
    $bareHead = Invoke-GitCore -RepoRoot $repo -GitArgs @('--git-dir', $bare, 'rev-parse', 'HEAD')
    Assert-True $bareHead.ok 'bare remote has HEAD'
    Assert-True (([string]$bareHead.output).Trim() -eq $shaOnly) 'Push-GitCore published the latest SHA'

    $optThrew = $false
    try {
        Push-GitCore -RepoRoot $repo -Remote '--receive-pack=true' -Branch 'main'
    } catch {
        $optThrew = $true
        Assert-True ([string]$_.Exception.Message -match 'must not start with -') 'hyphen remote rejected before git'
    }
    Assert-True $optThrew 'Push-GitCore throws for option-like remote'
}
finally {
    Restore-GitCoreTestEnv -Root $repo
}

if ($failures.Count -gt 0) {
    $sep = [Environment]::NewLine + ' - '
    Write-Error ('Test-GitCore FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join $sep))
    exit 1
}

Write-Output 'OK: git-core'
exit 0
