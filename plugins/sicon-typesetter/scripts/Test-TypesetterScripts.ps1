#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

$failures = New-Object 'System.Collections.Generic.List[string]'
function Assert-True { param([bool]$Condition, [string]$Message) if (-not $Condition) { [void]$failures.Add($Message) } }

$scripts = @(Get-ChildItem -LiteralPath $scriptDir -Filter '*.ps1' | Where-Object { $_.Name -ne 'Test-TypesetterScripts.ps1' })
Assert-True ($scripts.Count -gt 0) 'typesetter scripts exist'

foreach ($script in $scripts) {
    $bytes = [IO.File]::ReadAllBytes($script.FullName)
    $ansiText = [Text.Encoding]::Default.GetString($bytes)
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseInput($ansiText, [ref]$tokens, [ref]$errors)
    Assert-True (@($errors).Count -eq 0) ("$($script.Name) parses under Windows PowerShell default encoding")

    $utf8 = New-Object System.Text.UTF8Encoding $false
    $utf8Text = $utf8.GetString($bytes)
    Assert-True ($utf8Text -notmatch '[^\x09\x0A\x0D\x20-\x7E]') ("$($script.Name) stays ASCII so PS 5.1 -File can parse it")
}

if ($failures.Count -gt 0) {
    Write-Error ('Test-TypesetterScripts FAILED:' + [Environment]::NewLine + ' - ' + ($failures -join ([Environment]::NewLine + ' - ')))
    exit 1
}
Write-Output 'OK: typesetter-scripts'
exit 0
