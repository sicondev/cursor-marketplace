param(
  [Parameter(Mandatory)][string]$SpecFile,
  [Parameter(Mandatory)][string]$OutFile,
  [string]$CollectionClass
)

# Generates the ObjectStore view collection (<ClassName>s : ViewCollection) for a view spec:
# indexer, First, Owner, and Joins built from the spec's Joins list.
# Each join is @{ Left; Right; LeftColumn; RightColumn; Type = 'Inner' | 'LeftOuter'; RightAlias; LeftAlias }.
# A joined field's TableName must be the join's RightAlias when it has one, otherwise its Right table.
$spec = & $SpecFile
$view = $spec.ClassName
if (-not $CollectionClass) { $CollectionClass = "$($view)s" }
$joins = @($spec.Joins | Where-Object { $_ })

# Every joined field must point at a table or alias that is joined
$joinedNames = @($joins | ForEach-Object { if ($_.RightAlias) { $_.RightAlias } else { $_.Right } })
$aliasesAndTables = @($spec.Table) + $joinedNames + @($joins | ForEach-Object { $_.LeftAlias } | Where-Object { $_ })
foreach ($c in $spec.Columns) {
  if ($c[2] -match 'TableName = "(\w+)"' -and $aliasesAndTables -notcontains $matches[1]) {
    throw "Field $($c[0]) reads from '$($matches[1])', which no join provides"
  }
}
$dupes = $joinedNames | Group-Object | Where-Object Count -gt 1
if ($dupes) { throw "Joined more than once without an alias: $($dupes.Name -join ', ') - give the extra joins a RightAlias" }
foreach ($j in $joins) {
  if ($j.Type -notin 'Inner','LeftOuter') { throw "Join $($j.Left) -> $($j.Right): Type must be Inner or LeftOuter, not '$($j.Type)'" }
}

function Q([string]$s) { if ($s) { """$s""" } else { 'null' } }

$sb = [Text.StringBuilder]::new()
function L([string]$s = '') { [void]$sb.AppendLine($s) }

'Sage.Common.Data','Sage.Common.DataAccess','Sage.ObjectStore','System.Runtime.Serialization' | ForEach-Object { L "using $_;" }
L ''
L "namespace $($spec.Namespace)"
L '{'
L '    /// <summary>'
L "    /// ObjectStore collection for <see cref=""$view""/>."
L '    /// </summary>'
L '    [DataContract(IsReference = true, Namespace = "http://schemas.sage.com/sage200/2011/")]'
L "    public class $CollectionClass : ViewCollection"
L '    {'
L '        /// <summary>'
L "        /// Gets the <see cref=""$view""/> at the specified index."
L '        /// </summary>'
L '        /// <param name="index">The zero-based index</param>'
L "        public new $view this[int index] =>"
L "            ($view)base[index];"
L ''
L '        /// <summary>'
L "        /// Gets the first <see cref=""$view""/> in the collection, or null if it is empty."
L '        /// </summary>'
L "        public new $view First =>"
L "            ($view)base.First;"
L ''
L '        /// <summary>'
L "        /// Gets the owning <see cref=""$view""/> used to build the query, creating it on first use."
L '        /// </summary>'
L '        public override PersistentObject Owner'
L '        {'
L '            get'
L '            {'
L '                if (Query.Owner == null)'
L "                    Query.Owner = new $view();"
L '                return Query.Owner;'
L '            }'
L '        }'
if ($joins.Count -gt 0) {
  L ''
  L '        /// <summary>'
  L "        /// Joins <c>$($spec.Table)</c> to the tables its joined fields read from."
  L '        /// </summary>'
  L '        /// <remarks>'
  L '        /// Inner joins are used only where the column is not nullable and backed by a foreign key;'
  L '        /// other joins are left outer so a row is never dropped because a lookup is missing.'
  L '        /// </remarks>'
  L '        public override Joins Joins'
  L '        {'
  L '            get'
  L '            {'
  L '                Joins joins = base.Joins;'
  L ''
  L '                if (joins.Count == 0)'
  L '                {'
  foreach ($j in $joins) {
    $init = "Type = JoinType.$($j.Type)"
    if ($j.LeftAlias) { $init += ", LeftTableAlias = $(Q $j.LeftAlias)" }
    if ($j.RightAlias) { $init += ", RightTableAlias = $(Q $j.RightAlias)" }
    L "                    joins.Add(new Join($(Q $j.Left), $(Q $j.Right), $(Q $j.LeftColumn), $(Q $j.RightColumn)) { $init });"
  }
  L '                }'
  L ''
  L '                return joins;'
  L '            }'
  L '        }'
}
L '    }'
L '}'

New-Item -ItemType Directory -Force (Split-Path $OutFile) | Out-Null
[IO.File]::WriteAllText($OutFile, $sb.ToString().Replace("`r`n","`n").TrimEnd("`n") + "`n", [Text.UTF8Encoding]::new($false))
"wrote $OutFile ($($joins.Count) joins)"
