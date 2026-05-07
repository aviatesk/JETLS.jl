module LoweredCodeUtils

# We use a code structure where all `using` and `import`
# statements in the package that load anything other than
# a Julia base or stdlib package are located in this file here.
# Nothing else should appear in this file here, apart from
# the `include("packagedef.jl")` statement, which loads what
# we would normally consider the bulk of the package code.
# This somewhat unusual structure is in place to support
# the VS Code extension integration.

using CodeTracking: MethodInfoKey

using JuliaInterpreter
using JuliaInterpreter: SSAValue, SlotNumber, Frame, Interpreter, RecursiveInterpreter
using JuliaInterpreter: codelocation, is_global_ref, is_global_ref_egal, is_quotenode_egal, is_return,
                        lookup, lookup_return, linetable, moduleof, next_until!, nstatements, pc_expr,
                        step_expr!, whichtt, extract_method_table
using Compiler: Compiler as CC

include("packagedef.jl")

end # module
