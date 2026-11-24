param(
  [Parameter(Mandatory)][string]$SpecFile,
  [Parameter(Mandatory)][string]$ModelNamespace,
  [Parameter(Mandatory)][string]$ModelClass,
  [Parameter(Mandatory)][string]$ModelSummary,
  [Parameter(Mandatory)][string]$OutFile,
  [string]$MappingOutFile,
  [string]$SourceVar = 'view'
)

# Builds a JSON API model (Newtonsoft) and, optionally, the "Property = view.Property," mappings from the same
# spec as gen-view.ps1, so the model can't drift from the view.
# Naming: XID -> xId, leading acronyms lower-cased (SLCustomerAccountID -> slCustomerAccountId).
$spec = & $SpecFile

function JsonName([string]$n) {
  $n = $n -replace 'ID$','Id'
  if ($n -cmatch '^([A-Z]+)([A-Z][a-z].*)$') { return $matches[1].ToLower() + $matches[2] }
  if ($n -cmatch '^[A-Z]+$') { return $n.ToLower() }
  return $n.Substring(0,1).ToLower() + $n.Substring(1)
}

$props = foreach ($c in $spec.Columns) {
  $name = $c[0]; $kind = $c[1]; $doc = $c[3]
  switch ($kind) {
    'pk'            { @{ Type='long';      Name="$($name)ID";                   Src="$SourceVar.$name"; Doc=$doc } }
    'key'           { @{ Type='long';      Name=($name -replace 'DbKey$','ID'); Src="$SourceVar.$name"; Doc=$doc } }
    'keyNullable'   { $id = ($name -replace 'DbKey$','ID'); @{ Type='long?'; Name=$id; Src="$SourceVar.$id"; Doc="$doc Null when not set." } }
    'string'        { @{ Type='string';    Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'joined'        { @{ Type='string';    Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'int'           { @{ Type='int';       Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'intNullable'   { @{ Type='int?';      Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'short'         { @{ Type='short';     Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'shortNullable' { @{ Type='short?';    Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'long'          { @{ Type='long';      Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'longNullable'  { @{ Type='long?';     Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'joinedInt'     { @{ Type='int?';      Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'joinedShort'   { @{ Type='short?';    Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'joinedDate'    { @{ Type='DateTime?'; Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'decimal'       { @{ Type='decimal';   Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'bool'          { @{ Type='bool';      Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'boolNullable'  { @{ Type='bool?';     Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'date'          { @{ Type='DateTime';  Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'dateRO'        { @{ Type='DateTime';  Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    'dateNullable'  { @{ Type='DateTime?'; Name=$name; Src="$SourceVar.$name"; Doc=$doc } }
    default         { throw "Unknown kind '$kind' for $name" }
  }
}

$dupes = $props | ForEach-Object { $_.Name } | Group-Object | Where-Object Count -gt 1
if ($dupes) { throw "Duplicate model property names: $($dupes.Name -join ', ')" }

$sb = [Text.StringBuilder]::new()
[void]$sb.Append("using Newtonsoft.Json;`nusing System;`n`nnamespace $ModelNamespace`n{`n    /// <summary>`n    /// $ModelSummary`n    /// </summary>`n    public class $ModelClass`n    {`n")
$first = $true
foreach ($p in $props) {
  if (-not $first) { [void]$sb.Append("`n") }; $first = $false
  [void]$sb.Append("        /// <summary>`n        /// $($p.Doc)`n        /// </summary>`n        [JsonProperty(""$(JsonName $p.Name)"")]`n        public $($p.Type) $($p.Name) { get; set; }`n")
}
[void]$sb.Append("    }`n}`n")
New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
[IO.File]::WriteAllText($OutFile, $sb.ToString(), [Text.UTF8Encoding]::new($false))
"wrote $OutFile ($($props.Count) properties)"

if ($MappingOutFile) {
  $map = ($props | ForEach-Object { "                $($_.Name) = $($_.Src)," }) -join "`n"
  [IO.File]::WriteAllText($MappingOutFile, $map.TrimEnd(','), [Text.UTF8Encoding]::new($false))
  "wrote $MappingOutFile"
}
