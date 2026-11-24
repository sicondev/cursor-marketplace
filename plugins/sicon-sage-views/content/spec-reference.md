# View spec reference

A spec is a PowerShell script that returns a hashtable. `gen-view.ps1`, `gen-collection.ps1`, `gen-model.ps1` and
`Test-SageViewSpec.ps1` all run it.

```powershell
@{
  Namespace = 'My.Plugin.Objects.Views.SL'
  ClassName = 'SLCustomerAccountView'        # the collection is ClassName + 's' unless gen-collection gets -CollectionClass
  Table     = 'SLCustomerAccount'
  KeyColumn = 'SLCustomerAccountID'
  Summary   = 'Read view over <c>SLCustomerAccount</c>, joined to ...'   # XML doc; <c>...</c> is fine
  Remarks   = 'Leaves out OpLock, the Spare* columns and ...'           # list every column you leave out
  Columns   = $cols
  Joins     = $joins                         # optional
}
```

## Columns

Each entry is `@(Name, Kind, MetaDataArgs, Summary)`:

- **Name** - the C# property name (and ObjectStore field name). Keys are named `<X>DbKey`.
- **Kind** - how the property is generated (table below).
- **MetaDataArgs** - the body of the `[MetaDataField(...)]` attribute, e.g.
  `IsNullable = true, DbType = DbType.AnsiString, Precision = 60`. `ColumnName = "..."` maps to a different column;
  `FieldPropertyName = "_X"` sets the backing field; `TableName = "..."` reads from a joined table.
- **Summary** - the XML doc comment. Say what the value is and, for joined fields, where it's joined from.

Every entry in the `@( ... )` list starts with a comma, or PowerShell flattens it into the list.

| Kind | C# property | Use for |
|---|---|---|
| `pk` | `DbKey X` (read-only) | the primary key; Name is the table name |
| `key` | `DbKey XDbKey` | NOT NULL id columns |
| `keyNullable` | `DbKey XDbKey` + `long? XID` | nullable id columns - use `XID` for null checks |
| `string` | `string` | char / varchar (length in `Precision`; `varchar(max)` is 2147483647) |
| `int`, `intNullable` | `int`, `int?` | int |
| `short`, `shortNullable` | `short`, `short?` | smallint |
| `long`, `longNullable` | `long`, `long?` | bigint that is not an id |
| `decimal` | `Decimal` | decimal - give `UserDataType = "MonetaryBalance2dp"` etc. |
| `bool`, `boolNullable` | `bool`, `bool?` | bit |
| `date`, `dateNullable` | `DateTime`, `DateTime?` | datetime |
| `dateRO` | `DateTime` (read-only) | `DateTimeCreated`, `DateTimeUpdated` |
| `joined` | `string` (read-only) | text column read from a joined table |
| `joinedShort`, `joinedInt`, `joinedDate` | `short?`, `int?`, `DateTime?` (read-only) | other joined columns |

Not covered: nullable decimals, binary columns, `uniqueidentifier`. Leave them out or hand-write them.

## Spec helpers

Drafts from `New-SageViewSpec.ps1` define one-letter helpers that build entries:

| Helper | Builds |
|---|---|
| `S 'Name' 60 'Doc' [-Nullable]` | string |
| `Key 'Customer' 'CustomerID' 'Doc'` | `CustomerDbKey`, key, backing field `_Customer` |
| `NKey 'Warehouse' 'WarehouseID' 'Doc'` | `WarehouseDbKey` + `WarehouseID`, keyNullable |
| `J 'WarehouseName' 'Warehouse' 'Name' 20 'Doc' [-Nullable]` | joined string from table (or alias) `Warehouse`, column `Name` |
| `D 'TotalNetValue' 'MonetaryBalance2dp' 'Doc'` | decimal with a UserDataType |
| `I` / `NI`, `Sh` / `NSh`, `B` / `NB` | int, smallint, bit (nullable with `N`) |
| `Dt` / `ND` | datetime / nullable datetime |

Add your own (e.g. `function A($n) { ,@("AnalysisCode$n", 'string', ...) }` for numbered columns), but never name one
after a PowerShell alias (`PS`, `LS`, `CD`, `R`, `H`, `GC`, `CLS`, ...): the alias runs instead and its entries vanish
without an error. `Get-Alias <name>` tells you if a name is taken.

## Joined fields

- Put each joined field right after its key.
- Read-only, and nullable (`-Nullable`) when the join is left outer.
- Named after what they show: `CurrencyISOCode`, `PaymentGroupDescription`, not `Name`.
- Every field needs a unique backing field. When a joined field's natural name clashes with a key's backing field
  (key `TaxCode` -> `_TaxCode`, joined `TaxCode` -> also `_TaxCode`), give it its own:
  `FieldPropertyName = "_JoinedTaxCode"`. The generators reject duplicates.
- Non-text joined columns need a full entry, e.g.
  `@('TaxCode','joinedShort','FieldPropertyName = "_JoinedTaxCode", ColumnName = "Code", TableName = "SYSTaxRate", IsReadOnly = true, IsNullable = true, DbType = DbType.Int16, Precision = 5, Scale = 0, FormatScale = 0','The tax code number, joined from SYSTaxRate.Code; null when the line has no tax code.')`

## Joins

```powershell
$joins = @(
  ,@{ Left = 'SOPOrderReturn'; Right = 'SLCustomerAccount'; LeftColumn = 'CustomerID'; RightColumn = 'SLCustomerAccountID'; Type = 'Inner' }
  ,@{ Left = 'SOPOrderReturn'; Right = 'SYSCurrency'; LeftColumn = 'CurrencyID'; RightColumn = 'SYSCurrencyID'; Type = 'LeftOuter' }
  # two-step: join from a joined table
  ,@{ Left = 'SYSCurrency'; Right = 'SYSCurrencyISOCode'; LeftColumn = 'SYSCurrencyISOCodeID'; RightColumn = 'SYSCurrencyISOCodeID'; Type = 'LeftOuter' }
  # the same table again: alias it, and use the alias as the joined fields' TableName
  ,@{ Left = 'SOPOrderReturn'; Right = 'DocumentProcessStatus'; LeftColumn = 'AllocatedStatusID'; RightColumn = 'DocumentProcessStatusID'; Type = 'Inner'; RightAlias = 'AllocatedStatus' }
)
```

- **Inner** only when the column is NOT NULL *and* has a foreign key. Otherwise **LeftOuter**, or rows with a missing
  lookup silently disappear.
- A table joined more than once needs a `RightAlias` on every extra join; the first may keep the table name.
- Self-joins (a table to itself) should work the same way with an alias, but are untested.
- `gen-collection.ps1` fails if a joined field's `TableName` isn't a joined table or alias, or a table is joined
  twice without an alias.

## Naming in the API model

`gen-model.ps1` names JSON properties: `XID` -> `xId`, leading acronyms lower-cased (`SLCustomerAccountID` ->
`slCustomerAccountId`). Keys become `long` ids (`CustomerDbKey` -> `CustomerID`), nullable keys `long?`.
