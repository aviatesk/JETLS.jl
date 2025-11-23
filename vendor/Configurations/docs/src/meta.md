```@meta
CurrentModule = Configurations
```

# Meta Programming

For most use cases, the default API [`@option`](@ref) is sufficient, however, there are some
specific cases requires one to use `Configurations`'s advanced API on meta programming.

## Custom Option Macro

In some cases, you may not want all the features we defined by default in `Configurations`.

In this case, you can construct your own macro using the code generation passes defined in
`Configurations`. The code generation passes API starts with `codegen_`. You combine them
as a codegen pipeline.

`Configurations` uses an intermediate representation defined by
[Expronicon](https://github.com/Roger-luo/Expronicon.jl) to represent
user defined option types, which is the `JLKwStruct` struct.

## Builtin Code Generators

```@autodocs
Modules = [Configurations]
Order   = [:function]
Pages   = ["codegen.jl"]
```
