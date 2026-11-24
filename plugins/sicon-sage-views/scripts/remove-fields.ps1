param(
  [Parameter(Mandatory)][string[]]$Names,
  [Parameter(Mandatory)][string]$ViewFile,
  [string]$ModelFile,
  [string]$MappingFile,
  [string]$SpecFile
)
# Removes simple (non-joined) fields from a generated view and, when given, its model, the file holding the
# "Name = source.Name," mapping (e.g. a service's ConvertOne) and the spec.
# Use it when generated files have been hand-edited; otherwise delete the spec entries and regenerate.
# Every pattern must match exactly once; nothing is written unless all of them do.

function RemoveOnce([string]$text, [string]$pattern, [string]$what) {
  $m = [regex]::Matches($text, $pattern)
  if ($m.Count -ne 1) { throw "$what : expected 1 match, found $($m.Count)" }
  return $text.Remove($m[0].Index, $m[0].Length)
}

$view = [IO.File]::ReadAllText($ViewFile)
$model = if ($ModelFile) { [IO.File]::ReadAllText($ModelFile) }
$mapping = if ($MappingFile) { [IO.File]::ReadAllText($MappingFile) }
$nl = '\r?\n'

foreach ($n in $Names) {
  $e = [regex]::Escape($n)
  # const + backing field
  $view = RemoveOnce $view "        /// <summary>ObjectStore field name for <see cref=""$e""/>\.</summary>$nl        public const string FIELD_\w+ = ""$e"";$nl        /// <summary>ObjectStore backing field\.</summary>$nl        protected Sage\.ObjectStore\.Field _\w+;$nl" "view const/field $n"
  # property: doc comment, attributes, then either an expression body or a get/set block, then a blank line
  $view = RemoveOnce $view "        /// <summary>$nl(?:        ///[^\r\n]*$nl)+(?:        \[[^\r\n]*$nl)+        public virtual [\w\?\.<>]+ $e(?: =>[^\r\n]*$nl|$nl        \{$nl(?:            [^\r\n]*$nl)+?        \}$nl)$nl" "view property $n"
  if ($ModelFile) {
    $model = RemoveOnce $model "        /// <summary>$nl(?:        ///[^\r\n]*$nl)+        \[JsonProperty\(""[^""]+""\)\]$nl        public [\w\?\.<>]+ $e \{ get; set; \}$nl$nl" "model property $n"
  }
  if ($MappingFile) {
    $mapping = RemoveOnce $mapping "[ \t]*$e = \w+\.\w+,$nl" "mapping $n"
  }
}

[IO.File]::WriteAllText($ViewFile, $view)
if ($ModelFile) { [IO.File]::WriteAllText($ModelFile, $model) }
if ($MappingFile) { [IO.File]::WriteAllText($MappingFile, $mapping) }
"removed: $($Names -join ', ')"

if ($SpecFile -and (Test-Path $SpecFile)) {
  $lines = Get-Content $SpecFile
  $pattern = "'(" + (($Names | ForEach-Object { [regex]::Escape($_) }) -join '|') + ")'"
  $kept = $lines | Where-Object { $_ -notmatch $pattern }
  Set-Content $SpecFile $kept
  "spec: removed $($lines.Count - $kept.Count) lines"
}
