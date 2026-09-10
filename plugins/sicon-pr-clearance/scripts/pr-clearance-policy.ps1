#Requires -Version 5.1
Set-StrictMode -Version Latest

function Get-PrClearancePolicyFuseReason {
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
                        return 'Not a line this fix changed.'
                    }
                }
            }
            else {
                return 'Not on the initial clearance file list.'
            }
        }
    }
    elseif ($PSBoundParameters.ContainsKey('ChangedPaths') -and $null -ne $ChangedPaths) {
        if (-not (Test-PrClearanceFindingInPrScope -Path $path -ChangedPaths $ChangedPaths)) {
            return 'Not a file this PR changed.'
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
        return 'Same suggestion was already completed fixed twice.'
    }
    if (Test-PrClearancePathExhausted -Register $Register -Path $path) {
        return 'This file was code-fixed in three consecutive batches.'
    }
    if (Test-PrClearancePathAmendExhausted -Register $Register -Path $path) {
        return 'This file was amended too many times in this clearance.'
    }
    return ''
}

function Get-PrClearancePolicyDecision {
    param(
        [Parameter(Mandatory = $true)]
        $Finding,
        [Parameter(Mandatory = $true)]
        $Register,
        [string[]]$ChangedPaths
    )
    $reasonArgs = @{ Register = $Register; Finding = $Finding }
    if ($PSBoundParameters.ContainsKey('ChangedPaths')) {
        $reasonArgs.ChangedPaths = $ChangedPaths
    }
    $reason = Get-PrClearancePolicyFuseReason @reasonArgs
    if (-not [string]::IsNullOrWhiteSpace($reason)) {
        return [pscustomobject]@{
            action  = 'dismiss'
            reason  = $reason
            already = $false
        }
    }
    return [pscustomobject]@{
        action  = 'continue'
        reason  = ''
        already = $false
    }
}
