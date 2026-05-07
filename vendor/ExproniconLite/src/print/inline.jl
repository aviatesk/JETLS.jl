
    #= none:1 =# Base.@kwdef mutable struct InlinePrinterState
            type::Bool = false
            symbol::Bool = false
            call::Bool = false
            macrocall::Bool = false
            quoted::Bool = false
            keyword::Bool = false
            loop_iterator::Bool = false
            block::Bool = true
            precedence::Int = 0
        end
    function with(f::Function, p::InlinePrinterState, name::Symbol, new)
        old = getfield(p, name)
        setfield!(p, name, new)
        f()
        setfield!(p, name, old)
    end
    struct InlinePrinter{IO_t <: IO}
        io::IO_t
        color::ColorScheme
        line::Bool
        state::InlinePrinterState
    end
    function InlinePrinter(io::IO; color::ColorScheme = Monokai256(), line::Bool = false)
        InlinePrinter(io, color, line, InlinePrinterState())
    end
    function (p::InlinePrinter)(x, xs...; delim = ", ")
        p(x)
        for x = xs
            printstyled(p.io, delim; color = p.color.keyword)
            p(x)
        end
    end
    function (p::InlinePrinter)(expr)
        c = p.color
        print(xs...) = begin
                Base.print(p.io, xs...)
            end
        printstyled(xs...; kw...) = begin
                Base.printstyled(p.io, xs...; kw...)
            end
        function join(xs, delim = ", ")
            if !(p.line)
                xs = filter(!is_line_no, xs)
            end
            for (i, x) = enumerate(xs)
                p(x)
                i < length(xs) && keyword(delim)
            end
        end
        function print_braces(xs, open, close, delim = ", ")
            print(open)
            join(xs, delim)
            print(close)
        end
        string(s) = begin
                printstyled(repr(s); color = c.string)
            end
        keyword(s) = begin
                printstyled(s, color = c.keyword)
            end
        assign() = begin
                if p.state.loop_iterator
                    keyword(" in ")
                else
                    keyword(" = ")
                end
            end
        function symbol(ex)
            color = if p.state.type
                    c.type
                elseif p.state.quoted
                    c.quoted
                elseif p.state.call
                    c.call
                elseif p.state.macrocall
                    c.macrocall
                else
                    :normal
                end
            is_gensym(ex) && printstyled("var\""; color = color)
            printstyled(ex, color = color)
            is_gensym(ex) && printstyled("\""; color = color)
        end
        quoted(ex) = begin
                with((()->begin
                            p(ex)
                        end), p.state, :quoted, true)
            end
        type(ex) = begin
                with((()->begin
                            p(ex)
                        end), p.state, :type, true)
            end
        function call(ex)
            omit_parent = let
                    begin
                        var"##cache#815" = nothing
                    end
                    var"##return#812" = nothing
                    var"##814" = ex
                    if var"##814" isa Expr
                        if begin
                                    if var"##cache#815" === nothing
                                        var"##cache#815" = Some(((var"##814").head, (var"##814").args))
                                    end
                                    var"##816" = (var"##cache#815").value
                                    var"##816" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##816"[1] == :. && (begin
                                            var"##817" = var"##816"[2]
                                            var"##817" isa AbstractArray
                                        end && (ndims(var"##817") === 1 && length(var"##817") >= 0)))
                            var"##return#812" = let
                                    true
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#813#818")))
                        end
                    end
                    if var"##814" isa Symbol
                        begin
                            var"##return#812" = let
                                    true
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#813#818")))
                        end
                    end
                    begin
                        var"##return#812" = let
                                false
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#813#818")))
                    end
                    error("matching non-exhaustive, at #= none:85 =#")
                    $(Expr(:symboliclabel, Symbol("####final#813#818")))
                    var"##return#812"
                end
            omit_parent || print("(")
            with((()->begin
                        p(ex)
                    end), p.state, :call, true)
            omit_parent || print(")")
        end
        macrocall(ex) = begin
                with((()->begin
                            p(ex)
                        end), p.state, :macrocall, true)
            end
        noblock(ex) = begin
                with((()->begin
                            p(ex)
                        end), p.state, :block, false)
            end
        block(ex) = begin
                with((()->begin
                            p(ex)
                        end), p.state, :block, true)
            end
        function precedence(f, s)
            if s isa Int
                preced = s
            else
                preced = Base.operator_precedence(s)
            end
            require = preced > 0 && p.state.precedence > 0
            require && (p.state.precedence >= preced && print('('))
            with(f, p.state, :precedence, preced)
            require && (p.state.precedence >= preced && print(')'))
        end
        function print_call(ex)
            begin
                begin
                    var"##cache#822" = nothing
                end
                var"##821" = ex
                if var"##821" isa Expr && (begin
                                if var"##cache#822" === nothing
                                    var"##cache#822" = Some(((var"##821").head, (var"##821").args))
                                end
                                var"##823" = (var"##cache#822").value
                                var"##823" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##823"[1] == :call && (begin
                                        var"##824" = var"##823"[2]
                                        var"##824" isa AbstractArray
                                    end && ((ndims(var"##824") === 1 && length(var"##824") >= 1) && (var"##824"[1] == :(:) && begin
                                                var"##825" = SubArray(var"##824", (2:length(var"##824"),))
                                                true
                                            end)))))
                    args = var"##825"
                    var"##return#819" = begin
                            precedence(:(:)) do 
                                join(args, ":")
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#820#847")))
                end
                if var"##821" isa Expr && (begin
                                if var"##cache#822" === nothing
                                    var"##cache#822" = Some(((var"##821").head, (var"##821").args))
                                end
                                var"##826" = (var"##cache#822").value
                                var"##826" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##826"[1] == :call && (begin
                                        var"##827" = var"##826"[2]
                                        var"##827" isa AbstractArray
                                    end && (length(var"##827") === 2 && (begin
                                                var"##828" = var"##827"[1]
                                                var"##828" isa Symbol
                                            end && begin
                                                var"##829" = var"##827"[2]
                                                let f = var"##828", arg = var"##829"
                                                    Base.isunaryoperator(f)
                                                end
                                            end)))))
                    f = var"##828"
                    arg = var"##829"
                    var"##return#819" = begin
                            precedence(typemax(Int)) do 
                                keyword(f)
                                p(arg)
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#820#847")))
                end
                if var"##821" isa Expr && (begin
                                if var"##cache#822" === nothing
                                    var"##cache#822" = Some(((var"##821").head, (var"##821").args))
                                end
                                var"##830" = (var"##cache#822").value
                                var"##830" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##830"[1] == :call && (begin
                                        var"##831" = var"##830"[2]
                                        var"##831" isa AbstractArray
                                    end && ((ndims(var"##831") === 1 && length(var"##831") >= 1) && (begin
                                                var"##832" = var"##831"[1]
                                                var"##832" isa Symbol
                                            end && begin
                                                var"##833" = SubArray(var"##831", (2:length(var"##831"),))
                                                let f = var"##832", args = var"##833"
                                                    Base.isbinaryoperator(f)
                                                end
                                            end)))))
                    f = var"##832"
                    args = var"##833"
                    var"##return#819" = begin
                            precedence(f) do 
                                join(args, " $(f) ")
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#820#847")))
                end
                if var"##821" isa Expr && (begin
                                if var"##cache#822" === nothing
                                    var"##cache#822" = Some(((var"##821").head, (var"##821").args))
                                end
                                var"##834" = (var"##cache#822").value
                                var"##834" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##834"[1] == :call && (begin
                                        var"##835" = var"##834"[2]
                                        var"##835" isa AbstractArray
                                    end && ((ndims(var"##835") === 1 && length(var"##835") >= 2) && (begin
                                                var"##836" = var"##835"[1]
                                                begin
                                                    var"##cache#838" = nothing
                                                end
                                                var"##837" = var"##835"[2]
                                                var"##837" isa Expr
                                            end && (begin
                                                    if var"##cache#838" === nothing
                                                        var"##cache#838" = Some(((var"##837").head, (var"##837").args))
                                                    end
                                                    var"##839" = (var"##cache#838").value
                                                    var"##839" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##839"[1] == :parameters && (begin
                                                            var"##840" = var"##839"[2]
                                                            var"##840" isa AbstractArray
                                                        end && ((ndims(var"##840") === 1 && length(var"##840") >= 0) && begin
                                                                var"##841" = SubArray(var"##840", (1:length(var"##840"),))
                                                                var"##842" = SubArray(var"##835", (3:length(var"##835"),))
                                                                true
                                                            end)))))))))
                    f = var"##836"
                    args = var"##842"
                    kwargs = var"##841"
                    var"##return#819" = begin
                            call(f)
                            print("(")
                            join(args)
                            keyword("; ")
                            join(kwargs)
                            print(")")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#820#847")))
                end
                if var"##821" isa Expr && (begin
                                if var"##cache#822" === nothing
                                    var"##cache#822" = Some(((var"##821").head, (var"##821").args))
                                end
                                var"##843" = (var"##cache#822").value
                                var"##843" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##843"[1] == :call && (begin
                                        var"##844" = var"##843"[2]
                                        var"##844" isa AbstractArray
                                    end && ((ndims(var"##844") === 1 && length(var"##844") >= 1) && begin
                                            var"##845" = var"##844"[1]
                                            var"##846" = SubArray(var"##844", (2:length(var"##844"),))
                                            true
                                        end))))
                    f = var"##845"
                    args = var"##846"
                    var"##return#819" = begin
                            call(f)
                            print_braces(args, "(", ")")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#820#847")))
                end
                error("matching non-exhaustive, at #= none:111 =#")
                $(Expr(:symboliclabel, Symbol("####final#820#847")))
                var"##return#819"
            end
        end
        function print_function(head, call, body)
            keyword("$(head) ")
            p(call)
            keyword("; ")
            join(split_body(body), ";")
            keyword("; end")
        end
        function print_expr(ex)
            begin
                begin
                    var"##cache#851" = nothing
                end
                var"##850" = ex
                if var"##850" isa Char
                    begin
                        var"##return#848" = begin
                                printstyled(repr(ex), color = c.string)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa Nothing
                    begin
                        var"##return#848" = begin
                                printstyled("nothing", color = c.number)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa Symbol
                    begin
                        var"##return#848" = begin
                                symbol(ex)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa Expr
                    if begin
                                if var"##cache#851" === nothing
                                    var"##cache#851" = Some(((var"##850").head, (var"##850").args))
                                end
                                var"##852" = (var"##cache#851").value
                                var"##852" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##852"[1] == :line && (begin
                                        var"##853" = var"##852"[2]
                                        var"##853" isa AbstractArray
                                    end && (length(var"##853") === 2 && begin
                                            var"##854" = var"##853"[1]
                                            var"##855" = var"##853"[2]
                                            true
                                        end)))
                        line = var"##855"
                        file = var"##854"
                        var"##return#848" = begin
                                p.line || return nothing
                                printstyled("#= $(file):$(line) =#", color = c.line)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##856" = (var"##cache#851").value
                                var"##856" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##856"[1] == :kw && (begin
                                        var"##857" = var"##856"[2]
                                        var"##857" isa AbstractArray
                                    end && (length(var"##857") === 2 && begin
                                            var"##858" = var"##857"[1]
                                            var"##859" = var"##857"[2]
                                            true
                                        end)))
                        k = var"##858"
                        v = var"##859"
                        var"##return#848" = begin
                                p(k)
                                print(" = ")
                                p(v)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##860" = (var"##cache#851").value
                                var"##860" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##860"[1] == :(=) && (begin
                                        var"##861" = var"##860"[2]
                                        var"##861" isa AbstractArray
                                    end && (length(var"##861") === 2 && (begin
                                                var"##862" = var"##861"[1]
                                                begin
                                                    var"##cache#864" = nothing
                                                end
                                                var"##863" = var"##861"[2]
                                                var"##863" isa Expr
                                            end && (begin
                                                    if var"##cache#864" === nothing
                                                        var"##cache#864" = Some(((var"##863").head, (var"##863").args))
                                                    end
                                                    var"##865" = (var"##cache#864").value
                                                    var"##865" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##865"[1] == :block && (begin
                                                            var"##866" = var"##865"[2]
                                                            var"##866" isa AbstractArray
                                                        end && ((ndims(var"##866") === 1 && length(var"##866") >= 0) && begin
                                                                var"##867" = SubArray(var"##866", (1:length(var"##866"),))
                                                                true
                                                            end))))))))
                        k = var"##862"
                        stmts = var"##867"
                        var"##return#848" = begin
                                precedence(:(=)) do 
                                    if length(stmts) == 2 && count(!is_line_no, stmts) == 1
                                        p(k)
                                        assign()
                                        p.line && (is_line_no(stmts[1]) && p(stmts[1]))
                                        p(stmts[end])
                                    else
                                        p(k)
                                        assign()
                                        p(ex.args[2])
                                    end
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##868" = (var"##cache#851").value
                                var"##868" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##868"[1] == :(=) && (begin
                                        var"##869" = var"##868"[2]
                                        var"##869" isa AbstractArray
                                    end && (length(var"##869") === 2 && begin
                                            var"##870" = var"##869"[1]
                                            var"##871" = var"##869"[2]
                                            true
                                        end)))
                        k = var"##870"
                        v = var"##871"
                        var"##return#848" = begin
                                precedence(:(=)) do 
                                    p(k)
                                    assign()
                                    p(v)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##872" = (var"##cache#851").value
                                var"##872" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##872"[1] == :... && (begin
                                        var"##873" = var"##872"[2]
                                        var"##873" isa AbstractArray
                                    end && (length(var"##873") === 1 && begin
                                            var"##874" = var"##873"[1]
                                            true
                                        end)))
                        name = var"##874"
                        var"##return#848" = begin
                                precedence(:...) do 
                                    p(name)
                                    keyword("...")
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##875" = (var"##cache#851").value
                                var"##875" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##875"[1] == :& && (begin
                                        var"##876" = var"##875"[2]
                                        var"##876" isa AbstractArray
                                    end && (length(var"##876") === 1 && begin
                                            var"##877" = var"##876"[1]
                                            true
                                        end)))
                        name = var"##877"
                        var"##return#848" = begin
                                precedence(:&) do 
                                    keyword("&")
                                    p(name)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##878" = (var"##cache#851").value
                                var"##878" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##878"[1] == :(::) && (begin
                                        var"##879" = var"##878"[2]
                                        var"##879" isa AbstractArray
                                    end && (length(var"##879") === 1 && begin
                                            var"##880" = var"##879"[1]
                                            true
                                        end)))
                        t = var"##880"
                        var"##return#848" = begin
                                precedence(:(::)) do 
                                    keyword("::")
                                    type(t)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##881" = (var"##cache#851").value
                                var"##881" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##881"[1] == :(::) && (begin
                                        var"##882" = var"##881"[2]
                                        var"##882" isa AbstractArray
                                    end && (length(var"##882") === 2 && begin
                                            var"##883" = var"##882"[1]
                                            var"##884" = var"##882"[2]
                                            true
                                        end)))
                        name = var"##883"
                        t = var"##884"
                        var"##return#848" = begin
                                precedence(:(::)) do 
                                    p(name)
                                    keyword("::")
                                    type(t)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##885" = (var"##cache#851").value
                                var"##885" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##885"[1] == :$ && (begin
                                        var"##886" = var"##885"[2]
                                        var"##886" isa AbstractArray
                                    end && (length(var"##886") === 1 && begin
                                            var"##887" = var"##886"[1]
                                            true
                                        end)))
                        name = var"##887"
                        var"##return#848" = begin
                                precedence(:$) do 
                                    keyword('$')
                                    print("(")
                                    p(name)
                                    print(")")
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##888" = (var"##cache#851").value
                                var"##888" isa (Tuple{var1, var2} where {var2 <: AbstractArray, var1})
                            end && (begin
                                    var"##889" = var"##888"[1]
                                    var"##890" = var"##888"[2]
                                    var"##890" isa AbstractArray
                                end && (length(var"##890") === 2 && begin
                                        var"##891" = var"##890"[1]
                                        var"##892" = var"##890"[2]
                                        let rhs = var"##892", lhs = var"##891", head = var"##889"
                                            head in expr_infix_wide
                                        end
                                    end))
                        rhs = var"##892"
                        lhs = var"##891"
                        head = var"##889"
                        var"##return#848" = begin
                                precedence(head) do 
                                    p(lhs)
                                    keyword(" $(head) ")
                                    p(rhs)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##893" = (var"##cache#851").value
                                var"##893" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##893"[1] == :. && (begin
                                        var"##894" = var"##893"[2]
                                        var"##894" isa AbstractArray
                                    end && (length(var"##894") === 1 && begin
                                            var"##895" = var"##894"[1]
                                            true
                                        end)))
                        name = var"##895"
                        var"##return#848" = begin
                                print(name)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##896" = (var"##cache#851").value
                                var"##896" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##896"[1] == :. && (begin
                                        var"##897" = var"##896"[2]
                                        var"##897" isa AbstractArray
                                    end && (length(var"##897") === 2 && (begin
                                                var"##898" = var"##897"[1]
                                                var"##899" = var"##897"[2]
                                                var"##899" isa QuoteNode
                                            end && begin
                                                var"##900" = (var"##899").value
                                                true
                                            end))))
                        name = var"##900"
                        object = var"##898"
                        var"##return#848" = begin
                                precedence(:.) do 
                                    p(object)
                                    keyword(".")
                                    if name in Base.quoted_syms
                                        p(QuoteNode(name))
                                    else
                                        p(name)
                                    end
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##901" = (var"##cache#851").value
                                var"##901" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##901"[1] == :. && (begin
                                        var"##902" = var"##901"[2]
                                        var"##902" isa AbstractArray
                                    end && (length(var"##902") === 2 && begin
                                            var"##903" = var"##902"[1]
                                            var"##904" = var"##902"[2]
                                            true
                                        end)))
                        name = var"##904"
                        object = var"##903"
                        var"##return#848" = begin
                                precedence(:.) do 
                                    p(object)
                                    keyword(".")
                                    p(name)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##905" = (var"##cache#851").value
                                var"##905" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##905"[1] == :<: && (begin
                                        var"##906" = var"##905"[2]
                                        var"##906" isa AbstractArray
                                    end && (length(var"##906") === 2 && begin
                                            var"##907" = var"##906"[1]
                                            var"##908" = var"##906"[2]
                                            true
                                        end)))
                        type = var"##907"
                        supertype = var"##908"
                        var"##return#848" = begin
                                precedence(:<:) do 
                                    p(type)
                                    keyword(" <: ")
                                    p(supertype)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##909" = (var"##cache#851").value
                                var"##909" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##909"[1] == :call && (begin
                                        var"##910" = var"##909"[2]
                                        var"##910" isa AbstractArray
                                    end && (ndims(var"##910") === 1 && length(var"##910") >= 0)))
                        var"##return#848" = begin
                                print_call(ex)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##911" = (var"##cache#851").value
                                var"##911" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##911"[1] == :tuple && (begin
                                        var"##912" = var"##911"[2]
                                        var"##912" isa AbstractArray
                                    end && (length(var"##912") === 1 && (begin
                                                begin
                                                    var"##cache#914" = nothing
                                                end
                                                var"##913" = var"##912"[1]
                                                var"##913" isa Expr
                                            end && (begin
                                                    if var"##cache#914" === nothing
                                                        var"##cache#914" = Some(((var"##913").head, (var"##913").args))
                                                    end
                                                    var"##915" = (var"##cache#914").value
                                                    var"##915" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##915"[1] == :parameters && (begin
                                                            var"##916" = var"##915"[2]
                                                            var"##916" isa AbstractArray
                                                        end && ((ndims(var"##916") === 1 && length(var"##916") >= 0) && begin
                                                                var"##917" = SubArray(var"##916", (1:length(var"##916"),))
                                                                true
                                                            end))))))))
                        args = var"##917"
                        var"##return#848" = begin
                                print_braces(args, "(;", ")")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##918" = (var"##cache#851").value
                                var"##918" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##918"[1] == :tuple && (begin
                                        var"##919" = var"##918"[2]
                                        var"##919" isa AbstractArray
                                    end && ((ndims(var"##919") === 1 && length(var"##919") >= 0) && begin
                                            var"##920" = SubArray(var"##919", (1:length(var"##919"),))
                                            true
                                        end)))
                        args = var"##920"
                        var"##return#848" = begin
                                if length(args) == 1
                                    print("(")
                                    p(args[1])
                                    print(",)")
                                else
                                    print_braces(args, "(", ")")
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##921" = (var"##cache#851").value
                                var"##921" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##921"[1] == :curly && (begin
                                        var"##922" = var"##921"[2]
                                        var"##922" isa AbstractArray
                                    end && ((ndims(var"##922") === 1 && length(var"##922") >= 1) && begin
                                            var"##923" = var"##922"[1]
                                            var"##924" = SubArray(var"##922", (2:length(var"##922"),))
                                            true
                                        end)))
                        args = var"##924"
                        t = var"##923"
                        var"##return#848" = begin
                                with(p.state, :type, true) do 
                                    p(t)
                                    print_braces(args, "{", "}")
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##925" = (var"##cache#851").value
                                var"##925" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##925"[1] == :vect && (begin
                                        var"##926" = var"##925"[2]
                                        var"##926" isa AbstractArray
                                    end && ((ndims(var"##926") === 1 && length(var"##926") >= 0) && begin
                                            var"##927" = SubArray(var"##926", (1:length(var"##926"),))
                                            true
                                        end)))
                        args = var"##927"
                        var"##return#848" = begin
                                print_braces(args, "[", "]")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##928" = (var"##cache#851").value
                                var"##928" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##928"[1] == :hcat && (begin
                                        var"##929" = var"##928"[2]
                                        var"##929" isa AbstractArray
                                    end && ((ndims(var"##929") === 1 && length(var"##929") >= 0) && begin
                                            var"##930" = SubArray(var"##929", (1:length(var"##929"),))
                                            true
                                        end)))
                        args = var"##930"
                        var"##return#848" = begin
                                print_braces(args, "[", "]", " ")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##931" = (var"##cache#851").value
                                var"##931" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##931"[1] == :typed_hcat && (begin
                                        var"##932" = var"##931"[2]
                                        var"##932" isa AbstractArray
                                    end && ((ndims(var"##932") === 1 && length(var"##932") >= 1) && begin
                                            var"##933" = var"##932"[1]
                                            var"##934" = SubArray(var"##932", (2:length(var"##932"),))
                                            true
                                        end)))
                        args = var"##934"
                        t = var"##933"
                        var"##return#848" = begin
                                type(t)
                                print_braces(args, "[", "]", " ")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##935" = (var"##cache#851").value
                                var"##935" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##935"[1] == :vcat && (begin
                                        var"##936" = var"##935"[2]
                                        var"##936" isa AbstractArray
                                    end && ((ndims(var"##936") === 1 && length(var"##936") >= 0) && begin
                                            var"##937" = SubArray(var"##936", (1:length(var"##936"),))
                                            true
                                        end)))
                        args = var"##937"
                        var"##return#848" = begin
                                print_braces(args, "[", "]", "; ")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##938" = (var"##cache#851").value
                                var"##938" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##938"[1] == :ncat && (begin
                                        var"##939" = var"##938"[2]
                                        var"##939" isa AbstractArray
                                    end && ((ndims(var"##939") === 1 && length(var"##939") >= 1) && begin
                                            var"##940" = var"##939"[1]
                                            var"##941" = SubArray(var"##939", (2:length(var"##939"),))
                                            true
                                        end)))
                        n = var"##940"
                        args = var"##941"
                        var"##return#848" = begin
                                print_braces(args, "[", "]", ";" ^ n * " ")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##942" = (var"##cache#851").value
                                var"##942" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##942"[1] == :ref && (begin
                                        var"##943" = var"##942"[2]
                                        var"##943" isa AbstractArray
                                    end && ((ndims(var"##943") === 1 && length(var"##943") >= 1) && begin
                                            var"##944" = var"##943"[1]
                                            var"##945" = SubArray(var"##943", (2:length(var"##943"),))
                                            true
                                        end)))
                        args = var"##945"
                        object = var"##944"
                        var"##return#848" = begin
                                p(object)
                                print_braces(args, "[", "]")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##946" = (var"##cache#851").value
                                var"##946" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##946"[1] == :comprehension && (begin
                                        var"##947" = var"##946"[2]
                                        var"##947" isa AbstractArray
                                    end && (length(var"##947") === 1 && (begin
                                                begin
                                                    var"##cache#949" = nothing
                                                end
                                                var"##948" = var"##947"[1]
                                                var"##948" isa Expr
                                            end && (begin
                                                    if var"##cache#949" === nothing
                                                        var"##cache#949" = Some(((var"##948").head, (var"##948").args))
                                                    end
                                                    var"##950" = (var"##cache#949").value
                                                    var"##950" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##950"[1] == :generator && (begin
                                                            var"##951" = var"##950"[2]
                                                            var"##951" isa AbstractArray
                                                        end && (length(var"##951") === 2 && begin
                                                                var"##952" = var"##951"[1]
                                                                var"##953" = var"##951"[2]
                                                                true
                                                            end))))))))
                        iter = var"##952"
                        body = var"##953"
                        var"##return#848" = begin
                                preced = p.state.precedence
                                p.state.precedence = 0
                                with(p.state, :loop_iterator, true) do 
                                    print("[")
                                    p(iter)
                                    keyword(" for ")
                                    p(body)
                                    print("]")
                                end
                                p.state.precedence = preced
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##954" = (var"##cache#851").value
                                var"##954" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##954"[1] == :typed_comprehension && (begin
                                        var"##955" = var"##954"[2]
                                        var"##955" isa AbstractArray
                                    end && (length(var"##955") === 2 && (begin
                                                var"##956" = var"##955"[1]
                                                begin
                                                    var"##cache#958" = nothing
                                                end
                                                var"##957" = var"##955"[2]
                                                var"##957" isa Expr
                                            end && (begin
                                                    if var"##cache#958" === nothing
                                                        var"##cache#958" = Some(((var"##957").head, (var"##957").args))
                                                    end
                                                    var"##959" = (var"##cache#958").value
                                                    var"##959" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##959"[1] == :generator && (begin
                                                            var"##960" = var"##959"[2]
                                                            var"##960" isa AbstractArray
                                                        end && (length(var"##960") === 2 && begin
                                                                var"##961" = var"##960"[1]
                                                                var"##962" = var"##960"[2]
                                                                true
                                                            end))))))))
                        iter = var"##961"
                        body = var"##962"
                        t = var"##956"
                        var"##return#848" = begin
                                preced = p.state.precedence
                                p.state.precedence = 0
                                with(p.state, :loop_iterator, true) do 
                                    type(t)
                                    print("[")
                                    p(iter)
                                    keyword(" for ")
                                    p(body)
                                    print("]")
                                end
                                p.state.precedence = preced
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##963" = (var"##cache#851").value
                                var"##963" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##963"[1] == :-> && (begin
                                        var"##964" = var"##963"[2]
                                        var"##964" isa AbstractArray
                                    end && (length(var"##964") === 2 && (begin
                                                var"##965" = var"##964"[1]
                                                begin
                                                    var"##cache#967" = nothing
                                                end
                                                var"##966" = var"##964"[2]
                                                var"##966" isa Expr
                                            end && (begin
                                                    if var"##cache#967" === nothing
                                                        var"##cache#967" = Some(((var"##966").head, (var"##966").args))
                                                    end
                                                    var"##968" = (var"##cache#967").value
                                                    var"##968" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##968"[1] == :block && (begin
                                                            var"##969" = var"##968"[2]
                                                            var"##969" isa AbstractArray
                                                        end && (length(var"##969") === 2 && begin
                                                                var"##970" = var"##969"[1]
                                                                var"##971" = var"##969"[2]
                                                                true
                                                            end))))))))
                        line = var"##970"
                        code = var"##971"
                        args = var"##965"
                        var"##return#848" = begin
                                p(args)
                                keyword(" -> ")
                                p.line && begin
                                        print("(")
                                        p(line)
                                        print(" ")
                                    end
                                p(code)
                                p.line && print(")")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##972" = (var"##cache#851").value
                                var"##972" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##972"[1] == :-> && (begin
                                        var"##973" = var"##972"[2]
                                        var"##973" isa AbstractArray
                                    end && (length(var"##973") === 2 && begin
                                            var"##974" = var"##973"[1]
                                            var"##975" = var"##973"[2]
                                            true
                                        end)))
                        args = var"##974"
                        body = var"##975"
                        var"##return#848" = begin
                                p(args)
                                keyword(" -> ")
                                print("(")
                                noblock(body)
                                print(")")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##976" = (var"##cache#851").value
                                var"##976" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##976"[1] == :do && (begin
                                        var"##977" = var"##976"[2]
                                        var"##977" isa AbstractArray
                                    end && (length(var"##977") === 2 && (begin
                                                var"##978" = var"##977"[1]
                                                begin
                                                    var"##cache#980" = nothing
                                                end
                                                var"##979" = var"##977"[2]
                                                var"##979" isa Expr
                                            end && (begin
                                                    if var"##cache#980" === nothing
                                                        var"##cache#980" = Some(((var"##979").head, (var"##979").args))
                                                    end
                                                    var"##981" = (var"##cache#980").value
                                                    var"##981" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##981"[1] == :-> && (begin
                                                            var"##982" = var"##981"[2]
                                                            var"##982" isa AbstractArray
                                                        end && (length(var"##982") === 2 && (begin
                                                                    begin
                                                                        var"##cache#984" = nothing
                                                                    end
                                                                    var"##983" = var"##982"[1]
                                                                    var"##983" isa Expr
                                                                end && (begin
                                                                        if var"##cache#984" === nothing
                                                                            var"##cache#984" = Some(((var"##983").head, (var"##983").args))
                                                                        end
                                                                        var"##985" = (var"##cache#984").value
                                                                        var"##985" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                    end && (var"##985"[1] == :tuple && (begin
                                                                                var"##986" = var"##985"[2]
                                                                                var"##986" isa AbstractArray
                                                                            end && ((ndims(var"##986") === 1 && length(var"##986") >= 0) && begin
                                                                                    var"##987" = SubArray(var"##986", (1:length(var"##986"),))
                                                                                    var"##988" = var"##982"[2]
                                                                                    true
                                                                                end)))))))))))))
                        call = var"##978"
                        args = var"##987"
                        body = var"##988"
                        var"##return#848" = begin
                                p(call)
                                keyword(" do")
                                isempty(args) || begin
                                        print(" ")
                                        p(args...)
                                    end
                                keyword("; ")
                                noblock(body)
                                isempty(args) || print(" ")
                                keyword("end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##989" = (var"##cache#851").value
                                var"##989" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##989"[1] == :function && (begin
                                        var"##990" = var"##989"[2]
                                        var"##990" isa AbstractArray
                                    end && (length(var"##990") === 2 && begin
                                            var"##991" = var"##990"[1]
                                            var"##992" = var"##990"[2]
                                            true
                                        end)))
                        call = var"##991"
                        body = var"##992"
                        var"##return#848" = begin
                                print_function(:function, call, body)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##993" = (var"##cache#851").value
                                var"##993" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##993"[1] == :quote && (begin
                                        var"##994" = var"##993"[2]
                                        var"##994" isa AbstractArray
                                    end && (length(var"##994") === 1 && begin
                                            var"##995" = var"##994"[1]
                                            true
                                        end)))
                        stmt = var"##995"
                        var"##return#848" = begin
                                keyword(":(")
                                noblock(stmt)
                                keyword(")")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##996" = (var"##cache#851").value
                                var"##996" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##996"[1] == :quote && (begin
                                        var"##997" = var"##996"[2]
                                        var"##997" isa AbstractArray
                                    end && ((ndims(var"##997") === 1 && length(var"##997") >= 0) && begin
                                            var"##998" = SubArray(var"##997", (1:length(var"##997"),))
                                            true
                                        end)))
                        args = var"##998"
                        var"##return#848" = begin
                                keyword("quote ")
                                with(p.state, :block, false) do 
                                    join(args, "; ")
                                end
                                keyword(" end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##999" = (var"##cache#851").value
                                var"##999" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##999"[1] == :string && (begin
                                        var"##1000" = var"##999"[2]
                                        var"##1000" isa AbstractArray
                                    end && ((ndims(var"##1000") === 1 && length(var"##1000") >= 0) && begin
                                            var"##1001" = SubArray(var"##1000", (1:length(var"##1000"),))
                                            true
                                        end)))
                        args = var"##1001"
                        var"##return#848" = begin
                                printstyled("\"", color = c.string)
                                foreach(args) do x
                                    x isa AbstractString && return printstyled(x; color = c.string)
                                    keyword('$')
                                    x isa Symbol && return p(x)
                                    print("(")
                                    p(x)
                                    print(")")
                                end
                                printstyled("\"", color = c.string)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1002" = (var"##cache#851").value
                                var"##1002" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1002"[1] == :block && (begin
                                        var"##1003" = var"##1002"[2]
                                        var"##1003" isa AbstractArray
                                    end && ((ndims(var"##1003") === 1 && length(var"##1003") >= 0) && begin
                                            var"##1004" = SubArray(var"##1003", (1:length(var"##1003"),))
                                            let args = var"##1004"
                                                length(args) == 2 && (is_line_no(args[1]) && is_line_no(args[2]))
                                            end
                                        end)))
                        args = var"##1004"
                        var"##return#848" = begin
                                p(args[1])
                                print(" ")
                                p(args[2])
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1005" = (var"##cache#851").value
                                var"##1005" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1005"[1] == :block && (begin
                                        var"##1006" = var"##1005"[2]
                                        var"##1006" isa AbstractArray
                                    end && ((ndims(var"##1006") === 1 && length(var"##1006") >= 0) && begin
                                            var"##1007" = SubArray(var"##1006", (1:length(var"##1006"),))
                                            let args = var"##1007"
                                                length(args) == 2 && is_line_no(args[1])
                                            end
                                        end)))
                        args = var"##1007"
                        var"##return#848" = begin
                                p(args[1])
                                print(" ")
                                noblock(args[2])
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1008" = (var"##cache#851").value
                                var"##1008" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1008"[1] == :block && (begin
                                        var"##1009" = var"##1008"[2]
                                        var"##1009" isa AbstractArray
                                    end && ((ndims(var"##1009") === 1 && length(var"##1009") >= 0) && begin
                                            var"##1010" = SubArray(var"##1009", (1:length(var"##1009"),))
                                            let args = var"##1010"
                                                length(args) == 2 && is_line_no(args[2])
                                            end
                                        end)))
                        args = var"##1010"
                        var"##return#848" = begin
                                noblock(args[1])
                                print(" ")
                                p(args[2])
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1011" = (var"##cache#851").value
                                var"##1011" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1011"[1] == :block && (begin
                                        var"##1012" = var"##1011"[2]
                                        var"##1012" isa AbstractArray
                                    end && ((ndims(var"##1012") === 1 && length(var"##1012") >= 0) && begin
                                            var"##1013" = SubArray(var"##1012", (1:length(var"##1012"),))
                                            let args = var"##1013"
                                                length(args) == 2
                                            end
                                        end)))
                        args = var"##1013"
                        var"##return#848" = begin
                                print("(")
                                noblock(args[1])
                                keyword("; ")
                                noblock(args[2])
                                print(")")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1014" = (var"##cache#851").value
                                var"##1014" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1014"[1] == :block && (begin
                                        var"##1015" = var"##1014"[2]
                                        var"##1015" isa AbstractArray
                                    end && ((ndims(var"##1015") === 1 && length(var"##1015") >= 0) && begin
                                            var"##1016" = SubArray(var"##1015", (1:length(var"##1015"),))
                                            true
                                        end)))
                        args = var"##1016"
                        var"##return#848" = begin
                                p.state.block && keyword("begin ")
                                with(p.state, :block, true) do 
                                    join(args, "; ")
                                end
                                p.state.block && keyword(" end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1017" = (var"##cache#851").value
                                var"##1017" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1017"[1] == :let && (begin
                                        var"##1018" = var"##1017"[2]
                                        var"##1018" isa AbstractArray
                                    end && (length(var"##1018") === 2 && (begin
                                                begin
                                                    var"##cache#1020" = nothing
                                                end
                                                var"##1019" = var"##1018"[1]
                                                var"##1019" isa Expr
                                            end && (begin
                                                    if var"##cache#1020" === nothing
                                                        var"##cache#1020" = Some(((var"##1019").head, (var"##1019").args))
                                                    end
                                                    var"##1021" = (var"##cache#1020").value
                                                    var"##1021" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1021"[1] == :block && (begin
                                                            var"##1022" = var"##1021"[2]
                                                            var"##1022" isa AbstractArray
                                                        end && ((ndims(var"##1022") === 1 && length(var"##1022") >= 0) && begin
                                                                var"##1023" = SubArray(var"##1022", (1:length(var"##1022"),))
                                                                var"##1024" = var"##1018"[2]
                                                                true
                                                            end))))))))
                        args = var"##1023"
                        body = var"##1024"
                        var"##return#848" = begin
                                keyword("let ")
                                join(args, ", ")
                                keyword("; ")
                                noblock(body)
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1025" = (var"##cache#851").value
                                var"##1025" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1025"[1] == :let && (begin
                                        var"##1026" = var"##1025"[2]
                                        var"##1026" isa AbstractArray
                                    end && (length(var"##1026") === 2 && begin
                                            var"##1027" = var"##1026"[1]
                                            var"##1028" = var"##1026"[2]
                                            true
                                        end)))
                        arg = var"##1027"
                        body = var"##1028"
                        var"##return#848" = begin
                                keyword("let ")
                                p(arg)
                                keyword("; ")
                                noblock(body)
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1029" = (var"##cache#851").value
                                var"##1029" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1029"[1] == :macrocall && (begin
                                        var"##1030" = var"##1029"[2]
                                        var"##1030" isa AbstractArray
                                    end && ((ndims(var"##1030") === 1 && length(var"##1030") >= 2) && begin
                                            var"##1031" = var"##1030"[1]
                                            var"##1032" = var"##1030"[2]
                                            var"##1033" = SubArray(var"##1030", (3:length(var"##1030"),))
                                            true
                                        end)))
                        f = var"##1031"
                        line = var"##1032"
                        args = var"##1033"
                        var"##return#848" = begin
                                p.line && printstyled(line, color = c.comment)
                                macrocall(f)
                                print_braces(args, "(", ")")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1034" = (var"##cache#851").value
                                var"##1034" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1034"[1] == :return && (begin
                                        var"##1035" = var"##1034"[2]
                                        var"##1035" isa AbstractArray
                                    end && (length(var"##1035") === 1 && (begin
                                                begin
                                                    var"##cache#1037" = nothing
                                                end
                                                var"##1036" = var"##1035"[1]
                                                var"##1036" isa Expr
                                            end && (begin
                                                    if var"##cache#1037" === nothing
                                                        var"##cache#1037" = Some(((var"##1036").head, (var"##1036").args))
                                                    end
                                                    var"##1038" = (var"##cache#1037").value
                                                    var"##1038" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1038"[1] == :tuple && (begin
                                                            var"##1039" = var"##1038"[2]
                                                            var"##1039" isa AbstractArray
                                                        end && ((ndims(var"##1039") === 1 && length(var"##1039") >= 1) && (begin
                                                                    begin
                                                                        var"##cache#1041" = nothing
                                                                    end
                                                                    var"##1040" = var"##1039"[1]
                                                                    var"##1040" isa Expr
                                                                end && (begin
                                                                        if var"##cache#1041" === nothing
                                                                            var"##cache#1041" = Some(((var"##1040").head, (var"##1040").args))
                                                                        end
                                                                        var"##1042" = (var"##cache#1041").value
                                                                        var"##1042" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                    end && (var"##1042"[1] == :parameters && (begin
                                                                                var"##1043" = var"##1042"[2]
                                                                                var"##1043" isa AbstractArray
                                                                            end && ((ndims(var"##1043") === 1 && length(var"##1043") >= 0) && begin
                                                                                    var"##1044" = SubArray(var"##1043", (1:length(var"##1043"),))
                                                                                    var"##1045" = SubArray(var"##1039", (2:length(var"##1039"),))
                                                                                    true
                                                                                end)))))))))))))
                        args = var"##1045"
                        kwargs = var"##1044"
                        var"##return#848" = begin
                                keyword("return ")
                                p(Expr(:tuple, Expr(:parameters, kwargs...), args...))
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1046" = (var"##cache#851").value
                                var"##1046" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1046"[1] == :return && (begin
                                        var"##1047" = var"##1046"[2]
                                        var"##1047" isa AbstractArray
                                    end && (length(var"##1047") === 1 && (begin
                                                begin
                                                    var"##cache#1049" = nothing
                                                end
                                                var"##1048" = var"##1047"[1]
                                                var"##1048" isa Expr
                                            end && (begin
                                                    if var"##cache#1049" === nothing
                                                        var"##cache#1049" = Some(((var"##1048").head, (var"##1048").args))
                                                    end
                                                    var"##1050" = (var"##cache#1049").value
                                                    var"##1050" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1050"[1] == :tuple && (begin
                                                            var"##1051" = var"##1050"[2]
                                                            var"##1051" isa AbstractArray
                                                        end && ((ndims(var"##1051") === 1 && length(var"##1051") >= 0) && begin
                                                                var"##1052" = SubArray(var"##1051", (1:length(var"##1051"),))
                                                                true
                                                            end))))))))
                        args = var"##1052"
                        var"##return#848" = begin
                                keyword("return ")
                                join(args)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1053" = (var"##cache#851").value
                                var"##1053" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1053"[1] == :return && (begin
                                        var"##1054" = var"##1053"[2]
                                        var"##1054" isa AbstractArray
                                    end && ((ndims(var"##1054") === 1 && length(var"##1054") >= 0) && begin
                                            var"##1055" = SubArray(var"##1054", (1:length(var"##1054"),))
                                            true
                                        end)))
                        args = var"##1055"
                        var"##return#848" = begin
                                keyword("return ")
                                join(args)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1056" = (var"##cache#851").value
                                var"##1056" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1056"[1] == :module && (begin
                                        var"##1057" = var"##1056"[2]
                                        var"##1057" isa AbstractArray
                                    end && (length(var"##1057") === 3 && begin
                                            var"##1058" = var"##1057"[1]
                                            var"##1059" = var"##1057"[2]
                                            var"##1060" = var"##1057"[3]
                                            true
                                        end)))
                        bare = var"##1058"
                        name = var"##1059"
                        body = var"##1060"
                        var"##return#848" = begin
                                if bare
                                    keyword("module ")
                                else
                                    keyword("baremodule ")
                                end
                                p(name)
                                print("; ")
                                noblock(body)
                                keyword(" end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1061" = (var"##cache#851").value
                                var"##1061" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1061"[1] == :using && (begin
                                        var"##1062" = var"##1061"[2]
                                        var"##1062" isa AbstractArray
                                    end && ((ndims(var"##1062") === 1 && length(var"##1062") >= 0) && begin
                                            var"##1063" = SubArray(var"##1062", (1:length(var"##1062"),))
                                            true
                                        end)))
                        args = var"##1063"
                        var"##return#848" = begin
                                keyword("using ")
                                join(args)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1064" = (var"##cache#851").value
                                var"##1064" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1064"[1] == :import && (begin
                                        var"##1065" = var"##1064"[2]
                                        var"##1065" isa AbstractArray
                                    end && ((ndims(var"##1065") === 1 && length(var"##1065") >= 0) && begin
                                            var"##1066" = SubArray(var"##1065", (1:length(var"##1065"),))
                                            true
                                        end)))
                        args = var"##1066"
                        var"##return#848" = begin
                                keyword("import ")
                                join(args)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1067" = (var"##cache#851").value
                                var"##1067" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1067"[1] == :as && (begin
                                        var"##1068" = var"##1067"[2]
                                        var"##1068" isa AbstractArray
                                    end && (length(var"##1068") === 2 && begin
                                            var"##1069" = var"##1068"[1]
                                            var"##1070" = var"##1068"[2]
                                            true
                                        end)))
                        name = var"##1069"
                        alias = var"##1070"
                        var"##return#848" = begin
                                p(name)
                                keyword(" as ")
                                p(alias)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1071" = (var"##cache#851").value
                                var"##1071" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1071"[1] == :export && (begin
                                        var"##1072" = var"##1071"[2]
                                        var"##1072" isa AbstractArray
                                    end && ((ndims(var"##1072") === 1 && length(var"##1072") >= 0) && begin
                                            var"##1073" = SubArray(var"##1072", (1:length(var"##1072"),))
                                            true
                                        end)))
                        args = var"##1073"
                        var"##return#848" = begin
                                keyword("export ")
                                join(args)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1074" = (var"##cache#851").value
                                var"##1074" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1074"[1] == :(:) && (begin
                                        var"##1075" = var"##1074"[2]
                                        var"##1075" isa AbstractArray
                                    end && ((ndims(var"##1075") === 1 && length(var"##1075") >= 1) && begin
                                            var"##1076" = var"##1075"[1]
                                            var"##1077" = SubArray(var"##1075", (2:length(var"##1075"),))
                                            true
                                        end)))
                        args = var"##1077"
                        head = var"##1076"
                        var"##return#848" = begin
                                p(head)
                                keyword(": ")
                                join(args)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1078" = (var"##cache#851").value
                                var"##1078" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1078"[1] == :where && (begin
                                        var"##1079" = var"##1078"[2]
                                        var"##1079" isa AbstractArray
                                    end && ((ndims(var"##1079") === 1 && length(var"##1079") >= 1) && begin
                                            var"##1080" = var"##1079"[1]
                                            var"##1081" = SubArray(var"##1079", (2:length(var"##1079"),))
                                            true
                                        end)))
                        body = var"##1080"
                        whereparams = var"##1081"
                        var"##return#848" = begin
                                p(body)
                                keyword(" where {")
                                with(p.state, :type, true) do 
                                    join(whereparams, ", ")
                                end
                                keyword("}")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1082" = (var"##cache#851").value
                                var"##1082" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1082"[1] == :for && (begin
                                        var"##1083" = var"##1082"[2]
                                        var"##1083" isa AbstractArray
                                    end && (length(var"##1083") === 2 && begin
                                            var"##1084" = var"##1083"[1]
                                            var"##1085" = var"##1083"[2]
                                            true
                                        end)))
                        body = var"##1085"
                        iteration = var"##1084"
                        var"##return#848" = begin
                                preced = p.state.precedence
                                p.state.precedence = 0
                                with(p.state, :loop_iterator, true) do 
                                    keyword("for ")
                                    noblock(iteration)
                                    keyword("; ")
                                    noblock(body)
                                    keyword("; end")
                                end
                                p.state.precedence = preced
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1086" = (var"##cache#851").value
                                var"##1086" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1086"[1] == :while && (begin
                                        var"##1087" = var"##1086"[2]
                                        var"##1087" isa AbstractArray
                                    end && (length(var"##1087") === 2 && begin
                                            var"##1088" = var"##1087"[1]
                                            var"##1089" = var"##1087"[2]
                                            true
                                        end)))
                        body = var"##1089"
                        condition = var"##1088"
                        var"##return#848" = begin
                                keyword("while ")
                                noblock(condition)
                                keyword("; ")
                                noblock(body)
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1090" = (var"##cache#851").value
                                var"##1090" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1090"[1] == :continue && (begin
                                        var"##1091" = var"##1090"[2]
                                        var"##1091" isa AbstractArray
                                    end && isempty(var"##1091")))
                        var"##return#848" = begin
                                keyword("continue")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1092" = (var"##cache#851").value
                                var"##1092" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1092"[1] == :if && (begin
                                        var"##1093" = var"##1092"[2]
                                        var"##1093" isa AbstractArray
                                    end && (length(var"##1093") === 2 && begin
                                            var"##1094" = var"##1093"[1]
                                            var"##1095" = var"##1093"[2]
                                            true
                                        end)))
                        body = var"##1095"
                        condition = var"##1094"
                        var"##return#848" = begin
                                keyword("if ")
                                noblock(condition)
                                keyword("; ")
                                noblock(body)
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1096" = (var"##cache#851").value
                                var"##1096" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1096"[1] == :if && (begin
                                        var"##1097" = var"##1096"[2]
                                        var"##1097" isa AbstractArray
                                    end && (length(var"##1097") === 3 && begin
                                            var"##1098" = var"##1097"[1]
                                            var"##1099" = var"##1097"[2]
                                            var"##1100" = var"##1097"[3]
                                            true
                                        end)))
                        body = var"##1099"
                        elsebody = var"##1100"
                        condition = var"##1098"
                        var"##return#848" = begin
                                keyword("if ")
                                noblock(condition)
                                keyword("; ")
                                noblock(body)
                                keyword("; ")
                                Meta.isexpr(elsebody, :elseif) || keyword("else ")
                                noblock(elsebody)
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1101" = (var"##cache#851").value
                                var"##1101" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1101"[1] == :elseif && (begin
                                        var"##1102" = var"##1101"[2]
                                        var"##1102" isa AbstractArray
                                    end && (length(var"##1102") === 2 && begin
                                            var"##1103" = var"##1102"[1]
                                            var"##1104" = var"##1102"[2]
                                            true
                                        end)))
                        body = var"##1104"
                        condition = var"##1103"
                        var"##return#848" = begin
                                keyword("elseif ")
                                noblock(condition)
                                keyword("; ")
                                noblock(body)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1105" = (var"##cache#851").value
                                var"##1105" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1105"[1] == :elseif && (begin
                                        var"##1106" = var"##1105"[2]
                                        var"##1106" isa AbstractArray
                                    end && (length(var"##1106") === 3 && begin
                                            var"##1107" = var"##1106"[1]
                                            var"##1108" = var"##1106"[2]
                                            var"##1109" = var"##1106"[3]
                                            true
                                        end)))
                        body = var"##1108"
                        elsebody = var"##1109"
                        condition = var"##1107"
                        var"##return#848" = begin
                                keyword("elseif ")
                                noblock(condition)
                                keyword("; ")
                                noblock(body)
                                keyword("; ")
                                Meta.isexpr(elsebody, :elseif) || keyword("else")
                                noblock(elsebody)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1110" = (var"##cache#851").value
                                var"##1110" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1110"[1] == :try && (begin
                                        var"##1111" = var"##1110"[2]
                                        var"##1111" isa AbstractArray
                                    end && (length(var"##1111") === 3 && begin
                                            var"##1112" = var"##1111"[1]
                                            var"##1113" = var"##1111"[2]
                                            var"##1114" = var"##1111"[3]
                                            true
                                        end)))
                        catch_vars = var"##1113"
                        catch_body = var"##1114"
                        try_body = var"##1112"
                        var"##return#848" = begin
                                keyword("try ")
                                noblock(try_body)
                                keyword("; ")
                                keyword("catch")
                                catch_vars == false || begin
                                        print(" ")
                                        noblock(catch_vars)
                                    end
                                keyword(";")
                                noblock(catch_body)
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1115" = (var"##cache#851").value
                                var"##1115" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1115"[1] == :try && (begin
                                        var"##1116" = var"##1115"[2]
                                        var"##1116" isa AbstractArray
                                    end && (length(var"##1116") === 4 && begin
                                            var"##1117" = var"##1116"[1]
                                            var"##1118" = var"##1116"[2]
                                            var"##1119" = var"##1116"[3]
                                            var"##1120" = var"##1116"[4]
                                            true
                                        end)))
                        catch_vars = var"##1118"
                        catch_body = var"##1119"
                        try_body = var"##1117"
                        finally_body = var"##1120"
                        var"##return#848" = begin
                                keyword("try ")
                                noblock(try_body)
                                keyword("; ")
                                catch_vars == false || begin
                                        keyword("catch ")
                                        noblock(catch_vars)
                                    end
                                catch_vars == false || begin
                                        keyword("; ")
                                        noblock(catch_body)
                                    end
                                finally_body == false || begin
                                        keyword("; finally ")
                                        noblock(finally_body)
                                    end
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1121" = (var"##cache#851").value
                                var"##1121" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1121"[1] == :try && (begin
                                        var"##1122" = var"##1121"[2]
                                        var"##1122" isa AbstractArray
                                    end && (length(var"##1122") === 5 && begin
                                            var"##1123" = var"##1122"[1]
                                            var"##1124" = var"##1122"[2]
                                            var"##1125" = var"##1122"[3]
                                            var"##1126" = var"##1122"[4]
                                            var"##1127" = var"##1122"[5]
                                            true
                                        end)))
                        catch_vars = var"##1124"
                        catch_body = var"##1125"
                        try_body = var"##1123"
                        finally_body = var"##1126"
                        else_body = var"##1127"
                        var"##return#848" = begin
                                keyword("try ")
                                noblock(try_body)
                                keyword("; ")
                                catch_vars == false || begin
                                        keyword("catch ")
                                        noblock(catch_vars)
                                    end
                                catch_vars == false || begin
                                        keyword("; ")
                                        noblock(catch_body)
                                    end
                                keyword("; else ")
                                noblock(else_body)
                                finally_body == false || begin
                                        keyword("; finally ")
                                        noblock(finally_body)
                                    end
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1128" = (var"##cache#851").value
                                var"##1128" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1128"[1] == :struct && (begin
                                        var"##1129" = var"##1128"[2]
                                        var"##1129" isa AbstractArray
                                    end && (length(var"##1129") === 3 && begin
                                            var"##1130" = var"##1129"[1]
                                            var"##1131" = var"##1129"[2]
                                            var"##1132" = var"##1129"[3]
                                            true
                                        end)))
                        ismutable = var"##1130"
                        name = var"##1131"
                        body = var"##1132"
                        var"##return#848" = begin
                                if ismutable
                                    keyword("mutable struct ")
                                else
                                    keyword("struct ")
                                end
                                p(name)
                                keyword("; ")
                                noblock(body)
                                keyword("; end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1133" = (var"##cache#851").value
                                var"##1133" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1133"[1] == :abstract && (begin
                                        var"##1134" = var"##1133"[2]
                                        var"##1134" isa AbstractArray
                                    end && (length(var"##1134") === 1 && begin
                                            var"##1135" = var"##1134"[1]
                                            true
                                        end)))
                        name = var"##1135"
                        var"##return#848" = begin
                                keyword("abstract type ")
                                p(name)
                                keyword(" end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1136" = (var"##cache#851").value
                                var"##1136" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1136"[1] == :primitive && (begin
                                        var"##1137" = var"##1136"[2]
                                        var"##1137" isa AbstractArray
                                    end && (length(var"##1137") === 2 && begin
                                            var"##1138" = var"##1137"[1]
                                            var"##1139" = var"##1137"[2]
                                            true
                                        end)))
                        name = var"##1138"
                        size = var"##1139"
                        var"##return#848" = begin
                                keyword("primitive type ")
                                p(name)
                                print(" ")
                                p(size)
                                keyword(" end")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1140" = (var"##cache#851").value
                                var"##1140" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1140"[1] == :meta && (begin
                                        var"##1141" = var"##1140"[2]
                                        var"##1141" isa AbstractArray
                                    end && (length(var"##1141") === 1 && var"##1141"[1] == :inline)))
                        var"##return#848" = begin
                                macrocall(GlobalRef(Base, Symbol("@_inline_meta")))
                                keyword(";")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1142" = (var"##cache#851").value
                                var"##1142" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1142"[1] == :break && (begin
                                        var"##1143" = var"##1142"[2]
                                        var"##1143" isa AbstractArray
                                    end && isempty(var"##1143")))
                        var"##return#848" = begin
                                keyword("break")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1144" = (var"##cache#851").value
                                var"##1144" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1144"[1] == :symboliclabel && (begin
                                        var"##1145" = var"##1144"[2]
                                        var"##1145" isa AbstractArray
                                    end && (length(var"##1145") === 1 && begin
                                            var"##1146" = var"##1145"[1]
                                            true
                                        end)))
                        label = var"##1146"
                        var"##return#848" = begin
                                macrocall(GlobalRef(Base, Symbol("@label")))
                                print(" ")
                                p(label)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1147" = (var"##cache#851").value
                                var"##1147" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1147"[1] == :symbolicgoto && (begin
                                        var"##1148" = var"##1147"[2]
                                        var"##1148" isa AbstractArray
                                    end && (length(var"##1148") === 1 && begin
                                            var"##1149" = var"##1148"[1]
                                            true
                                        end)))
                        label = var"##1149"
                        var"##return#848" = begin
                                macrocall(GlobalRef(Base, Symbol("@goto")))
                                print(" ")
                                p(label)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    if begin
                                var"##1150" = (var"##cache#851").value
                                var"##1150" isa (Tuple{var1, var2} where {var2 <: AbstractArray, var1})
                            end && (begin
                                    var"##1151" = var"##1150"[1]
                                    var"##1152" = var"##1150"[2]
                                    var"##1152" isa AbstractArray
                                end && ((ndims(var"##1152") === 1 && length(var"##1152") >= 0) && begin
                                        var"##1153" = SubArray(var"##1152", (1:length(var"##1152"),))
                                        true
                                    end))
                        args = var"##1153"
                        head = var"##1151"
                        var"##return#848" = begin
                                keyword('$')
                                print("(")
                                printstyled(:Expr, color = c.call)
                                print("(")
                                keyword(":")
                                printstyled(head, color = c.symbol)
                                print(", ")
                                join(args)
                                print("))")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa GlobalRef
                    begin
                        var"##return#848" = begin
                                p(ex.mod)
                                keyword(".")
                                p(ex.name)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa QuoteNode
                    if ex.value in Base.quoted_syms
                        var"##return#848" = begin
                                keyword(":(")
                                quoted(ex.value)
                                keyword(")")
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                    begin
                        var"##return#848" = begin
                                if ex.value isa Symbol && Base.isidentifier(ex.value)
                                    keyword(":")
                                    quoted(ex.value)
                                else
                                    keyword(":(")
                                    quoted(ex.value)
                                    keyword(")")
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa Number
                    begin
                        var"##return#848" = begin
                                printstyled(ex, color = c.number)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa String
                    begin
                        var"##return#848" = begin
                                string(ex)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                if var"##850" isa LineNumberNode
                    begin
                        var"##return#848" = begin
                                p.line || return nothing
                                printstyled("#= $(ex.file):$(ex.line) =#", color = c.line)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                    end
                end
                begin
                    var"##return#848" = begin
                            print(ex)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#849#1154")))
                end
                error("matching non-exhaustive, at #= none:142 =#")
                $(Expr(:symboliclabel, Symbol("####final#849#1154")))
                var"##return#848"
            end
        end
        print_expr(expr)
        return nothing
    end
    #= none:455 =# Core.@doc "    print_expr([io::IO], ex; kw...)\n\nPrint a given expression within one line.\n`ex` can be a `Expr` or a syntax type `JLExpr`.\n" print_inline(io::IO, expr; kw...) = begin
                (InlinePrinter(io; kw...))(expr)
            end
    print_inline(expr; kw...) = begin
            (InlinePrinter(stdout; kw...))(expr)
        end
