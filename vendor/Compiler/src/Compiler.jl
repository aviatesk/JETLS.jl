# This file is a part of Julia. License is MIT: https://julialang.org/license

baremodule Compiler

using Base: Base
const BaseCompiler = Base.:(>=)(Base.VERSION.minor, 12) ? Base.Compiler : Core.Compiler
let names = Base.:(>=)(Base.VERSION.minor, 12) ?
        Base.names(BaseCompiler; all=true, imported=true, usings=true) :
        Base.names(BaseCompiler; all=true, imported=true)
    for name in names
        if name === :Compiler
            continue
        end
        Core.eval(Compiler, :(using .BaseCompiler: $name))
        Base.@static if Base.:(>=)(Base.VERSION.minor, 11)
            Core.eval(Compiler, Expr(:public, name))
        end
    end
end

end # baremodule Compiler
