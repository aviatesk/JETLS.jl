
    const Maybe{T} = Union{Nothing, T}
    const __DEFAULT_KWARG_DOC__ = "All the following fields are valid as keyword arguments `kw` in the constructor, and can\nbe access via `<object>.<field>`.\n"
    const __DEF_DOC__ = "`doc::String`: the docstring of this definition."
    const __LINENO_DOC__ = "`line::LineNumberNode`: a `LineNumberNode` to indicate the line information."
    #= none:11 =# Core.@doc "    NoDefault\n\nType describes a field should have no default value.\n" struct NoDefault
        end
    #= none:18 =# Core.@doc "    const no_default = NoDefault()\n\nConstant instance for [`NoDefault`](@ref) that\ndescribes a field should have no default value.\n" const no_default = NoDefault()
    Base.show(io::IO, ::NoDefault) = begin
            print(io, "no_default")
        end
    #= none:27 =# Core.@doc "    abstract type JLExpr end\n\nAbstract type for Julia syntax type.\n" abstract type JLExpr end
    #= none:34 =# Core.@doc "    JLCall(func, args::Vector, kwargs::Maybe{Vector})\n    JLCall(; func, args=[], kwargs=nothing)\n\nRepresents a Julia function call expression.\n\n# Fields and Keyword Arguments\n\n$(__DEFAULT_KWARG_DOC__)\n- `func`: the function being called\n- `args`: optional, function arguments, a list of `Expr` or `Symbol`.\n- `kwargs`: optional, function keyword arguments, a list of `Expr(:kw, name, default)`.\n" mutable struct JLCall <: JLExpr
            func
            args::Vector
            kwargs::Maybe{Vector}
        end
    function JLCall(; func, args = [], kwargs = nothing)
        JLCall(func, args, kwargs)
    end
    #= none:58 =# Core.@doc "    mutable struct JLFunction <: JLExpr\n    JLFunction(;kw...)\n\nType describes a Julia function declaration expression.\n\n# Fields and Keyword Arguments\n\n$(__DEFAULT_KWARG_DOC__)\nThe only required keyword argument for the constructor\nis `name`, the rest are all optional.\n\n- `head`: optional, function head, can be `:function`, `:(=)` or `:(->)`.\n- `name`: optional, function name, can has type `Nothing`, `Symbol` or `Expr`, default is `nothing`.\n- `args`: optional, function arguments, a list of `Expr` or `Symbol`.\n- `kwargs`: optional, function keyword arguments, a list of `Expr(:kw, name, default)`.\n- `rettype`: optional, the explicit return type of a function,\n    can be a `Type`, `Symbol`, `Expr` or just `nothing`, default is `nothing`.\n- `generated`: optional, if this is a generated function.\n- `whereparams`: optional, type variables, can be a list of `Type`,\n    `Expr` or `nothing`, default is `nothing`.\n- `body`: optional, function body, an `Expr`, default is `Expr(:block)`.\n- $(__LINENO_DOC__)\n- $(__DEF_DOC__)\n\n# Example\n\nConstruct a function expression\n\n```julia\njulia> JLFunction(;name=:foo, args=[:(x::T)], body= quote 1+1 end, head=:function, whereparams=[:T])\nfunction foo(x::T) where {T}\n    #= REPL[25]:1 =#    \n    1 + 1    \nend\n```\n\nDecompose a function expression\n\n```julia\njulia> ex = :(function foo(x::T) where {T}\n           #= REPL[25]:1 =#    \n           1 + 1    \n       end)\n:(function foo(x::T) where T\n      #= REPL[26]:1 =#\n      #= REPL[26]:3 =#\n      1 + 1\n  end)\n\njulia> jl = JLFunction(ex)\nfunction foo(x::T) where {T}\n    #= REPL[26]:1 =#    \n    #= REPL[26]:3 =#    \n    1 + 1    \nend\n```\n\nGenerate `Expr` from `JLFunction`\n\n```julia\njulia> codegen_ast(jl)\n:(function foo(x::T) where T\n      #= REPL[26]:1 =#\n      #= REPL[26]:3 =#\n      1 + 1\n  end)\n```\n" mutable struct JLFunction <: JLExpr
            head::Symbol
            name::Any
            args::Vector{Any}
            kwargs::Maybe{Vector{Any}}
            rettype::Any
            generated::Bool
            whereparams::Maybe{Vector{Any}}
            body::Any
            line::Maybe{LineNumberNode}
            doc::Maybe{Union{String, Expr}}
        end
    function JLFunction(; head = :function, name = nothing, args = [], kwargs = nothing, rettype = nothing, generated = false, whereparams = nothing, body = Expr(:block), line = nothing, doc = nothing)
        head in [:function, :(=), :->] || throw(ArgumentError("function head can only take `:function`, `:(=)` or `:(->)`"))
        name isa Union{Nothing, Symbol, Expr} || throw(ArgumentError("function name can only be a `Nothing`, `Symbol` or `Expr`, got a $(typeof(name))."))
        rettype isa Union{Nothing, Symbol, Expr, Type} || throw(ArgumentError("function rettype can only be a `Type`, `Symbol`, `Expr` or just `nothing`, got a $(typeof(rettype))."))
        line isa Maybe{LineNumberNode} || throw(ArgumentError("function line must be a `LineNumberNode` or just `nothing`, got a $(typeof(line))."))
        any((x->begin
                        !(x isa Union{Symbol, Expr})
                    end), args) && throw(ArgumentError("function args can only be a list of `Symbol` or `Expr`, got a $(typeof(args))."))
        !(isnothing(whereparams)) && (any((x->begin
                            !(x isa Union{Symbol, Expr})
                        end), whereparams) && throw(ArgumentError("function whereparams can only be a list of `Symbol` or `Expr`, got a $(typeof(whereparams)).")))
        !(isnothing(kwargs)) && (any((x->begin
                            !(x isa Union{Symbol, Expr})
                        end), kwargs) && throw(ArgumentError("function kwargs can only be a list of `Expr(:kw, name, default)` or `Symbol`, got a $(typeof(kwargs)).")))
        JLFunction(head, name, args, kwargs, rettype, generated, whereparams, body, line, doc)
    end
    #= none:168 =# Core.@doc "    mutable struct JLField <: JLExpr\n    JLField(;kw...)\n\nType describes a Julia field in a Julia struct.\n\n# Fields and Keyword Arguments\n\n$(__DEFAULT_KWARG_DOC__)\nThe only required keyword argument for the constructor\nis `name`, the rest are all optional.\n\n- `name::Symbol`: the name of the field.\n- `type`: the type of the field.\n- `isconst`: if the field is annotated with `const`.\n- $(__LINENO_DOC__)\n- $(__DEF_DOC__)\n" mutable struct JLField <: JLExpr
            name::Symbol
            type::Any
            isconst::Bool
            doc::Maybe{Union{String, Expr}}
            line::Maybe{LineNumberNode}
        end
    function JLField(; name, isconst = false, type = Any, doc = nothing, line = nothing)
        JLField(name, type, isconst, doc, line)
    end
    #= none:199 =# Core.@doc "    mutable struct JLKwField <: JLExpr\n\nType describes a Julia field that can have a default value in a Julia struct.\n\n    JLKwField(;kw...)\n\nCreate a `JLKwField` instance.\n\n# Fields and Keyword Arguments\n\n$(__DEFAULT_KWARG_DOC__)\nThe only required keyword argument for the constructor\nis `name`, the rest are all optional.\n\n- `name::Symbol`: the name of the field.\n- `type`: the type of the field.\n- `isconst`: if the field is annotated with `const`.\n- `default`: default value of the field, default is [`no_default`](@ref).\n- $(__LINENO_DOC__)\n- $(__DEF_DOC__)\n" mutable struct JLKwField <: JLExpr
            name::Symbol
            type::Any
            isconst::Bool
            doc::Maybe{Union{String, Expr}}
            line::Maybe{LineNumberNode}
            default::Any
        end
    function JLKwField(; name, isconst = false, type = Any, doc = nothing, line = nothing, default = no_default)
        JLKwField(name, type, isconst, doc, line, default)
    end
    #= none:235 =# Core.@doc "    mutable struct JLStruct <: JLExpr\n\nType describes a Julia struct.\n\n    JLStruct(;kw...)\n\nCreate a `JLStruct` instance.\n\n# Available Fields and Keyword Arguments\n\n$(__DEFAULT_KWARG_DOC__)\nThe only required keyword argument for the constructor\nis `name`, the rest are all optional.\n\n- `name::Symbol`: name of the struct, this is the only required keyword argument.\n- `ismutable::Bool`: if the struct definition is mutable.\n- `typevars::Vector{Any}`: type variables of the struct, should be `Symbol` or `Expr`.\n- `supertype`: supertype of the struct definition.\n- `fields::Vector{JLField}`: field definitions of the struct, should be a [`JLField`](@ref).\n- `constructors::Vector{JLFunction}`: constructors definitions of the struct, should be [`JLFunction`](@ref).\n- `line::LineNumberNode`: a `LineNumberNode` to indicate the definition position for error report etc.\n- `doc::String`: documentation string of the struct.\n- `misc`: other things that happens inside the struct body, by definition this will\n    just fall through and is equivalent to eval them outside the struct body.\n\n# Example\n\nConstruct a Julia struct.\n\n```julia\njulia> JLStruct(;name=:Foo, typevars=[:T], fields=[JLField(;name=:x, type=Int)])\nstruct Foo{T}\n    x::Int64\nend\n```\n\nDecompose a Julia struct expression\n\n```julia\njulia> ex = :(struct Foo{T}\n           x::Int64\n       end)\n:(struct Foo{T}\n      #= REPL[31]:2 =#\n      x::Int64\n  end)\n\njulia> jl = JLStruct(ex)\nstruct Foo{T}\n    #= REPL[31]:2 =#\n    x::Int64\nend\n```\n\nGenerate a Julia struct expression\n\n```julia\njulia> codegen_ast(jl)\n:(struct Foo{T}\n      #= REPL[31]:2 =#\n      x::Int64\n  end)\n```\n" mutable struct JLStruct <: JLExpr
            name::Symbol
            ismutable::Bool
            typevars::Vector{Any}
            supertype::Any
            fields::Vector{JLField}
            constructors::Vector{JLFunction}
            line::Maybe{LineNumberNode}
            doc::Maybe{Union{String, Expr}}
            misc::Any
        end
    function JLStruct(; name::Symbol, ismutable::Bool = false, typevars = [], supertype = nothing, fields = JLField[], constructors = JLFunction[], line = nothing, doc = nothing, misc = nothing)
        JLStruct(name, ismutable, typevars, supertype, fields, constructors, line, doc, misc)
    end
    #= none:320 =# Core.@doc "    mutable struct JLKwStruct <: JLExpr\n    JLKwStruct(;kw...)\n\nType describes a Julia struct that allows keyword definition of defaults.\nThis syntax is similar to [`JLStruct`](@ref) except\nthe the fields are of type [`JLKwField`](@ref).\n\n# Fields and Keyword Arguments\n\n$(__DEFAULT_KWARG_DOC__)\nThe only required keyword argument for the constructor\nis `name`, the rest are all optional.\n\n- `name::Symbol`: name of the struct, this is the only required keyword argument.\n- `typealias::String`: an alias of the [`JLKwStruct`](@ref),\n    see also the `@option` macro in [Configurations.jl](https://github.com/Roger-luo/Configurations.jl).\n- `ismutable::Bool`: if the struct definition is mutable.\n- `typevars::Vector{Any}`: type variables of the struct, should be `Symbol` or `Expr`.\n- `supertype`: supertype of the struct definition.\n- `fields::Vector{JLField}`: field definitions of the struct, should be a [`JLField`](@ref).\n- `constructors::Vector{JLFunction}`: constructors definitions of the struct, should be [`JLFunction`](@ref).\n- `line::LineNumberNode`: a `LineNumberNode` to indicate the definition position for error report etc.\n- `doc::String`: documentation string of the struct.\n- `misc`: other things that happens inside the struct body, by definition this will\n    just fall through and is equivalent to eval them outside the struct body.\n" mutable struct JLKwStruct <: JLExpr
            name::Symbol
            typealias::Maybe{String}
            ismutable::Bool
            typevars::Vector{Any}
            supertype::Any
            fields::Vector{JLKwField}
            constructors::Vector{JLFunction}
            line::Maybe{LineNumberNode}
            doc::Maybe{Union{String, Expr}}
            misc::Any
        end
    function JLKwStruct(; name::Symbol, typealias::Maybe{String} = nothing, ismutable::Bool = false, typevars = [], supertype = nothing, fields = JLKwField[], constructors = JLFunction[], line = nothing, doc = nothing, misc = nothing)
        JLKwStruct(name, typealias, ismutable, typevars, supertype, fields, constructors, line, doc, misc)
    end
    #= none:367 =# Core.@doc "    JLIfElse <: JLExpr\n    JLIfElse(;kw...)\n\n`JLIfElse` describes a Julia `if ... elseif ... else ... end` expression. It allows one to easily construct\nsuch expression by inserting condition and code block via a map.\n\n# Fields and Keyword Arguments\n\n$(__DEFAULT_KWARG_DOC__)\n\n- `conds::Vector{Any}`: expression for the conditions.\n- `stmts::Vector{Any}`: expression for the statements for corresponding condition.\n- `otherwise`: the `else` body.\n\n# Example\n\n### Construct JLIfElse object\n\nOne can construct an `ifelse` as following\n\n```julia\njulia> jl = JLIfElse()\nnothing\n\njulia> jl[:(foo(x))] = :(x = 1 + 1)\n:(x = 1 + 1)\n\njulia> jl[:(goo(x))] = :(y = 1 + 2)\n:(y = 1 + 2)\n\njulia> jl.otherwise = :(error(\"abc\"))\n:(error(\"abc\"))\n\njulia> jl\nif foo(x)\n    x = 1 + 1\nelseif goo(x)\n    y = 1 + 2\nelse\n    error(\"abc\")\nend\n```\n\n### Generate the Julia `Expr` object\n\nto generate the corresponding `Expr` object, one can call [`codegen_ast`](@ref).\n\n```julia\njulia> codegen_ast(jl)\n:(if foo(x)\n      x = 1 + 1\n  elseif goo(x)\n      y = 1 + 2\n  else\n      error(\"abc\")\n  end)\n```\n" mutable struct JLIfElse <: JLExpr
            conds::Vector{Any}
            stmts::Vector{Any}
            otherwise::Any
        end
    JLIfElse(; conds = [], stmts = [], otherwise = nothing) = begin
            JLIfElse(conds, stmts, otherwise)
        end
    function Base.getindex(jl::JLIfElse, cond)
        idx = findfirst(jl.conds) do x
                cond == x
            end
        idx === nothing && error("cannot find condition: $(cond)")
        return jl.stmts[idx]
    end
    function Base.setindex!(jl::JLIfElse, stmt, cond)
        idx = findfirst(jl.conds) do x
                x == cond
            end
        if idx === nothing
            push!(jl.conds, cond)
            push!(jl.stmts, stmt)
        else
            jl.stmts[idx] = stmt
        end
        return stmt
    end
    Base.length(jl::JLIfElse) = begin
            length(jl.conds)
        end
    function Base.iterate(jl::JLIfElse, st = 1)
        st > length(jl) && return nothing
        (jl.conds[st] => jl.stmts[st], st + 1)
    end
    #= none:461 =# Core.@doc "    JLFor <: JLExpr\n\nSyntax type for Julia for loop.\n" struct JLFor <: JLExpr
            vars::Vector{Any}
            iterators::Vector{Any}
            kernel::Any
        end
    #= none:472 =# Core.@doc "    JLFor(;vars=[], iterators=[], kernel=nothing)\n\nGenerate a `JLFor` object.\n\n# Kwargs\n\n- `vars`: loop variables.\n- `iterators`: loop iterators.\n- `kernel`: loop kernel.\n" JLFor(; vars = [], iterators = [], kernel = nothing) = begin
                JLFor(vars, iterators, kernel)
            end
    #= none:485 =# Core.@doc "    JLFor(kernel, iterators::Vector)\n\nConvenient constructor for creating multiple loop expression\nfrom a list of iterators.\n\n# Example\n\n```julia\njulia> JLFor([:it1, :it2, :it3]) do i, j, k\n    :(kernel_function_call(\$i, \$j, \$k))\nend\nfor ##i#291 = it1, ##i#292 = it2, ##i#293 = it3\n    kernel_function_call(##i#291, ##i#292, ##i#293)\nend\n```\n" function JLFor(kernel, iterators::Vector)
            vars = map((_->begin
                            gensym(:i)
                        end), iterators)
            return JLFor(vars, iterators, kernel(vars...))
        end
