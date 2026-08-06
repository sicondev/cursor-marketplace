# Sicon Sage 200 Coding Standards (v1.4)

Apply these rules when writing or reviewing code that use the Sage 200 SDK.

Code that uses the Sage 200 SDK can be defined as:

- Projects that contain a reference to nuget packages starting `with Sage200c.*`
- Project Namespaces that start with `Sicon.Sage200.*`
- Code that uses classes in a namespace that starts with `Sage.*`

## Sage-specific

| Avoid | Use instead |
|-------|-------------|
| `DateTime.Now` | `CurrentSageContext.CurrentTime` or `Sage.Common.Clock.Now` |
| `DateTime.Today` | `CurrentSageContext.CurrentDate` or `Sage.Common.Clock.Today` |
| `Math.Round(…)` | `Sage.Common.Helper.NumberHelper.Round(…)` |

(`CurrentSageContext` = `Sicon.Sage200.Architecture.DAL.Common.CurrentSageContext`)