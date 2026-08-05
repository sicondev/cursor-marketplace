# Sicon C# Coding Standards

Version 1.3

# Introduction

Coding and Design standards are an essential part of successful product delivery. Standards help to enforce best practice, avoid pitfalls and ease the process of knowledge dissemination across the team. It forms part of a Service Level Agreement for the development process.
This guide is split into two parts.

The first details the Sicon Coding Standard. It is intentionally thin on the 'why' and rather concentrates on the 'what' and 'how'. The aim here is for a new developer to be able to apply the standard in a short space of time without lengthy mentoring and training.

The second details the Sicon Design Standard. This is based around many years of accumulated wisdom in Object Oriented design methods and presents a catalogue of design patterns together with an explanation of the rationale behind the patterns and examples of their use.

Together, the standards aim to capture best practices, dos and don'ts, pitfalls and guidelines as well as conventions and style. There are also some framework specific guidelines.

# Coding Standards

The Coding Standard is split into two parts; a section covering naming conventions and style and a section covering general coding practices.

## Naming Conventions and Style

The following naming conventions are to be adhered to for any code written either by Sicon.

- Use Pascal casing for types, methods and constants. Do not underscore to separate words.

Correct ✅:
```csharp
class DemoClass 
{
    const int DefaultLength = 0;
    
    public void DemoMethod() 
    {
        
    }
}
```
Incorrect ❌:
```csharp
class demoClass 
{ 
    const int Default_length = 0; 
    
    public void Demomethod()
    {
        
    }
}
````
- Use camel casing for local variables and method arguments. Do not underscore to separate words. Do not use Hungarian prefixes for variables.
Correct ✅:
```csharp
void SomeMethod()
{
    int defaultWidth = 0;
    int defaultHeight = 0;
}
```
Incorrect ❌:
```csharp
void SomeMethod()
{
    int Default_width = 0;
    int iDefaultHeight = 0;
}
````
- Prefix interface names with 'I'. Do not append 'Interface' to the name.

Correct ✅:
```csharp
interface IDiscoverable 
{
    
}
```
Incorrect ❌:
```csharp
interface DiscoverableInterface 
{
    
} 
````
- Suffix custom attribute classes with Attribute
- Suffix custom exception classes with **Exception**
- Try to name methods using a verb or verb-object pair, such as **Execute()** or **ShowDialog()**
- Methods with return values should have a name describing the value returned, such as **GetObjectState()**. This should not be used in situations where a property would be more appropriate.
- Use descriptive variable names. Do not use Hungarian notation, such as **iLoopCounter, szString** or **frmPropertyDialog**

Correct ✅:
```csharp
int loopCounter = 0; 
foreach (object record in records) 
{
    loopCounter++;
}
```
Incorrect ❌:
```csharp
int iLoopCounter = 0; 
foreach (object record in records) 
{
    iLoopCounter++;
}
````
- Always use predefined C# types, rather than System namespace aliases

Correct ✅:
```csharp
object o;
int i
```
Incorrect ❌:
```csharp
Object o;
Int32 i;
````
- When using generics, use capital letters for types. Only suffix **Type** when dealing with the

.NET type **Type**

Correct ✅:
```csharp
public class LinkedList<K,T>
{
    
} 
```
Incorrect ❌:
```csharp
public class LinkedList<KeyType, DataType>
{
    
}
````

- Namespaces should consist of company name, Sage 200, product and module where this is practical and the product is a Sage 200 module.

Correct ✅:
```csharp
Sicon.Sage200.Product
Sicon.Sage200.Product.Objects 
```
Incorrect ❌:
```csharp
Sicon.Product 
Sicon.Product.Objects
````
- Avoid using fully-qualified names. Use the using keyword instead.
- Group all framework namespaces together and put custom or third-party namespaces underneath.
```csharp 
using System;  
using System.Collections.Generic;

using Sicon.Api;
````
- Use delegate inference instead of explicit delegate instantiation
```csharp
delegate void SomeDelegate();  
public void SomeMethod()  
{  
}  
SomeDelegate someDelegate = SomeMethod;
```
- Maintain strict indentation. Use four spaces. Do not use tabs (make sure that Visual Studio has 'Use spaces' switched on in the editor settings)
- Indent comments to the same level as the code that is being documented.
- All public methods should be XML commented at minimum, preferably all methods. Each parameter should be commented and any exceptions that could be thrown should be listed. Any relevant remarks such as a link to an external resource should be added to the remarks section. XML comments make the methods easier to use by other developers without the need to open the code in an editor to see what each parameter does.

```csharp
/// &lt;summary&gt;  
/// Opens a FileStream to the selected file  
/// &lt;/summary&gt;  
/// &lt;param name="path"&gt;The full path to the file to open&lt;/param&gt;  
/// &lt;returns&gt;FileStream&lt;/returns&gt;  
/// &lt;exception cref="FileNotFoundException"&gt;A FileNotFound exception can be thrown if the specified file does not exist on disk&lt;/exception&gt;  
/// &lt;remarks&gt;For more information see <https://docs.microsoft.com/en-us/dotnet/api/system.io.file.open?view=net-6.0</remarks>&gt;  
public FileStream GetFileStream(string path)  
{  
    if (!File.Exists(path))  
        throw new FileNotFoundException(\$"File '{path}' was not found.");  
    return File.Open(path, FileMode.Open);  
}
```
- All member variables should be declared at the top of the class
- Member variable names should begin with an underscore with the first letter lowercase

Correct ✅:
```csharp
private string _userName; 
```
Incorrect ❌:
```csharp
public string UserName;
````
- All methods should be spaced with a single line between methods.
- Declare local variables as close as possible to the point at which they are first used.
- Use string interpolation and not `string.format`
  
Correct ✅:
```csharp
string errorMessage = $"Error Encountered ({ex.Message})";
```
Incorrect ❌:
```csharp
string errorMessage = string.Format("Error Encountered ({0}), ex.Message)";
````
- Always place open braces on a new line
Correct ✅:
```csharp
if (x == 0) 
{
    
}
```
Incorrect ❌:
```csharp
if (x == 0) {
    
}
````
## Coding Practices

- Never use public member variables. Use a property instead. Also consider using properties for protected member variables.
- Try to avoid putting multiple classes in the same file
- A single file should contribute types to a single namespace
- Try to avoid files with more than 1000 lines of code (excluding machine-generated code). Consider using partial classes.
- Try to avoid methods with more than 5 or 6 parameters. This is usually an indication that the purpose of the method is poorly defined.
- Do not edit machine-generated code
- Avoid comments that explain the obvious. Only document algorithmic and operational assumptions
- With the exception of 0 and 1 (and possibly -1 and 2), never hard-code a numeric value. Always declare a constant and ensure that it is used consistently. Constants should be declared in a const class. Consider using a private const nested class for constants that only pertain to a particular class.
- Only use the const keyword for natural constants, such as days of the week or database keys that are constant values.
- Do not use const to declare read-only variables. Use the readonly keyword instead.
- Validate method parameters before they are used
```csharp
public void DoSomething(object parameter, int parameter2)  
{  
    if (parameter == null) throw new ArgumentNullException(nameof(parameter));  
    if (parameter2 <= 0) throw new ArgumentOutOfRangeException(\$"{nameof(parameter2)} must be greater than 0.");  
}
```
- Only catch exceptions for which you have explicit handling. Do not use 'catch-all' blocks.
- In a catch block that re-throws the exception, always throw the original exception (or another exception constructed from it) to maintain the stack location of the original problem.
- Do not use error codes as return values
- Try to avoid defining custom exception classes when there are built in exception types that can be used
- Do not use exceptions to implement normal logic flow. Exceptions are very expensive in terms of performance.
- When defining custom exceptions, always derive from Exception and provide for serialisation.
- Do not use multiple Main() methods in a single assembly.
- Mark all classes as internal by default. Only use public when necessary.
- Do not use friend assemblies as this increases coupling. This indicates a possible defect in the architecture.
- Try not to use code that depends on an assembly running in a particular location.
- Minimize code in application assemblies (EXE client assemblies) and UI Assemblies. Use class libraries to contain business logic.
- Always use zero-based arrays.
- With indexed collections, always use zero-based indexes.
- Avoid explicit casting. Use the as operator instead.
- Avoid using events as interface members.
- Don't use `""`. Use `string.Empty` instead.
- Don't compare strings to "". Use `string.IsNullOrEmpty()` instead.
- When comparing strings, use string.Compare() `string.Compare("text 1", "text 2") == 0`
- Don't use goto as normal program flow
- Always provide a default case in switch statements. Consider throwing a `NotImplementedException` or `NotSupportedException`
- Do not use `GC.AddMemoryPressure();`
- Use checking for overflow- and underflow- prone operations. This is very expensive in terms of performance and should be used sparingly.

```csharp
int CalcPower(int number, int power)  
{
    int result = 1;
    for (int count = 1; count <= power; count++)  
    {  
        checked
        {
            result *= number;  
        }
    }

    return result;
}
```

- Avoid using explicit `#if...#endif` to exclude code. Use conditional methods instead.

```csharp
[Conditional("Some condition")]  
public void SomeMethod()  
{  
}
```

## Sage Specific Conventions

- Use `Sicon.Sage200.Architecture.DAL.Common.CurrentSageContext.CurrentTime` or `Sage.Common.Clock.Now` instead of `DateTime.Now`
- Use `Sicon.Sage200.Architecture.DAL.Common.CurrentSageContext.CurrentDate` or `Sage.Common.Clock.Today` instead of `DateTime.Today`
- Use `Sage.Common.Helper.NumberHelper.Round(10, 2)` instead of `Math.Round(10, 2)`
