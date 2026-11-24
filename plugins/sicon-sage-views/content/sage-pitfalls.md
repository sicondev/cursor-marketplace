# Sage 200 ObjectStore pitfalls

Each of these has caused a real bug or a lost afternoon.

## Schema

- **Read the live database, not Sage's DLL metadata.** The persistent classes are older than the database: they
  miss columns (e.g. `SYSAccountStatusID`, `IntrastatStatus` on newer tables) and have wrong lengths. Use the
  persistent class only for decimal `UserDataType`s (`MonetaryBalance2dp`, `Percentage2dp`, `ExchangeRate`, ...).
- **Some id columns have no foreign key** (e.g. `StockItem.TaxCodeID`, `SOPOrderReturnLine.TraceableTypeID`).
  Join them left outer, or rows whose id points nowhere disappear.
- **NOT NULL lookups can still be missing**: 14 Demo Data nominal accounts have no report category. Check with a
  left join count before choosing inner.

## Ids and nulls

- **`DbKey.IsNull` is also true for id 0.** Many Sage lookups start at 0 (Active status, Component BOM type,
  Full payment type). For a nullable key use the generated `long? XID`, which reads the field's own `IsNull`.
- **The installed Sage version may name a field `XDbKey` or `XID`.** Check both when reading a persistent object's
  fields by name.
- **Newer columns can be missing from the installed persistent class** (e.g. `POPOrderReturn.DocumentCreatedByUserID`),
  so tests can't compare them; say so in a comment rather than dropping the column.

## Business objects and persistent classes

- **Business objects don't expose every field-name constant.** e.g. `FinancialCurrency` has no
  `FIELD_DATETIMECREATED`; use the persistent class's constant (`PersistentFinancialCurrency.FIELD_DATETIMECREATED`).
- **`PersistentObject.Fields` is only readable while its collection is alive.** Read inside the `using`.
- **Query.Max on a persistent collection is not always applied**: a `PersistentSOPInvoiceCreditLines` query sorted
  descending loaded all 26,308 rows. Take the first N in code as well, and keep test fetches small.

## Queries

- **SQL Server sorts with `Latin1_General_CI_AS`.** Compare sort order in .NET with
  `StringComparer.InvariantCultureIgnoreCase`, not ordinal.
- **Always add a final sort on the primary key**, so paging and "first N rows" are stable when the main sort ties.
- **Comparisons never match NULL**: `Filter(field, FilterOperator.GreaterThanOrEqual, 0L)` keeps only rows where a
  nullable id is set - handy for finding test samples.

## Spec files (PowerShell)

- **A helper named after an alias doesn't run** (`PS` is `Get-Process`): its entries silently vanish.
- **Every `@( ... )` entry starts with a comma**, or PowerShell flattens the arrays into one list.
- **`-replace` is case-insensitive.** Use `-creplace` or `.Replace()` when renaming in generated text.
