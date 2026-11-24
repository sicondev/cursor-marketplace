param(
  [Parameter(Mandatory)][string]$Table,
  [Parameter(Mandatory)][string]$Namespace,
  [Parameter(Mandatory)][string]$OutFile,
  [string]$ClassName,
  [string]$Server = '.\SQL2022',
  [string]$Database = 'Sage200_DemoData',
  [string[]]$Exclude = @('OpLock', 'Spare*'),
  [string]$AssemblyPath,
  [switch]$NoUserDataTypes,
  [switch]$Force
)

# Drafts a view spec for gen-view.ps1 / gen-collection.ps1 / gen-model.ps1 from the live table:
#   - one entry per column in table order, with its kind, nullability and length
#   - decimals get their UserDataType from Sage's persistent class (via Get-SagePersistentFields.ps1)
#   - every foreign key becomes a key (nullable or not); a foreign key to a lookup table with a Name column also
#     gets a joined <Key>Name field and a join (inner when NOT NULL, left outer otherwise; aliased when the table is
#     already joined)
#   - anything it can't decide is marked "# TODO" - review the draft before generating
# Excluded columns (default OpLock and Spare*) are left out and listed in Remarks.

$ErrorActionPreference = 'Stop'
if ($Table -notmatch '^\w+$') { throw "Table must be a plain table name: $Table" }
if (-not $ClassName) { $ClassName = "$($Table)View" }
if ((Test-Path $OutFile) -and -not $Force) { throw "$OutFile exists - pass -Force to overwrite" }

function Invoke-SqlRows([string]$query) {
  $out = & sqlcmd -S $Server -d $Database -E -W -h -1 -s '|' -Q "SET NOCOUNT ON; $query"
  if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed ($LASTEXITCODE) for: $query" }
  $out | Where-Object { $_ -and $_.Trim() } | ForEach-Object { , ($_.Trim() -split '\|') }
}

function Words([string]$name) {
  # SOPOrderReturnLineID -> SOP order return line; DateTimeCreated -> date time created
  $w = ($name -creplace 'ID$', '') -creplace '([a-z0-9])([A-Z])', '$1 $2' -creplace '([A-Z]+)([A-Z][a-z])', '$1 $2'
  ($w -split ' ' | ForEach-Object { if ($_ -cmatch '^[A-Z][a-z]') { $_.ToLower() } else { $_ } }) -join ' '
}
function Q([string]$s) { "'" + ($s -replace "'", "''") + "'" }

$columns = Invoke-SqlRows "SELECT COLUMN_NAME, DATA_TYPE, ISNULL(CHARACTER_MAXIMUM_LENGTH, 0), ISNULL(NUMERIC_PRECISION, 0), ISNULL(NUMERIC_SCALE, 0), IS_NULLABLE FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$Table' ORDER BY ORDINAL_POSITION" |
  ForEach-Object { [pscustomobject]@{ Name = $_[0]; Type = $_[1]; Length = [int]$_[2]; Precision = [int]$_[3]; Scale = [int]$_[4]; Nullable = $_[5] -eq 'YES' } }
if (-not $columns) { throw "Table $Table not found in $Database" }

$pk = (Invoke-SqlRows "SELECT COL_NAME(ic.object_id, ic.column_id) FROM sys.indexes i JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id WHERE i.is_primary_key = 1 AND i.object_id = OBJECT_ID('dbo.$Table')" | Select-Object -First 1)[0]
if (-not $pk) { $pk = $columns[0].Name }

$fks = @{}
Invoke-SqlRows "SELECT COL_NAME(fc.parent_object_id, fc.parent_column_id), OBJECT_NAME(fc.referenced_object_id), COL_NAME(fc.referenced_object_id, fc.referenced_column_id) FROM sys.foreign_key_columns fc WHERE fc.parent_object_id = OBJECT_ID('dbo.$Table')" |
  ForEach-Object { $fks[$_[0]] = [pscustomobject]@{ Table = $_[1]; Column = $_[2] } }

# Name column of each referenced table, if it has one
$nameColumns = @{}
foreach ($ref in ($fks.Values.Table | Sort-Object -Unique)) {
  $n = Invoke-SqlRows "SELECT COLUMN_NAME, CHARACTER_MAXIMUM_LENGTH FROM INFORMATION_SCHEMA.COLUMNS WHERE TABLE_NAME = '$ref' AND COLUMN_NAME = 'Name' AND DATA_TYPE IN ('varchar','nvarchar','char')" | Select-Object -First 1
  if ($n) { $nameColumns[$ref] = [int]$n[1] }
}

$userDataTypes = @{}
if (-not $NoUserDataTypes) {
  $script = Join-Path $PSScriptRoot 'Get-SagePersistentFields.ps1'
  $psArgs = @('-NoProfile', '-File', $script, '-Table', $Table, '-Json')
  if ($AssemblyPath) { $psArgs += @('-AssemblyPath', $AssemblyPath) }
  # A separate process, so the Sage assemblies are not loaded (and locked) in this one
  $json = & powershell.exe @psArgs 2>$null
  if ($LASTEXITCODE -eq 0 -and $json) {
    ($json | ConvertFrom-Json) | ForEach-Object { if ($_.UserDataType) { $userDataTypes[$_.Name] = $_.UserDataType } }
  }
  else { Write-Warning "No persistent class for $Table - decimals get DbType metadata and a TODO" }
}

$excluded = @($columns | Where-Object { $c = $_.Name; $Exclude | Where-Object { $c -like $_ } } | ForEach-Object Name)
$columnNames = @($columns.Name)
$entries = [Collections.Generic.List[string]]::new()
$joins = [Collections.Generic.List[string]]::new()
$joinedTables = @{}
$todo = 0

foreach ($c in $columns) {
  if ($excluded -contains $c.Name) { continue }
  $name = $c.Name; $words = Words $name; $null_ = $c.Nullable

  if ($name -eq $pk) {
    $entries.Add(",@($(Q $Table),'pk',""ColumnName = """"$name"""", IsReadOnly = true, AllowOverwrite = AllowOverwriteType.Equal, IsPrimaryKey = true, IsIndexed = true, IsUnique = true, `$k"",$(Q "The $(Words $Table) primary key ($Table.$name)."))")
    continue
  }

  if ($name -in 'DateTimeCreated', 'DateTimeUpdated') {
    $what = if ($name -eq 'DateTimeCreated') { 'created' } else { 'last updated' }
    $entries.Add(",@($(Q $name),'dateRO','IsReadOnly = true, DbType = DbType.DateTime',$(Q "The date and time the row was $what."))")
    continue
  }

  switch ($c.Type) {
    { $_ -in 'varchar', 'nvarchar', 'char', 'nchar' } {
      $len = if ($c.Length -lt 0) { 2147483647 } else { $c.Length }
      $flag = if ($null_) { ' -Nullable' } else { '' }
      $doc = if ($null_) { "The $words; null if not set." } else { "The $words." }
      $entries.Add(",(S $(Q $name) $len $(Q $doc)$flag)")
    }
    'bigint' {
      $fk = $fks[$name]
      if ($fk -or $name -cmatch 'ID$') {
        $base = $name -creplace 'ID$', ''
        if ($base -eq $name) { $base = $name }
        $target = if ($fk) { " -> $($fk.Table)" } else { '' }
        $helper = if ($null_) { 'NKey' } else { 'Key' }
        $entries.Add(",($helper $(Q $base) $(Q $name) $(Q "The $words ($Table.$name$target)."))")
        if (-not $fk) {
          $entries.Add("  # TODO: $name has no foreign key - if you join it, join left outer")
          $todo++
        }
        elseif ($fk.Table -eq $Table) {
          $entries.Add("  # TODO: self-join on $name - join $Table with a RightAlias if you want its columns")
          $todo++
        }
        elseif ($nameColumns.ContainsKey($fk.Table)) {
          $alias = $null
          if ($joinedTables.ContainsKey($fk.Table)) { $alias = $base }
          $source = if ($alias) { $alias } else { $fk.Table }
          $fieldName = "$($base)Name"
          if ($columnNames -contains $fieldName) { $fieldName = "$($base)LookupName" }
          $inner = (-not $null_)
          $nflag = if ($inner) { '' } else { ' -Nullable' }
          $doc = "The $words name, joined from $($fk.Table).Name" + $(if ($alias) { " (aliased $alias)" } else { '' }) + $(if ($inner) { '.' } else { '; null when not set.' })
          $entries.Add(",(J $(Q $fieldName) $(Q $source) 'Name' $($nameColumns[$fk.Table]) $(Q $doc)$nflag)")
          $type = if ($inner) { 'Inner' } else { 'LeftOuter' }
          $aliasPart = if ($alias) { "; RightAlias = $(Q $alias)" } else { '' }
          $joins.Add(",@{ Left = $(Q $Table); Right = $(Q $fk.Table); LeftColumn = $(Q $name); RightColumn = $(Q $fk.Column); Type = '$type'$aliasPart }")
          $joinedTables[$fk.Table] = $true
        }
        else {
          $type = if ($null_) { 'LeftOuter' } else { 'Inner' }
          $entries.Add("  # TODO: join $($fk.Table) ($type) and add its code / name / description columns with J entries, or leave it as an id")
          $todo++
        }
      }
      else {
        $kind = if ($null_) { 'longNullable' } else { 'long' }
        $nullable = if ($null_) { 'IsNullable = true, ' } else { '' }
        $entries.Add(",@($(Q $name),'$kind','$($nullable)DbType = DbType.Int64, Precision = 19, Scale = 0, FormatScale = 0',$(Q "The $words."))")
      }
    }
    'int' {
      $helper = if ($null_) { 'NI' } else { 'I' }
      $entries.Add(",($helper $(Q $name) $(Q "The $words."))")
    }
    'smallint' {
      $helper = if ($null_) { 'NSh' } else { 'Sh' }
      $entries.Add(",($helper $(Q $name) $(Q "The $words."))")
    }
    'bit' {
      $helper = if ($null_) { 'NB' } else { 'B' }
      $entries.Add(",($helper $(Q $name) $(Q "Whether $words."))")
    }
    { $_ -in 'datetime', 'datetime2', 'date', 'smalldatetime' } {
      if ($null_) { $entries.Add(",(ND $(Q $name) $(Q "The $words; null if not set."))") }
      else { $entries.Add(",(Dt $(Q $name) $(Q "The $words."))") }
    }
    { $_ -in 'decimal', 'numeric', 'money' } {
      if ($null_) { $entries.Add("  # TODO: $name is a nullable decimal - no generator kind for it yet"); $todo++ }
      $udt = $userDataTypes[$name]
      if ($udt) { $entries.Add(",(D $(Q $name) $(Q $udt) $(Q "The $words."))") }
      else {
        $entries.Add(",@($(Q $name),'decimal','DbType = DbType.Decimal, Precision = $($c.Precision), Scale = $($c.Scale)',$(Q "The $words."))  # TODO: UserDataType unknown")
        $todo++
      }
    }
    default {
      $entries.Add("  # TODO: $name ($($c.Type)) has no generator kind - left out")
      $todo++
    }
  }
}

$remarks = "Leaves out $($excluded -join ', ')."
$sb = [Text.StringBuilder]::new()
function L([string]$s = '') { [void]$sb.AppendLine($s) }
L "# Draft from $Database.$Table by New-SageViewSpec.ps1 - review the TODOs, docs and joins before generating."
L '$k = ''DbType = DbType.Int64, Precision = 19, Scale = 0, FormatScale = 0'''
L 'function S($name, $len, $doc, [switch]$Nullable) { $n = if ($Nullable) { ''IsNullable = true, '' } else { '''' }; ,@($name, ''string'', "$($n)DbType = DbType.AnsiString, Precision = $len", $doc) }'
L 'function Key($name, $column, $doc) { ,@("$($name)DbKey", ''key'', "FieldPropertyName = ""_$name"", ColumnName = ""$column"", IsIndexed = true, $k", $doc) }'
L 'function NKey($name, $column, $doc) { ,@("$($name)DbKey", ''keyNullable'', "FieldPropertyName = ""_$name"", ColumnName = ""$column"", IsNullable = true, IsIndexed = true, $k", $doc) }'
L 'function J($name, $table, $column, $len, $doc, [switch]$Nullable) { $n = if ($Nullable) { ''IsNullable = true, '' } else { '''' }; ,@($name, ''joined'', "FieldPropertyName = ""_$name"", ColumnName = ""$column"", TableName = ""$table"", IsReadOnly = true, $($n)DbType = DbType.AnsiString, Precision = $len", $doc) }'
L 'function D($name, $udt, $doc) { ,@($name, ''decimal'', "UserDataType = ""$udt""", $doc) }'
L 'function I($name, $doc) { ,@($name, ''int'', ''DbType = DbType.Int32, Precision = 10, Scale = 0, FormatScale = 0'', $doc) }'
L 'function NI($name, $doc) { ,@($name, ''intNullable'', ''IsNullable = true, DbType = DbType.Int32, Precision = 10, Scale = 0, FormatScale = 0'', $doc) }'
L 'function Sh($name, $doc) { ,@($name, ''short'', ''DbType = DbType.Int16, Precision = 5, Scale = 0, FormatScale = 0'', $doc) }'
L 'function NSh($name, $doc) { ,@($name, ''shortNullable'', ''IsNullable = true, DbType = DbType.Int16, Precision = 5, Scale = 0, FormatScale = 0'', $doc) }'
L 'function B($name, $doc) { ,@($name, ''bool'', ''DbType = DbType.Boolean'', $doc) }'
L 'function NB($name, $doc) { ,@($name, ''boolNullable'', ''IsNullable = true, DbType = DbType.Boolean'', $doc) }'
L 'function Dt($name, $doc) { ,@($name, ''date'', ''DbType = DbType.DateTime'', $doc) }'
L 'function ND($name, $doc) { ,@($name, ''dateNullable'', ''IsNullable = true, DbType = DbType.DateTime'', $doc) }'
L ''
L '# Every entry starts with a comma so PowerShell keeps it as one item instead of flattening it into the list'
L '$cols = @('
foreach ($e in $entries) { L "  $e" }
L ')'
L ''
L '# Inner only when the column is NOT NULL and has a foreign key; a table joined twice needs a RightAlias,'
L '# and the joined fields then use the alias as their TableName'
L '$joins = @('
foreach ($j in $joins) { L "  $j" }
L ')'
L ''
L '@{'
L "  Namespace = $(Q $Namespace)"
L "  ClassName = $(Q $ClassName)"
L "  Table = $(Q $Table)"
L "  KeyColumn = $(Q $pk)"
L "  Summary = $(Q "Read view over <c>$Table</c>, joined to its lookup tables for their names.")"
L "  Remarks = $(Q $remarks)"
L '  Columns = $cols'
L '  Joins = $joins'
L '}'

New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
[IO.File]::WriteAllText($OutFile, $sb.ToString().Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
"wrote $OutFile ($($entries.Count) lines, $($joins.Count) joins, $todo TODOs, excluded: $($excluded -join ', '))"
