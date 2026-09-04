#Requires -Version 5.1
<#
.SYNOPSIS
  Marks active CodeAnt trigger threads Fixed (@/# codeant-ai: review) so they do not block ADO autocomplete.
.PARAMETER PullRequestId
  Azure DevOps pull request id.
.EXAMPLE
  ./Clear-CodeAntRetriggerThreads.ps1 -PullRequestId 30055
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$PullRequestId,

    [string]$Collection = '',
    [string]$Project = '',
    [string]$Repository = '',
    [string]$ServerUrl = '',

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

$result = Clear-CodeAntRetriggerThreads -PullRequestId $PullRequestId `
    -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl

if ($Json) {
    $result | ConvertTo-Json -Depth 4
}
else {
    Write-Output ("Cleared $($result.ResolvedCount) active CodeAnt trigger thread(s) on PR $PullRequestId")
    if ($result.ResolvedCount -gt 0) {
        Write-Output ("ThreadIds: $($result.ThreadIds -join ', ')")
    }
    foreach ($warning in @($result.Warnings)) {
        Write-Warning $warning
    }
}
