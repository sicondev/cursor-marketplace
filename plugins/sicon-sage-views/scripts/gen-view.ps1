param(
  [Parameter(Mandatory)][string]$SpecFile,
  [Parameter(Mandatory)][string]$OutFile
)

# Generates a Sage 200 ObjectStore read view (one class per table row) from a spec file.
# Spec file returns @{ Namespace; ClassName; Table; KeyColumn; Summary; Remarks; Columns = @( @(Name, Kind, MetaDataArgs, Summary), ... ); Joins }
#   Kind: pk, key, keyNullable, string, int, intNullable, short, shortNullable, long, longNullable, decimal,
#         bool, boolNullable, date, dateRO, dateNullable, joined, joinedShort, joinedInt, joinedDate
# Joins are used by gen-collection.ps1, not here.
$spec = & $SpecFile
$cols = $spec.Columns

function BackingField($c) {
  if ($c[2] -match 'FieldPropertyName = "(_\w+)"') { return $matches[1] }
  return "_$($c[0])"
}

$dupes = $cols | ForEach-Object { BackingField $_ } | Group-Object | Where-Object Count -gt 1
if ($dupes) { throw "Duplicate backing fields: $($dupes.Name -join ', ') - set a distinct FieldPropertyName" }
$dupeNames = $cols | ForEach-Object { $_[0] } | Group-Object | Where-Object Count -gt 1
if ($dupeNames) { throw "Duplicate property names: $($dupeNames.Name -join ', ')" }

$sb = [Text.StringBuilder]::new()
function L([string]$s = '') { [void]$sb.AppendLine($s) }

'Sage.Accounting','Sage.Common.Data','Sage.Common.DataAccess','Sage.ObjectStore','Sage.ObjectStore.Builder','Sage.ObjectStore.CompoundKeys','System','System.ComponentModel','System.Data','System.Runtime.Serialization' | ForEach-Object { L "using $_;" }
L ''
L "namespace $($spec.Namespace)"
L '{'
L '    /// <summary>'
L "    /// $($spec.Summary)"
L '    /// </summary>'
if ($spec.Remarks) { L '    /// <remarks>'; L "    /// $($spec.Remarks)"; L '    /// </remarks>' }
L '    [DataContract(IsReference = true, Namespace = "http://schemas.sage.com/sage200/2011/")]'
L "    [CompoundKeyField(CompoundKeyName = ""CK1"", FieldName = ""$($spec.KeyColumn)"", Precedence = 0)]"
L "    [PersistentObject(TableName = ""$($spec.Table)"")]"
L '    [CompoundKey(IsDefault = Default.IsDefault, IsIndexed = Indexed.IsIndexed, IsUnique = Unique.IsUnique, Name = "CK1")]'
L "    public class $($spec.ClassName) : View"
L '    {'
foreach ($c in $cols) {
  L "        /// <summary>ObjectStore field name for <see cref=""$($c[0])""/>.</summary>"
  L "        public const string FIELD_$($c[0].ToUpper()) = ""$($c[0])"";"
  L "        /// <summary>ObjectStore backing field.</summary>"
  L "        protected Sage.ObjectStore.Field $(BackingField $c);"
}
foreach ($c in $cols) {
  $name = $c[0]; $kind = $c[1]; $bf = BackingField $c
  L ''
  L '        /// <summary>'
  L "        /// $($c[3])"
  L '        /// </summary>'
  L '        [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]'
  L "        [MetaDataField($($c[2]))]"
  switch ($kind) {
    'pk'            { L "        public virtual DbKey $name => this.$bf.GetDbKey();" }
    'dateRO'        { L "        public virtual DateTime $name => this.$bf.GetDateTime();" }
    'joined'        { L "        public virtual string $name => this.$bf.GetString();" }
    'dateNullable'  { L "        public virtual DateTime? $name => this.$bf.IsNull ? (DateTime?)null : this.$bf.GetDateTime();" }
    'joinedInt'     { L "        public virtual int? $name => this.$bf.IsNull ? (int?)null : this.$bf.GetInt32();" }
    'joinedDate'    { L "        public virtual DateTime? $name => this.$bf.IsNull ? (DateTime?)null : this.$bf.GetDateTime();" }
    'joinedShort'   { L "        public virtual short? $name => this.$bf.IsNull ? (short?)null : this.$bf.GetInt16();" }
    'shortNullable' { L "        public virtual short? $name => this.$bf.IsNull ? (short?)null : this.$bf.GetInt16();" }
    'intNullable'   { L "        public virtual int? $name => this.$bf.IsNull ? (int?)null : this.$bf.GetInt32();" }
    'longNullable'  { L "        public virtual long? $name => this.$bf.IsNull ? (long?)null : this.$bf.GetInt64();" }
    'boolNullable'  { L "        public virtual bool? $name => this.$bf.IsNull ? (bool?)null : this.$bf.GetBoolean();" }
    'keyNullable' {
      # DbKey property plus a long? id. Null-ness comes from the field, NOT DbKey.IsNull, which is also true for id 0.
      $idName = ($name -replace 'DbKey$','') + 'ID'
      L "        public virtual DbKey $name"
      L '        {'
      L "            get => this.$bf.GetDbKey();"
      L "            set => this.$bf.Value = (object)value;"
      L '        }'
      L ''
      L '        /// <summary>'
      L "        /// The id of <see cref=""$name""/>, or null when the column is NULL."
      L '        /// </summary>'
      L '        /// <remarks>Use this rather than <see cref="DbKey.IsNull"/>, which is also true for a valid id of 0.</remarks>'
      L "        public virtual long? $idName => this.$bf.IsNull ? (long?)null : (long)this.$bf.GetDbKey();"
    }
    default {
      $type, $getter = switch ($kind) { 'key' { 'DbKey','GetDbKey' } 'string' { 'string','GetString' } 'int' { 'int','GetInt32' } 'short' { 'short','GetInt16' } 'long' { 'long','GetInt64' } 'decimal' { 'Decimal','GetDecimal' } 'bool' { 'bool','GetBoolean' } 'date' { 'DateTime','GetDateTime' } }
      if (-not $type) { throw "Unknown kind '$kind' for $name" }
      L "        public virtual $type $name"
      L '        {'
      L "            get => this.$bf.$getter();"
      L "            set => this.$bf.Value = (object)value;"
      L '        }'
    }
  }
}
L '    }'
L '}'

New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
[IO.File]::WriteAllText($OutFile, $sb.ToString().Replace("`r`n","`n").TrimEnd("`n") + "`n", [Text.UTF8Encoding]::new($false))
"wrote $OutFile ($($cols.Count) columns)"
