param(
  [Parameter(Mandatory)][string]$Table,
  [string]$AssemblyPath,
  [switch]$Json
)

# Lists the fields of Sage's persistent class for a table (Sage.Accounting.Persistent<Table>), with each field's
# .NET type and UserDataType. Use it only for the UserDataType of decimals (MonetaryBalance2dp, Percentage2dp,
# ExchangeRate, ...): the class is older than the database, so trust the database for columns and lengths.
#
# Sage.Accounting.PersistentObjects.dll is found in the NuGet cache (sage200c.objects, newest version) unless
# -AssemblyPath is given. Run in a separate PowerShell process: loading Sage assemblies locks them.

if (-not $AssemblyPath) {
  $root = Join-Path $env:USERPROFILE '.nuget\packages\sage200c.objects'
  $AssemblyPath = Get-ChildItem $root -Recurse -Filter 'Sage.Accounting.PersistentObjects.dll' -ErrorAction SilentlyContinue |
    Sort-Object { [version]($_.FullName -replace '.*sage200c\.objects\\([\d\.]+)\\.*','$1') } -Descending |
    Select-Object -First 1 -ExpandProperty FullName
  if (-not $AssemblyPath) { throw "Sage.Accounting.PersistentObjects.dll not found under $root - pass -AssemblyPath" }
}
$dir = Split-Path $AssemblyPath
[AppDomain]::CurrentDomain.add_AssemblyResolve({
  param($s, $e)
  $f = Join-Path $dir ((($e.Name -split ',')[0]) + '.dll')
  if (Test-Path $f) { [Reflection.Assembly]::LoadFrom($f) }
}.GetNewClosure())

$assembly = [Reflection.Assembly]::LoadFrom($AssemblyPath)
$type = $assembly.GetType("Sage.Accounting.Persistent$Table")
if (-not $type) { throw "Sage.Accounting.Persistent$Table not found in $AssemblyPath" }

$fields = foreach ($p in $type.GetProperties()) {
  $meta = $p.GetCustomAttributes($true) | Where-Object { $_.GetType().Name -eq 'MetaDataFieldAttribute' } | Select-Object -First 1
  if ($meta) {
    [pscustomobject]@{ Name = $p.Name; Type = $p.PropertyType.Name; UserDataType = $meta.UserDataType; ColumnName = $meta.ColumnName }
  }
}

if ($Json) { $fields | ConvertTo-Json -Compress }
else {
  "Persistent class: $($type.FullName) ($AssemblyPath)"
  $fields | Format-Table -AutoSize | Out-String -Width 200
}
