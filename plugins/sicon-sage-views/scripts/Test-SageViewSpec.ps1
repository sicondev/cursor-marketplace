param(
  [Parameter(Mandatory)][string]$SpecFile,
  [string]$Server = '.\SQL2022',
  [string]$Database = 'Sage200_DemoData'
)

# Checks a view spec against the live database before generating:
#   - every table column is in the spec or listed as left out in Remarks; nothing in the spec is missing from the table
#   - nullable columns are nullable in the spec, and string lengths match
#   - every joined field's column exists in its table (or the aliased table)
#   - nullable or foreign-key-less joins are not inner joins
# Exits 1 if anything is wrong.

$ErrorActionPreference = 'Stop'
$spec = & $SpecFile
$problems = [Collections.Generic.List[string]]::new()

function Invoke-SqlRows([string]$query) {
  $out = & sqlcmd -S $Server -d $Database -E -W -h -1 -s '|' -Q "SET NOCOUNT ON; $query"
  if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed ($LASTEXITCODE) for: $query" }
  $out | Where-Object { $_ -and $_.Trim() } | ForEach-Object { , ($_.Trim() -split '\|') }
}
function Columns([string]$table) {
  $h = @{}
  Invoke-SqlRows "SELECT COLUMN_NAME, ISNULL(CHARACTER_MAXIMUM_LENGTH, 0), IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$table'" |
    ForEach-Object { $h[$_[0]] = [pscustomobject]@{ Length = [int]$_[1]; Nullable = $_[2] -eq 'YES' } }
  $h
}

$table = Columns $spec.Table
if ($table.Count -eq 0) { throw "Table $($spec.Table) not found in $Database" }

$joins = @($spec.Joins | Where-Object { $_ })
$aliasTables = @{}
foreach ($j in $joins) { $aliasTables[$(if ($j.RightAlias) { $j.RightAlias } else { $j.Right })] = $j.Right }

$specColumns = @{}
foreach ($c in $spec.Columns) {
  $meta = $c[2]
  if ($meta -match 'TableName = "(\w+)"') {
    $source = $matches[1]
    $real = $aliasTables[$source]
    if (-not $real) { $problems.Add("$($c[0]): no join provides table '$source'"); continue }
    $column = if ($meta -match 'ColumnName = "(\w+)"') { $matches[1] } else { $c[0] }
    $other = Columns $real
    if (-not $other.ContainsKey($column)) { $problems.Add("$($c[0]): $real has no column $column") }
    $join = $joins | Where-Object { $(if ($_.RightAlias) { $_.RightAlias } else { $_.Right }) -eq $source } | Select-Object -First 1
    if ($join.Type -eq 'LeftOuter' -and $meta -notmatch 'IsNullable = true') { $problems.Add("$($c[0]): joined left outer, so it should be IsNullable = true (-Nullable)") }
    continue
  }
  $column = if ($meta -match 'ColumnName = "(\w+)"') { $matches[1] } else { $c[0] }
  $specColumns[$column] = $c
  if (-not $table.ContainsKey($column)) { $problems.Add("$($c[0]): table has no column $column"); continue }
  $db = $table[$column]
  $nullableInSpec = $meta -match 'IsNullable = true'
  if ($db.Nullable -and -not $nullableInSpec -and $c[1] -notin 'pk') { $problems.Add("$($c[0]): column is nullable but the spec entry is not") }
  if (-not $db.Nullable -and $nullableInSpec) { $problems.Add("$($c[0]): spec entry is nullable but the column is NOT NULL (fine, but check)") }
  if ($c[1] -eq 'string' -and $meta -match 'Precision = (\d+)') {
    $expected = if ($db.Length -lt 0) { 2147483647 } else { $db.Length }
    if ([int]$matches[1] -ne $expected) { $problems.Add("$($c[0]): length $($matches[1]) but the column is $expected") }
  }
}

$leftOut = @($table.Keys | Where-Object { -not $specColumns.ContainsKey($_) })
$notMentioned = @($leftOut | Where-Object { $spec.Remarks -notmatch "\b$_\b" -and -not ($_ -like 'Spare*' -and $spec.Remarks -match 'Spare') })
foreach ($n in $notMentioned) { $problems.Add("$n is in the table but not in the spec or its Remarks") }

$fks = @{}
Invoke-SqlRows "SELECT COL_NAME(fc.parent_object_id, fc.parent_column_id), OBJECT_NAME(fc.referenced_object_id) FROM sys.foreign_key_columns fc WHERE fc.parent_object_id = OBJECT_ID('dbo.$($spec.Table)')" |
  ForEach-Object { $fks[$_[0]] = $_[1] }
foreach ($j in $joins | Where-Object { $_.Left -eq $spec.Table -and $_.Type -eq 'Inner' }) {
  $col = $table[$j.LeftColumn]
  if (-not $col) { $problems.Add("Join on $($j.LeftColumn): table has no such column"); continue }
  if ($col.Nullable) { $problems.Add("Join on $($j.LeftColumn) is inner but the column is nullable - rows with NULL would disappear; use LeftOuter") }
  if ($fks[$j.LeftColumn] -ne $j.Right) { $problems.Add("Join on $($j.LeftColumn) is inner but has no foreign key to $($j.Right) - use LeftOuter") }
}

"Spec: $($spec.Columns.Count) entries, $($joins.Count) joins; left out: $($leftOut -join ', ')"
if ($problems.Count) { $problems | ForEach-Object { "PROBLEM: $_" }; exit 1 }
'OK'
