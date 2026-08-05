#Requires -Version 5.1
<#
.SYNOPSIS
  Seed ~/.cursor/memory/ for personal-todo — copies templates only when targets are missing.
.DESCRIPTION
  Templates are resolved relative to this script:
    <root>/scripts/Initialize-PersonalTodoMemory.ps1
    <root>/templates/memory/...
  <root> is either ~/.cursor/packs/personal-todo (user-pack) or the sicon-personal-todo plugin tree.
.EXAMPLE
  & "$env:USERPROFILE\.cursor\packs\personal-todo\scripts\Initialize-PersonalTodoMemory.ps1"
.EXAMPLE
  powershell -NoProfile -File <plugin-root>\scripts\Initialize-PersonalTodoMemory.ps1
#>
param(
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.cursor'),
    [string]$TemplateRoot = '',
    [switch]$WhatIf
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TemplateRoot)) {
    $TemplateRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'templates\memory'
}
$TemplateRoot = [IO.Path]::GetFullPath($TemplateRoot)

if (-not (Test-Path -LiteralPath $TemplateRoot)) {
    throw @"
Templates not found at: $TemplateRoot
Install personal-todo (user pack or Team Marketplace plugin), then re-run this script from that install's scripts/ folder.
"@
}

$fragmentSrc = Join-Path $TemplateRoot 'memory-personal-todos.fragment.md'
if (-not (Test-Path -LiteralPath $fragmentSrc -PathType Leaf)) {
    throw "Missing required template fragment: $fragmentSrc"
}

function Copy-IfMissing {
    param(
        [string]$RelativePath
    )
    $src = Join-Path $TemplateRoot $RelativePath
    $dest = Join-Path (Join-Path $ProfileRoot 'memory') $RelativePath
    if (-not (Test-Path -LiteralPath $src)) {
        throw "Missing template: $src"
    }
    if (Test-Path -LiteralPath $dest) {
        Write-Output "Skip (exists): $dest"
        return
    }
    $destDir = Split-Path -Parent $dest
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        if ($WhatIf) { Write-Output "[WhatIf] mkdir $destDir" }
        else { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    }
    if ($WhatIf) {
        Write-Output "[WhatIf] copy $src -> $dest"
    }
    else {
        Copy-Item -LiteralPath $src -Destination $dest -Force
        Write-Output "Seeded: $dest"
    }
}

Copy-IfMissing -RelativePath 'todos.md'
Copy-IfMissing -RelativePath 'todos\FORMAT.md'
Copy-IfMissing -RelativePath 'todos\transcripts\README.md'

$memoryPath = Join-Path (Join-Path $ProfileRoot 'memory') 'memory.md'
if (-not (Test-Path -LiteralPath $memoryPath)) {
    $stub = @"
# Personal agent memory

Private to this developer. Agents may read and update this file, todos.md, transcripts under todos/transcripts/, and daily logs under logs/.

**Windows:** %USERPROFILE%\.cursor\memory\
**macOS/Linux:** ~/.cursor/memory/

$(Get-Content -LiteralPath $fragmentSrc -Raw)

## Preferences

- (Editor, workflow, and communication preferences)

"@
    if ($WhatIf) { Write-Output "[WhatIf] write $memoryPath" }
    else {
        $memoryDir = Split-Path -Parent $memoryPath
        if (-not (Test-Path -LiteralPath $memoryDir)) {
            New-Item -ItemType Directory -Force -Path $memoryDir | Out-Null
        }
        [System.IO.File]::WriteAllText($memoryPath, $stub, [System.Text.UTF8Encoding]::new($false))
        Write-Output "Seeded: $memoryPath"
    }
}
else {
    Write-Output "Skip memory.md (exists) - merge Personal todos section from $fragmentSrc if missing"
}

Write-Output 'Done.'
