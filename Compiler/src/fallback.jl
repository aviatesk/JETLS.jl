# Julia versions without a snapshot, e.g. nightly, use `Base.Compiler` in the same way as
# the registered Compiler.jl (https://github.com/JuliaLang/BaseCompiler.jl) does. JETLS does
# not support these versions, but TestRunner.jl can still run tests with them.
baremodule Compiler

using Base: Base
const BaseCompiler = Base.Compiler
for name in Base.names(BaseCompiler; all=true, imported=true, usings=true)
    name === :Compiler && continue
    Core.eval(Compiler, :(using .BaseCompiler: $name))
    Core.eval(Compiler, Expr(:public, name))
end

end # baremodule Compiler
