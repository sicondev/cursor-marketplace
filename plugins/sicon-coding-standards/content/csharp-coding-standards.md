# Sicon C# Coding Standards (v1.4)

Apply these rules when writing or reviewing C#. Prefer this document over memory.

## Naming

| Kind | Style | Notes |
|------|--------|--------|
| Types, methods, constants | PascalCase | No underscores |
| Locals, parameters | camelCase | No Hungarian (`iCount`, `szName`) |
| Fields | `_camelCase` | Declare at top of class; never public fields — use properties |
| Interfaces | `I` prefix | Not `…Interface` |
| Attributes | `…Attribute` suffix | |
| Exceptions | `…Exception` suffix | |
| Generic type params | Single capitals (`K`, `T`) | Suffix `Type` only for `System.Type` |
| Methods | Verb / verb-object | Prefer property over `GetX()` when appropriate |
| Namespaces (Sage 200) | `Sicon.Sage200.Product[.Module]` | Not `Sicon.Product` |

- Prefer language keywords (`int`, `object`) over BCL names (`Int32`, `Object`).
- Prefer `using` over fully qualified names. Group: BCL usings, blank line, then app/third-party.
- Prefer delegate inference: `SomeDelegate d = SomeMethod;` not `new SomeDelegate(…)`.

## Style

- Indent with **4 spaces** (no tabs). Align comments with the code they document.
- Opening brace on its **own line**.
- One blank line between methods.
- Declare locals near first use.
- Prefer `$"..."` over `string.Format`.
- Prefer `string.Empty` over `""`; prefer `string.IsNullOrEmpty` for empty checks; compare with `string.Compare(a, b) == 0`.
- XML-doc all public methods (`summary`, `param`, `returns`, `exception`, `remarks` as needed). Prefer documenting other methods too.

```csharp
/// <summary>Opens a stream to the given path.</summary>
/// <param name="path">Full path.</param>
/// <returns>Opened FileStream.</returns>
/// <exception cref="FileNotFoundException">When the file does not exist.</exception>
public FileStream GetFileStream(string path)
{
    if (!File.Exists(path))
        throw new FileNotFoundException($"File '{path}' was not found.");
    return File.Open(path, FileMode.Open);
}
```

## Structure

- One type per file; one namespace per file.
- Prefer files under ~1000 lines (exclude generated); use partials if needed.
- Prefer ≤5–6 method parameters; redesign if more.
- Classes `internal` by default; `public` only when required.
- No friend assemblies; avoid path-dependent assembly loading.
- Keep EXE/UI thin; put business logic in class libraries.
- Do not edit machine-generated code.
- No multiple `Main()` in one assembly.

## Practices

- Validate parameters before use (`ArgumentNullException`, `ArgumentOutOfRangeException`, `nameof`).
- Catch only exceptions you handle; on rethrow, `throw;` (or wrap with original as inner) — preserve stack.
- Do not return error codes; do not use exceptions for normal control flow.
- Prefer built-in exceptions; custom exceptions derive from `Exception` and support serialization.
- Prefer `as` over explicit casts.
- Avoid events on interfaces.
- No `goto` for normal flow.
- `switch` always has `default` (often `NotImplementedException` / `NotSupportedException`).
- Do not use `GC.AddMemoryPressure`.
- Prefer `[Conditional("…")]` over `#if` / `#endif` for excluding methods.
- Use `checked` only for overflow-prone arithmetic (sparingly).
- Magic numbers (except −1, 0, 1, 2): named constants. `const` for true constants; `readonly` for runtime-fixed values. Prefer a const class / private nested const class.
- Comment only non-obvious assumptions, not obvious code.
- Zero-based arrays and indexed collections.

## Sage-specific

| Avoid | Use instead |
|-------|-------------|
| `DateTime.Now` | `CurrentSageContext.CurrentTime` or `Sage.Common.Clock.Now` |
| `DateTime.Today` | `CurrentSageContext.CurrentDate` or `Sage.Common.Clock.Today` |
| `Math.Round(…)` | `Sage.Common.Helper.NumberHelper.Round(…)` |

(`CurrentSageContext` = `Sicon.Sage200.Architecture.DAL.Common.CurrentSageContext`)
