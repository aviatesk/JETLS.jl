
    #= none:2 =# Core.@doc "    codegen_ast(def)\n\nGenerate Julia AST object `Expr` from a given syntax type.\n\n# Example\n\nOne can generate the Julia AST object from a `JLKwStruct` syntax\ntype.\n\n```julia\njulia> def = @expr JLKwStruct struct Foo{N, T}\n                  x::T = 1\n              end\n#= kw =# struct Foo{N, T}\n    #= REPL[19]:2 =#\n    x::T = 1\nend\n\njulia> codegen_ast(def)|>rm_lineinfo\nquote\n    struct Foo{N, T}\n        x::T\n    end\n    begin\n        function Foo{N, T}(; x = 1) where {N, T}\n            Foo{N, T}(x)\n        end\n        function Foo{N}(; x::T = 1) where {N, T}\n            Foo{N, T}(x)\n        end\n    end\nend\n```\n" codegen_ast(ex) = begin
                ex
            end
    function codegen_ast(def::JLCall)
        call = Expr(:call, def.func)
        isnothing(def.kwargs) || push!(call.args, Expr(:parameters, def.kwargs...))
        append!(call.args, def.args)
        return call
    end
    function codegen_ast(def::JLFor)
        lhead = Expr(:block)
        for (var, itr) = zip(def.vars, def.iterators)
            push!(lhead.args, :($var = $itr))
        end
        return Expr(:for, lhead, codegen_ast(def.kernel))
    end
    function codegen_ast(def::JLIfElse)
        isempty(def.conds) && return def.otherwise
        stmt = (ex = Expr(:if))
        for (k, (cond, action)) = enumerate(def)
            push!(stmt.args, cond)
            push!(stmt.args, rm_single_block(Expr(:block, codegen_ast(action))))
            if k !== length(def)
                push!(stmt.args, Expr(:elseif))
                stmt = stmt.args[end]
            end
        end
        def.otherwise === nothing || push!(stmt.args, codegen_ast(def.otherwise))
        return ex
    end
    #= none:70 =# @static if VERSION < v"1.10-"
            function codegen_ast(fn::JLFunction)
                if fn.head === :function && (fn.name === nothing && (fn.kwargs !== nothing && (isone(length(fn.args)) && isone(length(fn.kwargs)))))
                    kw = (fn.kwargs[1]).args[1]
                    va = (fn.kwargs[1]).args[2]
                    call = Expr(:block, fn.args[1], :($kw = $va))
                else
                    if fn.name === nothing
                        call = Expr(:tuple)
                    else
                        call = Expr(:call, fn.name)
                    end
                    if fn.kwargs !== nothing
                        push!(call.args, Expr(:parameters, fn.kwargs...))
                    end
                    append!(call.args, fn.args)
                end
                if fn.rettype !== nothing
                    call = Expr(:(::), call, fn.rettype)
                end
                if fn.whereparams !== nothing && !(isempty(fn.whereparams))
                    call = Expr(:where, call, fn.whereparams...)
                end
                fn_def = Expr(fn.head, call, maybe_wrap_block(codegen_ast(fn.body)))
                fn_def = codegen_ast_generated(fn, fn_def)
                return codegen_ast_docstring(fn, fn_def)
            end
        else
            function codegen_ast(fn::JLFunction)
                if fn.name === nothing
                    call = Expr(:tuple)
                else
                    call = Expr(:call, fn.name)
                end
                if fn.kwargs !== nothing
                    push!(call.args, Expr(:parameters, fn.kwargs...))
                end
                append!(call.args, fn.args)
                if fn.rettype !== nothing
                    call = Expr(:(::), call, fn.rettype)
                end
                if fn.whereparams !== nothing && !(isempty(fn.whereparams))
                    call = Expr(:where, call, fn.whereparams...)
                end
                fn_def = Expr(fn.head, call, maybe_wrap_block(codegen_ast(fn.body)))
                fn_def = codegen_ast_generated(fn, fn_def)
                return codegen_ast_docstring(fn, fn_def)
            end
        end
    function codegen_ast(def::JLStruct)
        return codegen_ast_struct(def)
    end
    function codegen_ast(def::JLKwStruct)
        quote
            $(codegen_ast_struct(def))
            $(codegen_ast_kwfn(def))
            nothing
        end
    end
    function maybe_wrap_block(ex::Expr)
        ex.head === :block && return ex
        return Expr(:block, ex)
    end
    #= none:148 =# Core.@doc "    codegen_ast_kwfn(def[, name = nothing])\n\nGenerate the keyword function from a Julia struct definition.\n\n# Example\n\n```julia\njulia> def = @expr JLKwStruct struct Foo{N, T}\n                  x::T = 1\n              end\n#= kw =# struct Foo{N, T}\n    #= REPL[19]:2 =#\n    x::T = 1\nend\n\njulia> codegen_ast_kwfn(def)|>prettify\nquote\n    function Foo{N, T}(; x = 1) where {N, T}\n        Foo{N, T}(x)\n    end\n    function Foo{N}(; x::T = 1) where {N, T}\n        Foo{N, T}(x)\n    end\nend\n\njulia> def = @expr JLKwStruct struct Foo\n                  x::Int = 1\n              end\n#= kw =# struct Foo\n    #= REPL[23]:2 =#\n    x::Int = 1\nend\n\njulia> codegen_ast_kwfn(def)|>prettify\nquote\n    function Foo(; x = 1)\n        Foo(x)\n    end\n    nothing\nend\n```\n" function codegen_ast_kwfn(def, name = nothing)
            quote
                $(codegen_ast_kwfn_plain(def, name))
                $(codegen_ast_kwfn_infer(def, name))
            end
        end
    #= none:198 =# Core.@doc "    codegen_ast_kwfn_plain(def[, name = nothing])\n\nGenerate the plain keyword function that does not infer type variables.\nSo that one can use the type conversions defined by constructors.\n" function codegen_ast_kwfn_plain(def, name = nothing)
            isempty(def.fields) && return nothing
            struct_name = struct_name_plain(def)
            if name === nothing
                name = struct_name
                args = []
                whereparams = if isempty(def.typevars)
                        nothing
                    else
                        name_only.(def.typevars)
                    end
            else
                #= none:213 =# @gensym T
                args = [:(::Type{$T})]
                whereparams = [name_only.(def.typevars)..., :($T <: $struct_name)]
            end
            has_kwfn_constructor(def, name) && return nothing
            kwfn_def = JLFunction(; name = name, args = args, kwargs = codegen_ast_fields(def.fields; just_name = true), whereparams = whereparams, body = Expr(:call, struct_name, [field.name for field = def.fields]...))
            return codegen_ast(kwfn_def)
        end
    #= none:236 =# Core.@doc "    codegen_ast_kwfn_infer(def, name = nothing)\n\nGenerate the keyword function that infers the type.\n" function codegen_ast_kwfn_infer(def, name = nothing)
            isempty(def.typevars) && return nothing
            struct_name = struct_name_without_inferable(def)
            requires = uninferrable_typevars(def)
            length(requires) == length(def.typevars) && return nothing
            if name === nothing
                name = struct_name
                args = []
                whereparams = if isempty(requires)
                        nothing
                    else
                        requires
                    end
            else
                #= none:254 =# @gensym T
                ub = if isempty(requires)
                        def.name
                    else
                        Expr(:curly, def.name, requires...)
                    end
                args = [:(::Type{$T})]
                whereparams = [requires..., :($T <: $ub)]
            end
            has_kwfn_constructor(def, name) && return nothing
            kwfn_def = JLFunction(; name = name, args = args, kwargs = codegen_ast_fields(def.fields; just_name = true), whereparams = whereparams, body = Expr(:call, struct_name, [field.name for field = def.fields]...))
            return codegen_ast(kwfn_def)
        end
    #= none:276 =# Core.@doc "    codegen_ast_fields(fields; just_name::Bool=true)\n\nGenerate a list of Julia AST object for each field, only generate\na list of field names by default, option `just_name` can be turned\noff to call [`codegen_ast`](@ref) on each field object.\n" function codegen_ast_fields(fields; just_name::Bool = true)
            map(fields) do field
                name = if just_name
                        field.name
                    else
                        codegen_ast(field)
                    end
                support_default(field) || return name
                if field.default === no_default
                    name
                else
                    Expr(:kw, name, field.default)
                end
            end
        end
    #= none:296 =# Core.@doc "    struct_name_plain(def)\n\nPlain constructor name. See also [`struct_name_without_inferable`](@ref).\n\n# Example\n\n```julia\njulia> def = @expr JLKwStruct struct Foo{N, Inferable}\n    x::Inferable = 1\nend\n\njulia> struct_name_plain(def)\n:(Foo{N, Inferable})\n```\n" function struct_name_plain(def)
            isempty(def.typevars) && return def.name
            return Expr(:curly, def.name, name_only.(def.typevars)...)
        end
    #= none:317 =# Core.@doc "    struct_name_without_inferable(def; leading_inferable::Bool=true)\n\nConstructor name that assume some of the type variables is inferred.\nSee also [`struct_name_plain`](@ref). The kwarg `leading_inferable`\ncan be used to configure whether to preserve the leading inferable\ntype variables, the default is `true` to be consistent with the\ndefault julia constructors.\n\n# Example\n\n```julia\njulia> def = @expr JLKwStruct struct Foo{N, Inferable}\n    x::Inferable = 1\nend\n\njulia> struct_name_without_inferable(def)\n:(Foo{N})\n\njulia> def = @expr JLKwStruct struct Foo{Inferable, NotInferable}\n    x::Inferable\nend\n\njulia> struct_name_without_inferable(def; leading_inferable=true)\n:(Foo{Inferable, NotInferable})\n\njulia> struct_name_without_inferable(def; leading_inferable=false)\n:(Foo{NotInferable})\n```\n" function struct_name_without_inferable(def; leading_inferable::Bool = true)
            isempty(def.typevars) && return def.name
            required_typevars = uninferrable_typevars(def; leading_inferable = leading_inferable)
            isempty(required_typevars) && return def.name
            return Expr(:curly, def.name, required_typevars...)
        end
    function codegen_ast_docstring(def, body)
        def.doc === nothing && return body
        Expr(:macrocall, GlobalRef(Core, Symbol("@doc")), def.line, def.doc, body)
    end
    function codegen_ast_generated(def::JLFunction, body)
        def.generated || return body
        return Expr(:macrocall, Expr(:., Base, QuoteNode(Symbol("@generated"))), def.line, body)
    end
    #= none:364 =# Core.@doc "    codegen_ast_struct_head(def)\n\nGenerate the struct head.\n\n# Example\n\n```julia\njulia> using Expronicon\n\njulia> def = JLStruct(:(struct Foo{T} end))\nstruct Foo{T}\nend\n\njulia> codegen_ast_struct_head(def)\n:(Foo{T})\n\njulia> def = JLStruct(:(struct Foo{T} <: AbstractArray end))\nstruct Foo{T} <: AbstractArray\nend\n\njulia> codegen_ast_struct_head(def)\n:(Foo{T} <: AbstractArray)\n```\n" function codegen_ast_struct_head(def)
            head = def.name::Symbol
            if !(isempty(def.typevars))
                head = Expr(:curly, head, def.typevars...)
            end
            if def.supertype !== nothing
                head = Expr(:<:, head, def.supertype)
            end
            return head
        end
    #= none:401 =# Core.@doc "    codegen_ast_struct_body(def)\n\nGenerate the struct body.\n\n# Example\n\n```julia\njulia> def = JLStruct(:(struct Foo\n           x::Int\n           \n           Foo(x::Int) = new(x)\n       end))\nstruct Foo\n    x::Int\nend\n\njulia> codegen_ast_struct_body(def)\nquote\n    #= REPL[15]:2 =#\n    x::Int\n    Foo(x::Int) = begin\n            #= REPL[15]:4 =#\n            new(x)\n        end\nend\n```\n" function codegen_ast_struct_body(def)
            body = Expr(:block)
            for field = def.fields
                field.line === nothing || push!(body.args, field.line)
                field.doc === nothing || push!(body.args, field.doc)
                push!(body.args, codegen_ast(field))
            end
            for constructor = def.constructors
                push!(body.args, codegen_ast(constructor))
            end
            body = flatten_blocks(body)
            def.misc === nothing || append!(body.args, def.misc)
            return body
        end
    #= none:446 =# Core.@doc "    codegen_ast_struct(def)\n\nGenerate pure Julia struct `Expr` from struct definition. This is equivalent\nto `codegen_ast` for `JLStruct`. See also [`codegen_ast`](@ref).\n\n# Example\n\n```julia-repl\njulia> def = JLKwStruct(:(struct Foo\n           x::Int=1\n           \n           Foo(x::Int) = new(x)\n       end))\nstruct Foo\n    x::Int = 1\nend\n\njulia> codegen_ast_struct(def)\n:(struct Foo\n      #= REPL[21]:2 =#\n      x::Int\n      Foo(x::Int) = begin\n              #= REPL[21]:4 =#\n              new(x)\n          end\n  end)\n```\n" function codegen_ast_struct(def)
            head = codegen_ast_struct_head(def)
            body = codegen_ast_struct_body(def)
            ex = Expr(:struct, def.ismutable, head, body)
            return codegen_ast_docstring(def, ex)
        end
    function codegen_ast(def::Union{JLField, JLKwField})
        expr = if def.type === Any
                def.name
            else
                :($(def.name)::$(def.type))
            end
        #= none:489 =# @static if VERSION > v"1.8-"
                def.isconst && return Expr(:const, expr)
            end
        return expr
    end
    #= none:497 =# Core.@doc "    xtuple(xs...)\n\nCreate a `Tuple` expression.\n" xtuple(xs...) = begin
                Expr(:tuple, xs...)
            end
    #= none:504 =# Core.@doc "    xnamedtuple(;kw...)\n\nCreate a `NamedTuple` expression.\n" function xnamedtuple(; kw...)
            ex = Expr(:tuple)
            for (k, v) = kw
                push!(ex.args, :($k = $v))
            end
            return ex
        end
    #= none:517 =# Core.@doc "    xcall(name, args...; kw...)\n\nCreate a function call to `name`.\n" function xcall(name, args...; kw...)
            isempty(kw) && return Expr(:call, name, args...)
            p = Expr(:parameters)
            for (k, v) = kw
                push!(p.args, Expr(:kw, k, v))
            end
            Expr(:call, name, p, args...)
        end
    #= none:531 =# Core.@doc "    xcall(m::Module, name::Symbol, args...; kw...)\n\nCreate a function call to `GlobalRef(m, name)`.\n\n!!! tip\n\n    due to [Revise/#616](https://github.com/timholy/Revise.jl/issues/616),\n    to make your macro work with Revise, we use the dot expression\n    `Expr(:., <module>, QuoteNode(<name>))` instead of `GlobalRef` here.\n" function xcall(m::Module, name::Symbol, args...; kw...)
            xcall(Expr(:., m, QuoteNode(name)), args...; kw...)
        end
    #= none:547 =# Core.@doc "    xgetindex(collection, key...)\n\nCreate a function call expression to `Base.getindex`.\n" xgetindex(coll, key...) = begin
                xcall(Base, :getindex, coll, key...)
            end
    #= none:554 =# Core.@doc "    xpush(collection, items...)\n\nCreate a function call expression to `Base.push!`.\n" function xpush(collection, items...)
            xcall(Base, :push!, collection, items...)
        end
    #= none:563 =# Core.@doc "    xfirst(collection)\n\nCreate a function call expression to `Base.first`.\n" xfirst(collection) = begin
                xcall(Base, :first, collection)
            end
    #= none:570 =# Core.@doc "    xlast(collection)\n\nCreate a function call expression to `Base.last`.\n" xlast(collection) = begin
                xcall(Base, :last, collection)
            end
    #= none:577 =# Core.@doc "    xprint(xs...)\n\nCreate a function call expression to `Base.print`.\n" xprint(xs...) = begin
                xcall(Base, :print, xs...)
            end
    #= none:584 =# Core.@doc "    xprintln(xs...)\n\nCreate a function call expression to `Base.println`.\n" xprintln(xs...) = begin
                xcall(Base, :println, xs...)
            end
    #= none:591 =# Core.@doc "    xmap(f, xs...)\n\nCreate a function call expression to `Base.map`.\n" xmap(f, xs...) = begin
                xcall(Base, :map, f, xs...)
            end
    #= none:598 =# Core.@doc "    xmapreduce(f, op, xs...)\n\nCreate a function call expression to `Base.mapreduce`.\n" xmapreduce(f, op, xs...) = begin
                xcall(Base, :mapreduce, f, op, xs...)
            end
    #= none:605 =# Core.@doc "    xiterate(it)\n\nCreate a function call expression to `Base.iterate`.\n" xiterate(it) = begin
                xcall(Base, :iterate, it)
            end
    #= none:612 =# Core.@doc "    xiterate(it, st)\n\nCreate a function call expression to `Base.iterate`.\n" xiterate(it, st) = begin
                xcall(Base, :iterate, it, st)
            end
