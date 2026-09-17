#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-TypesetterNativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [IO.Path]::GetFullPath($Path)
}

function Get-TypesetterGitRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    $dir = if (Test-Path -LiteralPath $Path -PathType Leaf) {
        Split-Path -Parent $Path
    } else {
        $Path
    }
    Push-Location -LiteralPath $dir
    try {
        $root = & git rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($root)) { return $null }
        return (ConvertTo-TypesetterNativePath -Path $root.Trim())
    } finally {
        Pop-Location
    }
}

function ConvertFrom-TypesetterGitStatusPath {
    param([Parameter(Mandatory = $true)][string]$Raw)
    # Porcelain is invoked with -z and core.quotepath=false, so paths are literal
    # (including filenames that begin/end with quotes). Do not C-unquote.
    return $Raw
}

function Get-TypesetterDirtyFiles {
    param([string]$StartPath = (Get-Location).Path)

    $root = Get-TypesetterGitRoot -Path $StartPath
    if (-not $root) { return @() }

    $tmpOut = $null
    $tmpErr = $null
    Push-Location -LiteralPath $root
    try {
        $tmpOut = [IO.Path]::GetTempFileName()
        $tmpErr = [IO.Path]::GetTempFileName()
        $p = Start-Process -FilePath 'git' -ArgumentList @('-c', 'core.quotepath=false', 'status', '--porcelain', '-uall', '-z') -WorkingDirectory $root -Wait -PassThru -NoNewWindow -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr
        if ([int]$p.ExitCode -ne 0) {
            throw ("git status failed with exit code {0}." -f $p.ExitCode)
        }
        $files = New-Object 'System.Collections.Generic.List[string]'
        $fs = [IO.File]::OpenRead($tmpOut)
        try {
            $chunk = New-Object System.Collections.Generic.List[byte]
            $pendingRename = $false
            $buf = New-Object byte[] 4096
            while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                for ($b = 0; $b -lt $n; $b++) {
                    if ($buf[$b] -eq 0) {
                        $text = [Text.Encoding]::UTF8.GetString($chunk.ToArray())
                        $chunk.Clear()
                        if ($pendingRename) {
                            $pathText = ConvertFrom-TypesetterGitStatusPath -Raw $text
                            $pendingRename = $false
                        } else {
                            if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -lt 3) { continue }
                            $xy = $text.Substring(0, 2)
                            if ($text.Length -ge 3 -and $text[2] -eq ' ') {
                                $pathText = $text.Substring(3)
                            } else {
                                $pathText = $text.Substring(2)
                            }
                            if ($xy -match '[RC]') {
                                $pendingRename = $true
                                continue
                            }
                            $pathText = ConvertFrom-TypesetterGitStatusPath -Raw $pathText
                        }
                        if ([string]::IsNullOrWhiteSpace($pathText)) { continue }
                        $full = ConvertTo-TypesetterNativePath -Path (Join-Path $root $pathText)
                        if (Test-Path -LiteralPath $full -PathType Leaf) {
                            [void]$files.Add($full)
                        }
                    } else {
                        [void]$chunk.Add($buf[$b])
                    }
                }
            }
        } finally {
            $fs.Dispose()
        }
        return @($files | Select-Object -Unique)
    } finally {
        Pop-Location
        if ($tmpOut -and (Test-Path -LiteralPath $tmpOut)) { Remove-Item -LiteralPath $tmpOut -Force -ErrorAction SilentlyContinue }
        if ($tmpErr -and (Test-Path -LiteralPath $tmpErr)) { Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue }
    }
}

function Test-TypesetterPackageHas {
    param($Package, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Package) { return $false }
    foreach ($bucketName in @('devDependencies', 'dependencies')) {
        $bucket = $null
        if ($Package.PSObject.Properties.Name -contains $bucketName) {
            $bucket = $Package.$bucketName
        }
        if ($null -eq $bucket) { continue }
        if ($bucket.PSObject.Properties.Name -contains $Name) { return $true }
    }
    return $false
}

function Get-TypesetterPackageJson {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $packageJson = Join-Path $RepoRoot 'package.json'
    if (-not (Test-Path -LiteralPath $packageJson)) { return $null }
    try {
        return (Get-Content -LiteralPath $packageJson -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Test-TypesetterPathExists {
    param([Parameter(Mandatory = $true)][string]$RepoRoot, [Parameter(Mandatory = $true)][string[]]$Names)
    foreach ($n in $Names) {
        if (Test-Path -LiteralPath (Join-Path $RepoRoot $n)) { return $true }
    }
    return $false
}

function Get-TypesetterMsBuildDiscovery {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    $skip = @('packages', 'node_modules', 'bin', 'obj', '.git')
    $csprojs = New-Object 'System.Collections.Generic.List[object]'
    $propsFiles = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($RepoRoot)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($proj in @(Get-ChildItem -LiteralPath $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue)) {
            [void]$csprojs.Add($proj)
        }
        foreach ($propsName in @('Directory.Build.props', 'Directory.Packages.props', 'Directory.Build.targets')) {
            $propsPath = Join-Path $dir $propsName
            if (Test-Path -LiteralPath $propsPath -PathType Leaf) {
                [void]$propsFiles.Add((Get-Item -LiteralPath $propsPath))
            }
        }
        foreach ($child in @(Get-ChildItem -LiteralPath $dir -Directory -ErrorAction SilentlyContinue)) {
            if ($skip -contains $child.Name) { continue }
            $stack.Push($child.FullName)
        }
    }
    return [pscustomobject]@{
        CsProjects = @($csprojs)
        PropsFiles = @($propsFiles)
    }
}

function Get-TypesetterCsProjects {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    return @((Get-TypesetterMsBuildDiscovery -RepoRoot $RepoRoot).CsProjects)
}

function New-TypesetterProjectDirectoryIndex {
    param([object[]]$CsProjects = @())
    $index = @{}
    foreach ($proj in @($CsProjects)) {
        $dir = Split-Path -Parent $proj.FullName
        if (-not $index.ContainsKey($dir)) {
            $index[$dir] = $proj.FullName
        }
    }
    return $index
}

function Get-TypesetterRepoTooling {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [switch]$SkipFormat,
        [switch]$SkipLint
    )

    $pkg = $null
    $needPkg = $true
    $formatEngines = New-Object 'System.Collections.Generic.List[string]'
    $lintEngines = New-Object 'System.Collections.Generic.List[string]'
    $discovery = $null
    $projectIndex = @{}

    if (-not $SkipFormat) {
        if ($needPkg) { $pkg = Get-TypesetterPackageJson -RepoRoot $RepoRoot; $needPkg = $false }
        if ((Test-TypesetterPathExists -RepoRoot $RepoRoot -Names @('.prettierrc', '.prettierrc.json', '.prettierrc.yml', '.prettierrc.yaml', 'prettier.config.js', 'prettier.config.cjs', 'prettier.config.mjs')) -or (Test-TypesetterPackageHas -Package $pkg -Name 'prettier')) {
            [void]$formatEngines.Add('prettier')
        }
        $sln = @(Get-ChildItem -LiteralPath $RepoRoot -Filter '*.sln' -File -ErrorAction SilentlyContinue)
        $hasCs = $false
        if ($sln.Count -gt 0) {
            $hasCs = $true
            if ($null -eq $discovery) {
                $discovery = Get-TypesetterMsBuildDiscovery -RepoRoot $RepoRoot
                $projectIndex = New-TypesetterProjectDirectoryIndex -CsProjects $discovery.CsProjects
            }
        }
        if (-not $hasCs) {
            if ($null -eq $discovery) {
                $discovery = Get-TypesetterMsBuildDiscovery -RepoRoot $RepoRoot
                $projectIndex = New-TypesetterProjectDirectoryIndex -CsProjects $discovery.CsProjects
            }
            if (@($discovery.CsProjects).Count -gt 0) { $hasCs = $true }
        }
        if ($hasCs) { [void]$formatEngines.Add('dotnet') }
    }

    if (-not $SkipLint) {
        if ($needPkg) { $pkg = Get-TypesetterPackageJson -RepoRoot $RepoRoot; $needPkg = $false }
        if ((Test-TypesetterPathExists -RepoRoot $RepoRoot -Names @('.eslintrc', '.eslintrc.cjs', '.eslintrc.js', '.eslintrc.json', '.eslintrc.yml', 'eslint.config.js', 'eslint.config.cjs', 'eslint.config.mjs', 'eslint.config.ts')) -or (Test-TypesetterPackageHas -Package $pkg -Name 'eslint')) {
            [void]$lintEngines.Add('eslint')
        }
        if ($null -eq $discovery) {
            $discovery = Get-TypesetterMsBuildDiscovery -RepoRoot $RepoRoot
            $projectIndex = New-TypesetterProjectDirectoryIndex -CsProjects $discovery.CsProjects
        }
        $analyzerProbe = New-Object 'System.Collections.Generic.List[object]'
        foreach ($p in @($discovery.CsProjects)) { [void]$analyzerProbe.Add($p) }
        foreach ($p in @($discovery.PropsFiles)) { [void]$analyzerProbe.Add($p) }
        foreach ($p in $analyzerProbe) {
            $text = Get-Content -LiteralPath $p.FullName -Raw -ErrorAction SilentlyContinue
            if ([string]::IsNullOrEmpty($text)) { continue }
            $text = [regex]::Replace($text, '(?s)<!--.*?-->', '')
            $enabled = $false
            if ($text -match '(?i)<EnableNETAnalyzers>\s*true\s*</EnableNETAnalyzers>') { $enabled = $true }
            elseif ($text -match '(?i)<EnforceCodeStyleInBuild>\s*true\s*</EnforceCodeStyleInBuild>') { $enabled = $true }
            elseif ($text -match '(?i)<AnalysisLevel>\s*(?!none\s*<)[^<]+</AnalysisLevel>') { $enabled = $true }
            elseif ($text -match '(?i)<EffectiveAnalysisLevel>\s*(?!none\s*<)[^<]+</EffectiveAnalysisLevel>') { $enabled = $true }
            elseif ($text -match '(?i)<PackageReference[^>]*Include\s*=\s*[''"]Microsoft\.CodeAnalysis\.NetAnalyzers[''"]') { $enabled = $true }
            if ($enabled) {
                [void]$lintEngines.Add('dotnet-analyzers')
                break
            }
        }
    }

    $formatEngine = 'none'
    if ($formatEngines.Count -gt 0) { $formatEngine = [string]$formatEngines[0] }
    $lintEngine = 'none'
    if ($lintEngines.Count -gt 0) { $lintEngine = [string]$lintEngines[0] }

    return [pscustomobject]@{
        formatEngine  = $formatEngine
        formatEngines = @($formatEngines)
        lintEngine    = $lintEngine
        lintEngines   = @($lintEngines)
        projectIndex  = $projectIndex
    }
}

function Get-TypesetterFormatEngine {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    return [string](Get-TypesetterRepoTooling -RepoRoot $RepoRoot -SkipLint).formatEngine
}

function Get-TypesetterLintEngine {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    return [string](Get-TypesetterRepoTooling -RepoRoot $RepoRoot -SkipFormat).lintEngine
}

function Get-TypesetterProjectDirectoryIndex {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)
    return (New-TypesetterProjectDirectoryIndex -CsProjects (Get-TypesetterCsProjects -RepoRoot $RepoRoot))
}

function Get-TypesetterSolutionOrProject {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string[]]$PreferFiles = @(),
        $ProjectIndex = $null
    )

    $rootFull = ConvertTo-TypesetterNativePath -Path $RepoRoot
    if ($null -eq $ProjectIndex -and (@($PreferFiles | Where-Object { $_ -match '\.cs$' }).Count -gt 0)) {
        $ProjectIndex = Get-TypesetterProjectDirectoryIndex -RepoRoot $RepoRoot
    }
    foreach ($f in $PreferFiles) {
        if ($f -notmatch '\.cs$') { continue }
        $dir = Split-Path -Parent $f
        while ($dir -and $dir.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            if ($ProjectIndex -and $ProjectIndex.ContainsKey($dir)) {
                return [string]$ProjectIndex[$dir]
            }
            $proj = @(Get-ChildItem -LiteralPath $dir -Filter '*.csproj' -File -ErrorAction SilentlyContinue)
            if ($proj.Count -gt 0) { return $proj[0].FullName }
            $parent = Split-Path -Parent $dir
            if ($parent -eq $dir) { break }
            $dir = $parent
        }
    }

    if (@($PreferFiles | Where-Object { $_ -match '\.cs$' }).Count -gt 0) {
        return $null
    }

    $sln = @(Get-ChildItem -LiteralPath $RepoRoot -Filter '*.sln' -File -ErrorAction SilentlyContinue |
        Sort-Object Name)
    if ($sln.Count -gt 0) { return $sln[0].FullName }

    $csproj = @(Get-TypesetterCsProjects -RepoRoot $RepoRoot | Sort-Object FullName)
    if ($csproj.Count -gt 0) { return $csproj[0].FullName }
    return $null
}

function Group-TypesetterCsFilesByProject {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$CsFiles,
        $ProjectIndex = $null
    )
    if ($null -eq $ProjectIndex -or @($ProjectIndex.Keys).Count -eq 0) {
        $ProjectIndex = Get-TypesetterProjectDirectoryIndex -RepoRoot $RepoRoot
    }
    $map = @{}
    foreach ($cs in $CsFiles) {
        $target = Get-TypesetterSolutionOrProject -RepoRoot $RepoRoot -PreferFiles @($cs) -ProjectIndex $ProjectIndex
        if (-not $target) { continue }
        if (-not $map.ContainsKey($target)) {
            $map[$target] = New-Object 'System.Collections.Generic.List[string]'
        }
        [void]$map[$target].Add($cs)
    }
    return $map
}

function Add-TypesetterReportOutput {
    param(
        [AllowNull()][string]$Existing,
        [AllowNull()][string]$Chunk,
        [int]$MaxChars = 8000
    )
    if ([string]::IsNullOrEmpty($Chunk)) { return [string]$Existing }
    $sb = New-Object System.Text.StringBuilder
    if (-not [string]::IsNullOrEmpty($Existing)) {
        [void]$sb.Append($Existing)
        if (-not $Existing.EndsWith([Environment]::NewLine)) {
            [void]$sb.AppendLine()
        }
    }
    $remain = $MaxChars - $sb.Length
    if ($remain -le 0) {
        return ($sb.ToString() + '... (output truncated)')
    }
    if ($Chunk.Length -gt $remain) {
        [void]$sb.Append($Chunk.Substring(0, $remain))
        [void]$sb.Append('... (output truncated)')
    } else {
        [void]$sb.Append($Chunk)
    }
    return $sb.ToString()
}

function Get-TypesetterPathComparer {
    if ($env:OS -eq 'Windows_NT') {
        return [StringComparer]::OrdinalIgnoreCase
    }
    return [StringComparer]::Ordinal
}

function Test-TypesetterSafeRepoFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$RepoRoot
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    $full = ConvertTo-TypesetterNativePath -Path $Path
    $rootFull = ConvertTo-TypesetterNativePath -Path $RepoRoot
    $rootTrim = $rootFull.TrimEnd('\', '/')
    if (-not $rootFull.EndsWith([string][IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [IO.Path]::DirectorySeparatorChar
    }
    if (-not $full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) { return $false }

    $cursor = Split-Path -Parent $full
    while ($cursor -and $cursor.Length -ge $rootTrim.Length) {
        if (-not (Test-Path -LiteralPath $cursor)) { return $false }
        $dirItem = Get-Item -LiteralPath $cursor -Force
        if (($dirItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        if ($cursor.Equals($rootTrim, [StringComparison]::OrdinalIgnoreCase)) { break }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    return $true
}

function ConvertTo-TypesetterRelativeInclude {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string[]]$Files
    )
    $rootFull = (ConvertTo-TypesetterNativePath -Path $RepoRoot).TrimEnd('\', '/')
    $rels = foreach ($f in $Files) {
        $full = ConvertTo-TypesetterNativePath -Path $f
        if ($full.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $full.Substring($rootFull.Length).TrimStart('\', '/')
            $rel -replace '\\', '/'
        }
    }
    return @($rels | Where-Object { $_ } | Select-Object -Unique)
}

function Group-TypesetterByRoot {
    param([string[]]$Files)

    $map = @{}
    $cache = @{}
    foreach ($f in $Files) {
        $dir = if (Test-Path -LiteralPath $f -PathType Leaf) { Split-Path -Parent $f } else { $f }
        $root = $null
        if ($cache.ContainsKey($dir)) {
            $root = $cache[$dir]
        } else {
            $cursor = $dir
            while ($cursor) {
                if ($cache.ContainsKey($cursor)) {
                    $root = $cache[$cursor]
                    break
                }
                $parent = Split-Path -Parent $cursor
                if (-not $parent -or $parent -eq $cursor) { break }
                $cursor = $parent
            }
            if (-not $root) {
                $root = Get-TypesetterGitRoot -Path $dir
            }
            if ($root) {
                $fill = $dir
                $rootFull = ConvertTo-TypesetterNativePath -Path $root
                while ($fill -and $fill.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                    $cache[$fill] = $root
                    if ($fill.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
                    $parent = Split-Path -Parent $fill
                    if (-not $parent -or $parent -eq $fill) { break }
                    $fill = $parent
                }
            } else {
                $cache[$dir] = $null
            }
        }
        if (-not $root) { continue }
        if (-not $map.ContainsKey($root)) {
            $map[$root] = New-Object 'System.Collections.Generic.List[string]'
        }
        [void]$map[$root].Add($f)
    }
    return $map
}

function Invoke-TypesetterNative {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [int]$MaxChars = 8000
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $resolved = Get-Command -Name $FilePath -ErrorAction SilentlyContinue
        if (-not $resolved) {
            return [pscustomobject]@{
                ExitCode = 127
                Output   = ("Executable not found: {0}" -f $FilePath)
            }
        }
        $sb = New-Object System.Text.StringBuilder
        $truncated = $false
        & $FilePath @ArgumentList 2>&1 | ForEach-Object {
            $line = "$_"
            $remain = $MaxChars - $sb.Length
            if ($remain -le 0) {
                $truncated = $true
            } elseif ($line.Length -ge $remain) {
                [void]$sb.Append($line.Substring(0, $remain))
                $truncated = $true
            } else {
                [void]$sb.AppendLine($line)
            }
        }
        $output = $sb.ToString()
        if ($truncated) {
            $output = $output + '... (output truncated)'
        }
        return [pscustomobject]@{
            ExitCode = [int]$LASTEXITCODE
            Output   = $output
        }
    } finally {
        $ErrorActionPreference = $prev
    }
}

function Resolve-TypesetterLocalJsTool {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $bin = Join-Path $RepoRoot 'node_modules\.bin'
    foreach ($candidate in @(
            (Join-Path $bin "$Name.cmd"),
            (Join-Path $bin "$Name.ps1"),
            (Join-Path $bin $Name)
        )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}
