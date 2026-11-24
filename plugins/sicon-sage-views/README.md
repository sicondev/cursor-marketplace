# Sicon Sage Views

Create Sage 200 ObjectStore read views (`View`) and view collections (`ViewCollection`) for a Sage table, generated
from a spec drafted off the live database schema.

Install from the Sicon Team Marketplace, then enable the plugin. Ask the agent to "create a view and view collection
for `<Table>`" and the `sage-view-collection` skill takes it from there.

## What it does

1. Reads the table's live schema, foreign keys, NULL counts and lookup rows.
2. Drafts a spec: one entry per column with its kind, decimal `UserDataType`s from Sage's persistent class, keys for
   foreign keys, and joined name fields for lookup tables (inner or left outer, aliased when a table is joined twice).
3. Checks the spec against the table.
4. Generates `<Table>View.cs`, `<Table>Views.cs` (with joins) and, optionally, a JSON API model and its mappings.

## Scripts

All in `scripts/`, PowerShell 5.1+. They use `sqlcmd` with Windows authentication (default `.\SQL2022`,
`Sage200_DemoData`; override with `-Server` / `-Database`).

| Script | Purpose |
|---|---|
| `Get-SageTableSchema.ps1` | Print columns, keys, NULL counts and lookup rows for a table |
| `Get-SagePersistentFields.ps1` | List a persistent class's fields and decimal UserDataTypes (from the NuGet cache, or `-AssemblyPath`) |
| `New-SageViewSpec.ps1` | Draft a spec from the live table |
| `Test-SageViewSpec.ps1` | Check a spec against the table |
| `gen-view.ps1` | Generate the view |
| `gen-collection.ps1` | Generate the view collection and its joins |
| `gen-model.ps1` | Generate a JSON API model and property mappings |
| `remove-fields.ps1` | Remove fields from hand-edited generated files |

Reference docs: `content/spec-reference.md` (spec format), `content/sage-pitfalls.md`, `content/testing.md`.

## Requirements

- `sqlcmd` on the PATH, and read access to the Sage company database.
- For decimal UserDataTypes: the `sage200c.objects` NuGet package in the local cache, or a path to
  `Sage.Accounting.PersistentObjects.dll`.
- Generated code targets Sage 200 ObjectStore (`Sage.ObjectStore`, `Sage.Common.Data`); the model uses Newtonsoft.Json.

## Origin

Extracted from the Dost connector plugin (`tools/codegen` in sicon-dost), where these generators built the
ASM, NL, SL, PL, SOP, POP and Stock endpoints.
