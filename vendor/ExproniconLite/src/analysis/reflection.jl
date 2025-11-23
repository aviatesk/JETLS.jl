
    #= none:1 =# Core.@doc "    @expr <expression>\n\nReturn the original expression object.\n\n# Example\n\n```julia\njulia> ex = @expr x + 1\n:(x + 1)\n```\n" macro expr(ex)
            return QuoteNode(ex)
        end
    #= none:17 =# Core.@doc "    @expr <type> <expression>\n\nReturn the expression in given type.\n\n# Example\n\n```julia\njulia> ex = @expr JLKwStruct struct Foo{N, T}\n           x::T = 1\n       end\n#= kw =# struct Foo{N, T}\n    #= /home/roger/code/julia/Expronicon/test/analysis.jl:5 =#\n    x::T = 1\nend\n```\n" macro expr(type, ex)
            quote
                    ($type)($(Expr(:quote, ex)))
                end |> esc
        end
    #= none:40 =# Core.@doc "    gensym_name(x::Symbol)\n\nReturn the gensym name.\n\n!!! note\n    Borrowed from [MacroTools](https://github.com/FluxML/MacroTools.jl).\n" function gensym_name(x::Symbol)
            m = Base.match(r"##(.+)#\d+", String(x))
            m === nothing || return m.captures[1]
            m = Base.match(r"#\d+#(.+)", String(x))
            m === nothing || return m.captures[1]
            return "x"
        end
