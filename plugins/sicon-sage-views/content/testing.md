# Testing a view collection

Test against a real Sage 200 company (e.g. Demo Data), inside a transaction that is rolled back, and make a test
Inconclusive rather than failed when Sage can't be reached or the company lacks the data it needs.

## What to cover

One test class per view collection (or per service wrapping it):

- **Joins don't add or drop rows.** Compare the first N ids (N = 100) of the view collection with Sage's own
  persistent collection in the same sort order. A join that drops or duplicates rows shifts the ids. For small
  tables (< ~1,000 rows) comparing full counts is fine.
- **Sort order.** The returned rows are in the documented order, with the primary key as the final tie-break.
- **A smaller cap returns the start of the same ordering** (first 10 == first 10 of first 100).
- **Filters** (e.g. created / updated since a date): a future date returns nothing, a past date returns everything.
- **Nullable ids are null only when the column is NULL**: compare the view's `XID == null` with the persistent
  object's field `IsNull` (try both `XDbKey` and `XID` field names).
- **Every joined value matches its source table**: group rows by lookup id, check all rows in a group agree, then
  read the lookup record once per id and compare.
- **Aliased joins read their own column**: pick a sample where the aliased ids differ (check with SQL first), or a
  mix-up between aliases passes unnoticed.
- **Model mapping covers every field**: compare model and view properties by name, on samples with each optional
  lookup both set and not set.

## Getting good samples

- The first 100 rows often share the same optional values (e.g. no linked order, archived flag always set). Check
  with SQL, and add a second fetch for the other case: newest rows (sort by id descending) or rows where a nullable
  id is set (`Filter(field, FilterOperator.GreaterThanOrEqual, 0L)`).
- Prefer the view collection for these extra fetches, with `Query.Max`.

## Rules learned the hard way

- **Cap every fetch on large tables** (transactions, lines): loading 11k+ rows made one suite run for 40+ minutes,
  and counting a 6k-row table through ObjectStore took nearly 8.
- **Never put a Sage type in a test method's generic constraint** (`where T : PersistentObject`). MSTest loads it
  during discovery, before Sage assemblies are resolved, and silently skips the whole class.
- **Keep Sage's NuGet reference DLLs out of the test bin**, or they load instead of the installed Sage client and
  connecting fails with `MissingFieldException`.
- **Don't run two test runs at once** against the same company: they contend for the same tables and hang.
