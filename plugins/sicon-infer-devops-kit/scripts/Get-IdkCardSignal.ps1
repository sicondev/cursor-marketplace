#Requires -Version 5.1
<#
.SYNOPSIS
  Thin ADO card signal for /IDK classify — ado-core no-Expand, compact JSON only.
.DESCRIPTION
  Dual-resolves ado-core (plugin-first), fetches one work item without $expand,
  strips HTML, and emits a small classifier payload. Do not use for DLB ingest.
.EXAMPLE
  .\Get-IdkCardSignal.ps1 -WorkItemId 21026 -WorkspaceRoot C:\Repos\approvals
#>
param(
    [Parameter(Mandatory = $true)]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$WorkItemId,

    [string]$WorkspaceRoot = '',

    [ValidateRange(80, 2000)]
    [int]$SnippetChars = 500
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-IdkAdoCoreScriptPath {
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    $pluginsRoot = Join-Path $env:USERPROFILE '.cursor\plugins'
    $direct = Join-Path $pluginsRoot 'sicon-ado-core\scripts\ado-core.ps1'
    if (Test-Path -LiteralPath $direct -PathType Leaf) {
        [void]$candidates.Add($direct)
    }
    foreach ($sub in @('marketplaces', 'cache')) {
        $root = Join-Path $pluginsRoot $sub
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Recurse -Depth 8 -Filter 'ado-core.ps1' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match '[\\/]sicon-ado-core[\\/]scripts[\\/]ado-core\.ps1$' } |
            ForEach-Object {
                if (-not $candidates.Contains($_.FullName)) {
                    [void]$candidates.Add($_.FullName)
                }
            }
    }
    if ($candidates.Count -gt 0) {
        return (
            @($candidates) |
                Sort-Object { (Get-Item -LiteralPath $_).LastWriteTimeUtc } -Descending |
                Select-Object -First 1
        )
    }
    $userPack = Join-Path $env:USERPROFILE '.cursor\packs\ado-core\scripts\ado-core.ps1'
    if (Test-Path -LiteralPath $userPack -PathType Leaf) {
        return $userPack
    }
    throw 'ADO Core library not found. Install Sicon ADO Core (Team Marketplace) or Install-UserPack -Pack ado-core.'
}

function Remove-IdkHtmlTagsLinear {
    <#
    .SYNOPSIS
      Linear-time strip of HTML comments and tag-shaped spans. Avoids ReDoS on malformed ADO HTML.
      Keeps raw comparisons like "a < b > c" (not a tag name after '<').
    #>
    param([Parameter(Mandatory = $true)][string]$Text)

    $sb = New-Object System.Text.StringBuilder ($Text.Length)
    $i = 0
    $n = $Text.Length
    $maxTag = 512
    while ($i -lt $n) {
        $ch = $Text[$i]
        if ($ch -ne '<') {
            [void]$sb.Append($ch)
            $i++
            continue
        }

        # HTML comment <!-- ... -->
        if (($i + 3) -lt $n -and $Text[$i + 1] -eq '!' -and $Text[$i + 2] -eq '-' -and $Text[$i + 3] -eq '-') {
            $end = $Text.IndexOf('-->', $i + 4)
            if ($end -lt 0) {
                [void]$sb.Append(' ')
                break
            }
            [void]$sb.Append(' ')
            $i = $end + 3
            continue
        }

        # Tag-shaped: </?Name ... > with bounded scan (no backtracking).
        $j = $i + 1
        if ($j -lt $n -and $Text[$j] -eq '/') { $j++ }
        if ($j -ge $n -or -not [char]::IsLetter($Text[$j])) {
            [void]$sb.Append('<')
            $i++
            continue
        }
        $j++
        while ($j -lt $n -and [char]::IsLetterOrDigit($Text[$j])) { $j++ }

        $limit = [Math]::Min($n, $i + $maxTag)
        $gt = -1
        $k = $j
        while ($k -lt $limit) {
            if ($Text[$k] -eq '>') { $gt = $k; break }
            $k++
        }
        if ($gt -lt 0) {
            # Unclosed / oversized — drop the '<' and continue (fail closed for ReDoS).
            [void]$sb.Append(' ')
            $i++
            continue
        }

        $nameEnd = $j
        $tagName = $Text.Substring($i + 1, $nameEnd - ($i + 1)).TrimStart('/').ToLowerInvariant()
        $isClose = ($i + 1 -lt $n -and $Text[$i + 1] -eq '/')

        # Drop script/style bodies (open tag → matching close, linear scan).
        if (-not $isClose -and ($tagName -eq 'script' -or $tagName -eq 'style')) {
            $closeNeedle = "</$tagName>"
            $closeAt = $Text.IndexOf($closeNeedle, $gt + 1, [System.StringComparison]::OrdinalIgnoreCase)
            if ($closeAt -lt 0) {
                [void]$sb.Append(' ')
                break
            }
            [void]$sb.Append(' ')
            $i = $closeAt + $closeNeedle.Length
            continue
        }

        if ($tagName -eq 'br' -or (
                $isClose -and (
                    $tagName -eq 'p' -or $tagName -eq 'div' -or $tagName -eq 'li' -or $tagName -eq 'tr' -or
                    $tagName -eq 'h1' -or $tagName -eq 'h2' -or $tagName -eq 'h3' -or $tagName -eq 'h4' -or
                    $tagName -eq 'h5' -or $tagName -eq 'h6'
                )
            )) {
            [void]$sb.Append("`n")
        }
        else {
            [void]$sb.Append(' ')
        }
        $i = $gt + 1
    }
    return $sb.ToString()
}

function ConvertTo-IdkPlainText {
    param([AllowNull()][string]$Html)

    if ([string]::IsNullOrWhiteSpace($Html)) { return '' }
    $t = Remove-IdkHtmlTagsLinear -Text $Html
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = [regex]::Replace($t, '[ \t]+', ' ')
    $t = [regex]::Replace($t, '(\r?\n){3,}', "`n`n")
    return $t.Trim()
}

function Get-IdkSnippet {
    param([string]$Text, [int]$MaxChars)

    if ([string]::IsNullOrEmpty($Text) -or $MaxChars -le 0) { return '' }
    if ($Text.Length -le $MaxChars) { return $Text }
    $ellipsis = [string][char]0x2026
    if ($MaxChars -eq 1) { return $ellipsis }
    return $Text.Substring(0, $MaxChars - 1).TrimEnd() + $ellipsis
}

function Get-IdkBudgetedSnippet {
    <#
    .SYNOPSIS
      Title + desc head + AC head so a long description cannot starve AC in the classifier snippet.
    #>
    param(
        [string]$Title,
        [string]$DescPlain,
        [string]$AcPlain,
        [bool]$AcEmpty,
        [int]$MaxChars
    )

    $parts = New-Object 'System.Collections.Generic.List[string]'
    $titlePart = Get-IdkSnippet -Text $Title -MaxChars ([Math]::Min(160, $MaxChars))
    if (-not [string]::IsNullOrWhiteSpace($titlePart)) {
        [void]$parts.Add($titlePart)
    }

    $used = ($parts -join "`n").Length
    if ($parts.Count -gt 0) { $used += 1 } # pending join newline before next part
    $remain = [Math]::Max(0, $MaxChars - $used)

    if ($AcEmpty -or [string]::IsNullOrWhiteSpace($AcPlain)) {
        $descPart = Get-IdkSnippet -Text $DescPlain -MaxChars $remain
        if (-not [string]::IsNullOrWhiteSpace($descPart)) {
            [void]$parts.Add($descPart)
        }
        return ($parts -join "`n")
    }

    # Soft-cap desc so a fat description cannot wipe AC; unused desc budget folds into AC.
    $acReserve = [Math]::Max(80, [int][Math]::Floor($remain * 0.4))
    $descBudget = [Math]::Max(0, $remain - $acReserve)
    $descPart = Get-IdkSnippet -Text $DescPlain -MaxChars $descBudget
    $descLen = 0
    if (-not [string]::IsNullOrWhiteSpace($descPart)) {
        [void]$parts.Add($descPart)
        $descLen = $descPart.Length
    }
    $sep = if ($descLen -gt 0) { 1 } else { 0 }
    $acBudget = [Math]::Max(0, $remain - $descLen - $sep)
    $acPart = Get-IdkSnippet -Text $AcPlain -MaxChars $acBudget
    if (-not [string]::IsNullOrWhiteSpace($acPart)) {
        [void]$parts.Add($acPart)
    }
    return ($parts -join "`n")
}

function Get-IdkSignals {
    param([string]$Haystack)

    $signals = New-Object 'System.Collections.Generic.List[string]'
    $h = $Haystack.ToLowerInvariant()
    # Word-ish matches — avoid substrings (e.g. prove∈professional, hub∈github).
    $map = @(
        @{ re = '\bhub\b'; s = 'hub' },
        @{ re = '\bplatform\b'; s = 'platform' },
        @{ re = '\bapprovals?\b'; s = 'approvals' },
        @{ re = '\bsage\b'; s = 'sage' },
        @{ re = '\bprove\b'; s = 'prove' },
        @{ re = '\bsecurity\b'; s = 'security' },
        @{ re = '\bsplash\b'; s = 'splash' },
        @{ re = 'multi[\s-]?repo'; s = 'multi-repo' },
        @{ re = 'acceptance criteria'; s = 'ac-mentioned' }
    )
    foreach ($item in $map) {
        if ($h -match [string]$item.re) {
            [void]$signals.Add([string]$item.s)
        }
    }
    return @($signals | Select-Object -Unique)
}

function Get-IdkFieldText {
    param($Fields, [string]$Name)

    if ($null -eq $Fields) { return '' }
    $prop = $Fields.PSObject.Properties[$Name]
    if ($null -eq $prop) { return '' }
    return [string]$prop.Value
}

$adoCorePath = Resolve-IdkAdoCoreScriptPath
. $adoCorePath
if (-not (Get-Command Get-AdoCoreWorkItem -ErrorAction SilentlyContinue)) {
    throw "ADO Core helpers missing after load: $adoCorePath"
}
if (Get-Command Get-AdoCoreLibraryVersion -ErrorAction SilentlyContinue) {
    $ver = [version](Get-AdoCoreLibraryVersion)
    if ($ver -lt [version]'0.5.0') {
        throw "ado-core version $ver is below required 0.5.0 ($adoCorePath)"
    }
}

$wiArgs = @{
    WorkItemId = $WorkItemId
}
if (-not [string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
    $wiArgs.WorkspaceRoot = $WorkspaceRoot
}

# Thin read — no -Expand (relations / Halo fan-out stay out).
$wi = Get-AdoCoreWorkItem @wiArgs
$fields = $wi.fields
$title = Get-IdkFieldText -Fields $fields -Name 'System.Title'
$type = Get-IdkFieldText -Fields $fields -Name 'System.WorkItemType'
$descHtml = Get-IdkFieldText -Fields $fields -Name 'System.Description'
$acHtml = Get-IdkFieldText -Fields $fields -Name 'Microsoft.VSTS.Common.AcceptanceCriteria'

$descPlain = ConvertTo-IdkPlainText -Html $descHtml
$acPlain = ConvertTo-IdkPlainText -Html $acHtml
$acEmpty = [string]::IsNullOrWhiteSpace($acPlain)

$bundle = @(
    $title
    $descPlain
    $(if ($acEmpty) { '' } else { $acPlain })
) -join "`n"
# Full bundle for signals; budgeted snippet so AC is not hidden by a long description.
$snippet = Get-IdkBudgetedSnippet -Title $title -DescPlain $descPlain -AcPlain $acPlain -AcEmpty $acEmpty -MaxChars $SnippetChars
$signals = Get-IdkSignals -Haystack $bundle

$result = [ordered]@{
    id        = $WorkItemId
    type      = $type
    title     = $title
    acEmpty   = $acEmpty
    descChars = $descPlain.Length
    acChars   = $acPlain.Length
    snippet   = $snippet
    signals   = @($signals)
}

$result | ConvertTo-Json -Compress -Depth 4
