param(
  [Parameter(Mandatory)][string]$Table,
  [string]$Server = '.\SQL2022',
  [string]$Database = 'Sage200_DemoData',
  [int]$LookupRowLimit = 30
)

# Prints what you need to write a view spec, read from the live database (Sage's DLL metadata is older than
# the database: it misses columns and has wrong lengths):
#   - columns in table order, with type, length and nullability
#   - foreign keys
#   - NULL counts for every nullable column
#   - the rows of each small lookup table a foreign key points at, to pick its code / name / description columns
# Uses Windows authentication through sqlcmd.

function Invoke-Sql([string]$query) {
  & sqlcmd -S $Server -d $Database -E -W -s '|' -Q "SET NOCOUNT ON; $query"
  if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed ($LASTEXITCODE) for: $query" }
}

function Invoke-SqlValues([string]$query) {
  & sqlcmd -S $Server -d $Database -E -W -h -1 -s '|' -Q "SET NOCOUNT ON; $query" | Where-Object { $_ -and $_ -notmatch '^\s*$' }
}

if ($Table -notmatch '^\w+$') { throw "Table must be a plain table name: $Table" }

"== Columns: $Table =="
Invoke-Sql "SELECT c.COLUMN_NAME, c.DATA_TYPE, c.CHARACTER_MAXIMUM_LENGTH AS LEN, c.NUMERIC_PRECISION AS PREC, c.NUMERIC_SCALE AS SCALE, c.IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME = '$Table' ORDER BY c.ORDINAL_POSITION"

"`n== Primary key =="
Invoke-Sql "SELECT COL_NAME(ic.object_id, ic.column_id) AS COLUMN_NAME FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID('dbo.$Table')"

"`n== Row count =="
Invoke-Sql "SELECT COUNT(*) AS ROWS FROM dbo.[$Table]"

"`n== Foreign keys =="
$fkQuery = "SELECT COL_NAME(fc.parent_object_id, fc.parent_column_id) AS COL, OBJECT_NAME(fc.referenced_object_id) AS REF_TABLE, COL_NAME(fc.referenced_object_id, fc.referenced_column_id) AS REF_COLUMN FROM sys.foreign_keys fk JOIN sys.foreign_key_columns fc ON fc.constraint_object_id = fk.object_id WHERE fk.parent_object_id = OBJECT_ID('dbo.$Table') ORDER BY COL"
Invoke-Sql $fkQuery

$nullable = Invoke-SqlValues "SELECT COLUMN_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$Table' AND IS_NULLABLE = 'YES' AND DATA_TYPE NOT IN ('timestamp','image','text','ntext','varbinary') ORDER BY ORDINAL_POSITION"
if ($nullable) {
  "`n== NULL counts (nullable columns) =="
  $sums = ($nullable | ForEach-Object { $c = $_.Trim(); "SUM(CASE WHEN [$c] IS NULL THEN 1 ELSE 0 END) AS [$c]" }) -join ', '
  Invoke-Sql "SELECT $sums FROM dbo.[$Table]"
}

"`n== Id columns without a foreign key (join these left outer if you join them at all) =="
Invoke-Sql "SELECT c.COLUMN_NAME, c.IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS c WHERE c.TABLE_NAME = '$Table' AND c.DATA_TYPE = 'bigint' AND c.COLUMN_NAME LIKE '%ID' AND c.ORDINAL_POSITION > 1 AND NOT EXISTS (SELECT 1 FROM sys.foreign_key_columns fc WHERE fc.parent_object_id = OBJECT_ID('dbo.$Table') AND COL_NAME(fc.parent_object_id, fc.parent_column_id) = c.COLUMN_NAME) ORDER BY c.ORDINAL_POSITION"

$refs = Invoke-SqlValues "SELECT DISTINCT OBJECT_NAME(fc.referenced_object_id) FROM sys.foreign_key_columns fc WHERE fc.parent_object_id = OBJECT_ID('dbo.$Table')"
foreach ($ref in $refs) {
  $ref = $ref.Trim()
  if ($ref -eq $Table) { continue }
  $count = [int]((Invoke-SqlValues "SELECT COUNT(*) FROM dbo.[$ref]") | Select-Object -First 1)
  "`n== Lookup $ref ($count rows) =="
  if ($count -le $LookupRowLimit) {
    # Every column except OpLock (timestamp), which is just noise here
    $select = (Invoke-SqlValues "SELECT QUOTENAME(COLUMN_NAME) FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$ref' AND DATA_TYPE <> 'timestamp' ORDER BY ORDINAL_POSITION" | ForEach-Object { $_.Trim() }) -join ', '
    Invoke-Sql "SELECT $select FROM dbo.[$ref]"
  }
  else {
    $text = (Invoke-SqlValues "SELECT COLUMN_NAME + '(' + CAST(CHARACTER_MAXIMUM_LENGTH AS varchar) + ')' FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$ref' AND DATA_TYPE IN ('varchar','nvarchar','char','nchar') AND COLUMN_NAME NOT LIKE 'Spare%' AND COLUMN_NAME NOT LIKE 'AnalysisCode%' ORDER BY ORDINAL_POSITION" | ForEach-Object { $_.Trim() }) -join ', '
    "Not a fixed lookup. Text columns (code / name candidates): $text"
  }
}
