"""
    JuliaInterpreter

A Julia-code interpreter that executes Julia expressions by walking the lowered
AST (`CodeInfo`), enabling statement-level inspection and debugging.

Key entry points:
- [`@interpret`](@ref): execute a single call under the interpreter
- [`Frame`](@ref) + [`debug_command`](@ref): construct an execution frame and step through it
- [`breakpoint`](@ref), [`@bp`](@ref), [`@breakpoint`](@ref): set breakpoints
- [`break_on`](@ref): pause automatically on errors or throws
"""
module JuliaInterpreter

# We use a code structure where all `using` and `import`
# statements in the package that load anything other than
# a Julia base or stdlib package are located in this file here.
# Nothing else should appear in this file here, apart from
# the `include("packagedef.jl")` statement, which loads what
# we would normally consider the bulk of the package code.
# This somewhat unusual structure is in place to support
# the VS Code extension integration.

using CodeTracking: CodeTracking, whereis

include("packagedef.jl")

end # module
