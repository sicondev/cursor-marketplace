#Requires -Version 5.1
<#
.SYNOPSIS
  Posts a reply on an Azure DevOps PR thread and optionally resolves the thread.
.PARAMETER PullRequestId
  Azure DevOps pull request id.
.PARAMETER ThreadId
  PR comment thread id (from Fetch-CodeAntPrFindings.ps1 -Json).
.PARAMETER Reply
  Reply body (markdown). Use concise **Issue:** / **Fix:** lines in plain language for PR readers
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

$StatusMap = @{
    Active   = 1
    Fixed    = 2
    WontFix  = 3
    Closed   = 4
    ByDesign = 5
}

$endpoints = Resolve-AdoCodeAntTriageEndpoints -Collection $Collection -Project $Project -Repository $Repository -ServerUrl $ServerUrl
$apiBase = $endpoints.ApiBase
$threadBase = "$apiBase/pullRequests/$PullRequestId/threads/$ThreadId"

# Callers often pass literal `n when nesting shells or using single-quoted -Reply; expand before ADO post.
# Longest token first: `\\n` (two backslashes + n) before `\n` (one backslash + n) before `` `n ``.
$Reply = $Reply -creplace '(\\\\n|\\n|`n)', [Environment]::NewLine

$commentUri = "$threadBase/comments?api-version=7.0"
$commentBody = @{
    parentCommentId = $ParentCommentId
    content         = $Reply
    commentType     = 1
} | ConvertTo-Json

$posted = Invoke-RestMethod -Uri $commentUri -Method Post -Body $commentBody -ContentType 'application/json' -UseDefaultCredentials
Write-Output ('Posted reply on PR ' + $PullRequestId + ' thread ' + $ThreadId + ' (comment ' + $posted.id + ')')

$targetStatus = $Status
if (-not $targetStatus -and $Resolve) {
    $targetStatus = 'Fixed'
}

if ($targetStatus) {
    $patchUri = "$threadBase`?api-version=7.0"
    $patchBody = @{ status = $StatusMap[$targetStatus] } | ConvertTo-Json
    Invoke-RestMethod -Uri $patchUri -Method Patch -Body $patchBody -ContentType 'application/json' -UseDefaultCredentials | Out-Null
    Write-Output ('Thread ' + $ThreadId + ' marked ' + $targetStatus)
}
