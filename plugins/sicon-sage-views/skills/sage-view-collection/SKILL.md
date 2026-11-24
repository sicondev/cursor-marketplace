---
name: sage-view-collection
description: Create a Sage 200 ObjectStore read view (View) and its view collection (ViewCollection) for a Sage database table, with joins to lookup tables and an optional JSON API model, generated from a spec drafted off the live schema. Use when asked to add, generate or change a Sage 200 persistent object view, view collection, or a read endpoint over a Sage table.
---

# Sage 200 view and view collection

Builds `<Table>View.cs` (one row) and `<Table>Views.cs` (collection + joins) from a spec file, and optionally the API
model and its property mappings. All scripts are PowerShell, in this plugin's `scripts/` folder: resolve it as
`../../scripts/` relative to this SKILL.md and call them by full path. Reference docs are in `../../content/`.

Read `../../content/spec-reference.md` before writing or editing a spec, and `../../content/sage-pitfalls.md` before
writing joins, nullable ids or tests.

## Before you start

- Find the target project's conventions: an existing `*View.cs` / `*Views.cs`, where views live
  (e.g. `Objects/Views/<Module>/`), their namespace, and where specs are kept (e.g. `tools/codegen/specs/`).
  If the repo has its own copies of these generators or an AGENTS.md workflow, follow the repo.
- Ask for the SQL Server instance and database if they aren't the defaults (`.\SQL2022`, `Sage200_DemoData`).
- Ask which columns to leave out if the user hasn't said. Always leave out `OpLock` and `Spare*`. Commonly also left out:
  euro copy columns, payment cloud / Sage payments, T e-Mail, sync status, CRM. Removing later is cheap.

## Steps

1. **Read the live schema** (never Sage's DLL metadata, which is older than the database):
   ```powershell
   & <scripts>\Get-SageTableSchema.ps1 -Table <Table> [-Server ... -Database ...]
   ```
   It prints columns, the primary key, foreign keys, NULL counts, id columns without a foreign key, and each lookup
   table's rows (or its text columns for big tables). Use it to choose each lookup's code / name / description column.

2. **Draft the spec**:
   ```powershell
   & <scripts>\New-SageViewSpec.ps1 -Table <Table> -Namespace <Views namespace> -OutFile <specs>\spec-<table>.ps1 [-ClassName <Table>View] [-Exclude OpLock,Spare*,...]
   ```
   It writes one entry per column, decimals with their `UserDataType` (from Sage's persistent class), keys for every
   foreign key, and a joined `<Key>Name` field plus join for lookups that have a `Name` column. Inner joins only when
   the column is NOT NULL with a foreign key; a second join to the same table gets an alias.

3. **Review the draft** - the script can't know these:
   - Resolve every `# TODO`: join bigger tables (customer / supplier account, bank account, order) with the code / name
     columns the user wants, using `J` entries next to their key and a join in `$joins`; or leave them as ids.
   - Rewrite the generic doc comments (`The document no.`) into real ones, mentioning example values from the lookup
     rows (`The document status name (e.g. Live, Completed), joined from DocumentStatus.Name.`).
   - Rename joined fields so they say what they show (`CustomerAccountNumber`, `PaymentBankAccountCode`).
   - Check left-out columns are listed in `Remarks`.

4. **Check the spec against the table**:
   ```powershell
   & <scripts>\Test-SageViewSpec.ps1 -SpecFile <spec> [-Server ... -Database ...]
   ```
   Fix every `PROBLEM` line: missing / extra columns, nullability, string lengths, joined columns that don't exist,
   inner joins on nullable or foreign-key-less columns.

5. **Generate**:
   ```powershell
   & <scripts>\gen-view.ps1 -SpecFile <spec> -OutFile <views>\<Table>View.cs
   & <scripts>\gen-collection.ps1 -SpecFile <spec> -OutFile <views>\<Table>Views.cs
   ```
   Optional API model, plus `Name = source.Name,` mappings to paste into a converter:
   ```powershell
   & <scripts>\gen-model.ps1 -SpecFile <spec> -ModelNamespace <ns> -ModelClass <Thing>DetailModel -ModelSummary "Represents a ..." -OutFile <models>\<Thing>DetailModel.cs -MappingOutFile <temp>\mapping.txt -SourceVar <var>
   ```
   A project with an older hand-written collection (e.g. one using a `joins.AddJoin(...)` extension) can keep its
   style: the generated collection uses `joins.Add(new Join(...) { Type = ..., RightTableAlias = ... })`, which needs
   no extension.

6. **Build** with 0 errors and 0 warnings (generated members all carry XML doc comments).

7. **Test** against a real Sage company, following `../../content/testing.md`.

## Changing an existing view

- Generated files not hand-edited (regenerate to a temp file and compare hashes): edit the spec and regenerate.
- Hand-edited: remove simple fields with
  `& <scripts>\remove-fields.ps1 -Names A,B -ViewFile ... [-ModelFile ...] [-MappingFile ...] [-SpecFile ...]`.
  It stops without writing if any pattern doesn't match exactly once. Then remove joins left with no fields, and
  grep for the names.

## Don't

- Don't trust `DbKey.IsNull` for nullable ids - use the generated `long? XID` property.
- Don't use an inner join on a nullable column, or on a column with no foreign key.
- Don't name a spec helper after a PowerShell alias (`PS`, `LS`, `CD`, `R`, `H`, ...): the alias wins and entries
  silently go missing. Start every `@( ... )` entry with a comma.
- Don't write to Sage: views have setters only because ObjectStore expects them.
