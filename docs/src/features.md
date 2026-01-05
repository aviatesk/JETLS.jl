# [Features](@id features)

JETLS aims to be a fully-featured language server for Julia, providing advanced
static analysis and seamless integration with the Julia runtime, leveraging
recent tooling technologies like [JET.jl](https://github.com/aviatesk/JET.jl),
[JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) and
[JuliaLowering.jl](https://github.com/c42f/JuliaLowering.jl)

## [Diagnostic](@id features/diagnostic)

JETLS reports various diagnostics including:

- Syntax errors
- Lowering errors and macro expansion errors
- Unused bindings (arguments, locals)
- Method overwrites
- Abstract struct fields
- Undefined global variables
- Non-existent struct fields
- Out-of-bounds field access

> Syntax/lowering error (Zed)
> ```@raw html
> <center>
> <iframe class="display-light-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/a29db5d0-fa53-4958-ab3d-a9ab4952a0ef" alt="Syntax/lowering diagnostic" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> <iframe class="display-dark-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/7c291dde-8ab6-44f5-bce4-0e3478ff2018" alt="Syntax/lowering diagnostic" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> </center>
> ```

> Abstract field (VSCode)
> ```@raw html
> <center>
> <img class="display-light-only" alt="Diagnostic abstract field" src="https://github.com/user-attachments/assets/d2c80efb-5e34-4180-95e2-ee1df4fc93f6">
> <img class="display-dark-only" alt="Diagnostic abstract field" src="https://github.com/user-attachments/assets/0efec540-9d86-4887-a4d9-a49fbad03560">
> </center>
> ```

Some diagnostics offer quickfix [code actions](@ref features/refactoring/code-actions),
such as prefixing unused variables with `_` to suppress warnings.

For detailed diagnostic reference and configuration options, see
the [diagnostic section](@ref diagnostic).

## [Completion](@id features/completion)

JETLS provides powerful and intelligent code completion with type-aware suggestions.

### [Global and local completion](@id features/completion/global-local)

Completion for global symbols (functions, types, modules, constants) and local
bindings. Global completions include detailed kind information resolved lazily
when selected.

> Global and local completion (Zed)
> ```@raw html
> <center>
> <iframe class="display-light-only" style="width:100%;height:min(00px,70vh);aspect-ratio:16/7" src="https://github.com/user-attachments/assets/076769bd-3241-4c12-a165-f3ec7c5cd958" alt="Global and local completion" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> <iframe class="display-dark-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/7" src="https://github.com/user-attachments/assets/533674d0-e488-4639-b953-015158064c82" alt="Global and local completion" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> </center>
> ```

### [Method signature completion](@id features/completion/method-signature)

When typing inside a function call (triggered by `(`, `,`, or space), compatible
method signatures are suggested based on already-provided arguments. Selecting
a completion inserts remaining positional arguments as snippet placeholders with
type annotations. Inferred return type and documentation are resolved lazily.

> Method signature completion (VSCode)
> ```@raw html
> <center>
> <iframe class="display-light-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/fd72a4ee-4bb5-4cd6-a9a0-f0d669d9c065" alt="Method signature completion" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> <iframe class="display-dark-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/fd72a4ee-4bb5-4cd6-a9a0-f0d669d9c065" alt="Method signature completion" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> </center>
> ```

### [Keyword argument completion](@id features/completion/keyword-argument)

When typing inside a function call (e.g., `func(; |)` or `func(k|)`), available
keyword arguments are suggested with `=` appended. Already-specified keywords
are excluded from suggestions.

> Keyword argument completion (VSCode)
> ```@raw html
> <center>
> <iframe class="display-light-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/1e58bee2-e682-47d2-81e8-0553a620428a" alt="Keyword argument completion" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> <iframe class="display-dark-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/1fe8e695-e24a-4e62-b0bc-7027459ed3c9" alt="Keyword argument completion" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> </center>
> ```

### [LaTeX and emoji completion](@id features/completion/latex-emoji)

Type `\` to trigger LaTeX symbol completion (e.g., `\alpha` → `α`) or `\:`
to trigger emoji completion (e.g., `\:smile:` → `😄`), mirroring the behavior
of the Julia REPL.

> LaTeX emoji completion (Zed)
> ```@raw html
> <center>
> <img class="display-light-only" alt="LaTeX emoji completion" src="https://github.com/user-attachments/assets/0b074bc7-97a9-405b-8695-dd69a051f59a">
> <img class="display-dark-only" alt="LaTeX emoji completion" src="https://github.com/user-attachments/assets/20e88f56-8d9f-4f32-bff4-8cf9ffac8602">
> </center>
> ```

## [Signature help](@id features/signature-help)

JETLS displays method signatures as you type function arguments. Methods are
filtered based on the inferred types of already-provided arguments. For example,
typing `sin(1,` shows only methods compatible with an `Int` first argument.

## [Go to definition](@id features/go-to-definition)

Jump to where a symbol is defined. JETLS resolves method or module definitions,
and local bindings.

```@raw html
<center>
<img class="display-light-only" alt="Go to definition" src="https://github.com/user-attachments/assets/78d89486-4bc1-4faa-8d19-8dfb142bc046">
<img class="display-dark-only" alt="Go to definition" src="https://github.com/user-attachments/assets/555008e7-27e4-444d-b72b-76607db639c8">
</center>
```

## [Find references](@id features/find-references)

Find all references to a symbol within the same analysis unit. Both local and
global bindings are supported.

```@raw html
<center>
<img class="display-light-only" alt="Find references" src="https://github.com/user-attachments/assets/bcca21b3-a4cb-40fe-8f92-071a370e7255">
<img class="display-dark-only" alt="Find references" src="https://github.com/user-attachments/assets/95099e0b-f56b-437b-aabe-d10647292aca">
</center>
```

## [Hover](@id features/hover)

Hover over symbols to see documentation and source locations. Method
documentation includes signature information and docstrings. Local bindings
show their definition location.

## [Document highlight](@id features/document-highlight)

Select a symbol to highlight all its occurrences in the current file.

## [Refactoring](@id features/refactoring)

### [Rename](@id features/refactoring/rename)

Rename local or global bindings across files. When renaming a string literal
that refers to a file path (e.g., in `include("foo.jl")`), JETLS also renames
the file on disk.

### [Code actions](@id features/refactoring/code-actions)

JETLS provides code actions for quick fixes and refactoring:

- Prefix unused variables with `_` to suppress warnings
- Delete unused variable assignments (removes `y = `, keeping the RHS expression)
- Delete unused assignment statements entirely

## [Formatting](@id features/formatting)

JETLS integrates with external formatters:

- [Runic.jl](https://github.com/fredrikekre/Runic.jl) (default)
- [JuliaFormatter.jl](https://github.com/domluna/JuliaFormatter.jl)

See [Formatting](@ref "Formatting") for setup instructions.

## [TestRunner integration](@id features/testrunner)

Run individual `@testset` blocks and `@test` cases directly from your editor
via code lenses and code actions.

See [TestRunner integration](@ref "TestRunner integration") for setup
instructions.

## [Notebook support](@id features/notebook)

JETLS provides full LSP features for Julia code cells in Jupyter notebooks.
All cells are analyzed together, so features like go-to-definition, completions,
and diagnostics work across cells.

> Demo in VSCode
>
> ```@raw html
> <center>
> <iframe class="display-light-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/b5bb5201-d735-4a37-b430-932b519254ee" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> <iframe class="display-dark-only" style="width:100%;height:min(500px,70vh);aspect-ratio:16/9" src="https://github.com/user-attachments/assets/f7476257-7a53-44a1-8c8c-1ad57e136a63" frameborder="0" allow="accelerometer; clipboard-write; encrypted-media; gyroscope; picture-in-picture" allowfullscreen></iframe>
> </center>
> ```

See [Notebook support](@ref notebook) for details.

## Roadmap

JETLS is under active development. Features like inlay hints, workspace symbols,
and type-aware method definitions are planned but not yet implemented.

For the full list of planned features and current progress, see the
[roadmap on GitHub](https://github.com/aviatesk/JETLS.jl?tab=readme-ov-file#roadmap)
or the [development notes](https://publish.obsidian.md/jetls/work/JETLS/JETLS+roadmap).
