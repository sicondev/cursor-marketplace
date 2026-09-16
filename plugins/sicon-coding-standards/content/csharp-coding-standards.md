# Sicon C# Coding Standards (v1.5)

Apply these rules when writing or reviewing C#. Prefer this document over memory.

**EditorConfig owns format and IDE-enforceable naming** when the repo has a root `.editorconfig`
(e.g. Platform, Approvals): indent, braces layout, usings order/groups, language keywords vs BCL
names, method-group / delegate inference, `$"..."` vs `string.Format`, and capitalization rules
(`PascalCase` / `camelCase` / `I` / `_camelCase` fields). Do not restate or fight those settings here.

This document keeps **prose conventions** EditorConfig cannot (or does not) express.

## Naming (beyond EditorConfig)

| Kind | Style | Notes |
|------|--------|--------|
| Fields | (see EditorConfig) | Declare at top of class; **never public fields** — use properties |
| Attributes | `…Attribute` suffix | |
| Exceptions | `…Exception` suffix | |
| Generic type params | Single capitals (`K`, `T`) | Suffix `Type` only for `System.Type` |
| Methods | Verb / verb-object | Prefer property over `GetX()` when appropriate |
| Namespaces (Sage 200) | `Sicon.Sage200.Product[.Module]` | Not `Sicon.Product` |

- No Hungarian notation on locals/parameters (`iCount`, `szName`).

## Style (beyond EditorConfig)

- One blank line between methods.
- Declare locals near first use.
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
- Do not expose raw error messages to clients. Log them and return a safe or generic error message.
