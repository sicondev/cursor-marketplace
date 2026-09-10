#Requires -Version 5.1
<#
.SYNOPSIS
  Posts a reply on an Azure DevOps PR thread and optionally resolves the thread.
.PARAMETER PullRequestId
  Azure DevOps pull request id.
.PARAMETER ThreadId
  PR comment thread id (from Fetch-CodeAntPrFindings.ps1 -Json).
.PARAMETER Reply
  Reply body (markdown). Use concise **Issue:** / **Fix:** lines for a fixed finding, or
  **Issue:** / **WontFix Reason:** when Status is WontFix. Keep plain language for PR readers
  (no CAP-/AP- ids, pack paths, parity, or deferral jargon — see /codeant-triage § ADO PR reply text).
.PARAMETER ParentCommentId
  Parent comment id to reply under (required; use ParentCommentId from Fetch-CodeAntPrFindings.ps1 -Json).
.PARAMETER Resolve
  Mark thread status Fixed after posting (use when fix is committed/pushed).
.PARAMETER Status
  Explicit thread status: Active, Fixed, WontFix, Closed, ByDesign. Overrides -Resolve.
.EXAMPLE
  ./Post-CodeAntPrThreadReply.ps1 -PullRequestId 28305 -ThreadId 135393 -ParentCommentId 1 -Reply 'Fixed in ...' -Resolve
#>
param(
    [Parameter(Mandatory = $true)]
    [int]$PullRequestId,

    [Parameter(Mandatory = $true)]
    [int]$ThreadId,

    [Parameter(Mandatory = $true)]
    [string]$Reply,

    [Parameter(Mandatory = $true)]
    [int]$ParentCommentId,

    [switch]$Resolve,

    [ValidateSet('Active', 'Fixed', 'WontFix', 'Closed', 'ByDesign')]
    [string]$Status = '',

    [string]$Collection = '',
    [string]$Project = '',
    [string]$Repository = '',
    [string]$ServerUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'codeant-triage-lib.ps1')

Import-CodeAntAdoCore | Out-Null
$posted = Add-AdoCorePullRequestThreadComment -PullRequestId $PullRequestId `
    -ThreadId $ThreadId -ParentCommentId $ParentCommentId -Content $Reply `
    -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
Write-Output ('Posted reply on PR ' + $PullRequestId + ' thread ' + $ThreadId + ' (comment ' + $posted.CommentId + ')')

$targetStatus = $Status
if (-not $targetStatus -and $Resolve) {
    $targetStatus = 'Fixed'
}

if ($targetStatus) {
    Set-AdoCorePullRequestThreadStatus -PullRequestId $PullRequestId `
        -ThreadId $ThreadId -Status $targetStatus `
        -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
    Write-Output ('Thread ' + $ThreadId + ' marked ' + $targetStatus)
}
