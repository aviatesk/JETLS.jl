
    #= none:1 =# Core.@doc "    JLCall(ex::Expr)\n\nConvert a Julia call expression to `JLCall`.\n\n# Examples\n```julia\nex = :(f(x, y; z=1))\njlcall = JLCall(ex)  # creates JLCall with func=:f, args=[:x, :y], kwargs=[:(z=1)]\n```\n" function JLCall(ex::Expr)
            (name, args, kw) = let
                    begin
                        var"##cache#449" = nothing
                    end
                    var"##return#446" = nothing
                    var"##448" = ex
                    if var"##448" isa Expr && (begin
                                    if var"##cache#449" === nothing
                                        var"##cache#449" = Some(((var"##448").head, (var"##448").args))
                                    end
                                    var"##450" = (var"##cache#449").value
                                    var"##450" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##450"[1] == :call && (begin
                                            var"##451" = var"##450"[2]
                                            var"##451" isa AbstractArray
                                        end && ((ndims(var"##451") === 1 && length(var"##451") >= 2) && (begin
                                                    var"##452" = var"##451"[1]
                                                    begin
                                                        var"##cache#454" = nothing
                                                    end
                                                    var"##453" = var"##451"[2]
                                                    var"##453" isa Expr
                                                end && (begin
                                                        if var"##cache#454" === nothing
                                                            var"##cache#454" = Some(((var"##453").head, (var"##453").args))
                                                        end
                                                        var"##455" = (var"##cache#454").value
                                                        var"##455" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                    end && (var"##455"[1] == :parameters && (begin
                                                                var"##456" = var"##455"[2]
                                                                var"##456" isa AbstractArray
                                                            end && ((ndims(var"##456") === 1 && length(var"##456") >= 0) && begin
                                                                    var"##457" = SubArray(var"##456", (1:length(var"##456"),))
                                                                    var"##458" = SubArray(var"##451", (3:length(var"##451"),))
                                                                    true
                                                                end)))))))))
                        var"##return#446" = let name = var"##452", args = var"##458", kw = var"##457"
                                (name, args, kw)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#447#463")))
                    end
                    if var"##448" isa Expr && (begin
                                    if var"##cache#449" === nothing
                                        var"##cache#449" = Some(((var"##448").head, (var"##448").args))
                                    end
                                    var"##459" = (var"##cache#449").value
                                    var"##459" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##459"[1] == :call && (begin
                                            var"##460" = var"##459"[2]
                                            var"##460" isa AbstractArray
                                        end && ((ndims(var"##460") === 1 && length(var"##460") >= 1) && begin
                                                var"##461" = var"##460"[1]
                                                var"##462" = SubArray(var"##460", (2:length(var"##460"),))
                                                true
                                            end))))
                        var"##return#446" = let name = var"##461", args = var"##462"
                                (name, args, nothing)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#447#463")))
                    end
                    error("matching non-exhaustive, at #= none:13 =#")
                    $(Expr(:symboliclabel, Symbol("####final#447#463")))
                    var"##return#446"
                end
            JLCall(name, args, kw)
        end
    #= none:20 =# Core.@doc "    JLFunction(ex::Expr)\n\nCreate a `JLFunction` object from a Julia function `Expr`.\n\n# Example\n\n```julia\njulia> JLFunction(:(f(x) = 2))\nf(x) = begin\n    #= REPL[37]:1 =#    \n    2    \nend\n```\n" function JLFunction(ex::Expr; source = nothing)
            (line, doc, expr) = split_doc(ex)
            if !(isnothing(doc))
                source = line
            end
            (generated, expr) = let
                    begin
                        var"##cache#467" = nothing
                    end
                    var"##return#464" = nothing
                    var"##466" = expr
                    if var"##466" isa Expr
                        if begin
                                    if var"##cache#467" === nothing
                                        var"##cache#467" = Some(((var"##466").head, (var"##466").args))
                                    end
                                    var"##468" = (var"##cache#467").value
                                    var"##468" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##468"[1] == :macrocall && (begin
                                            var"##469" = var"##468"[2]
                                            var"##469" isa AbstractArray
                                        end && (length(var"##469") === 3 && (begin
                                                    var"##470" = var"##469"[1]
                                                    var"##470" == GlobalRef(Base, Symbol("@generated"))
                                                end && begin
                                                    var"##471" = var"##469"[2]
                                                    var"##472" = var"##469"[3]
                                                    true
                                                end))))
                            var"##return#464" = let line = var"##471", expr = var"##472"
                                    (true, expr)
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#465#487")))
                        end
                        if begin
                                    var"##473" = (var"##cache#467").value
                                    var"##473" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##473"[1] == :macrocall && (begin
                                            var"##474" = var"##473"[2]
                                            var"##474" isa AbstractArray
                                        end && (length(var"##474") === 3 && (begin
                                                    var"##475" = var"##474"[1]
                                                    var"##475" == Symbol("@generated")
                                                end && begin
                                                    var"##476" = var"##474"[2]
                                                    var"##477" = var"##474"[3]
                                                    true
                                                end))))
                            var"##return#464" = let line = var"##476", expr = var"##477"
                                    (true, expr)
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#465#487")))
                        end
                        if begin
                                    var"##478" = (var"##cache#467").value
                                    var"##478" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##478"[1] == :macrocall && (begin
                                            var"##479" = var"##478"[2]
                                            var"##479" isa AbstractArray
                                        end && (length(var"##479") === 3 && (begin
                                                    begin
                                                        var"##cache#481" = nothing
                                                    end
                                                    var"##480" = var"##479"[1]
                                                    var"##480" isa Expr
                                                end && (begin
                                                        if var"##cache#481" === nothing
                                                            var"##cache#481" = Some(((var"##480").head, (var"##480").args))
                                                        end
                                                        var"##482" = (var"##cache#481").value
                                                        var"##482" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                    end && (var"##482"[1] == :. && (begin
                                                                var"##483" = var"##482"[2]
                                                                var"##483" isa AbstractArray
                                                            end && (length(var"##483") === 2 && (var"##483"[1] == :Base && (begin
                                                                            var"##484" = var"##483"[2]
                                                                            var"##484" == QuoteNode(Symbol("@generated"))
                                                                        end && begin
                                                                            var"##485" = var"##479"[2]
                                                                            var"##486" = var"##479"[3]
                                                                            true
                                                                        end))))))))))
                            var"##return#464" = let line = var"##485", expr = var"##486"
                                    (true, expr)
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#465#487")))
                        end
                    end
                    begin
                        var"##return#464" = let
                                (false, expr)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#465#487")))
                    end
                    error("matching non-exhaustive, at #= none:41 =#")
                    $(Expr(:symboliclabel, Symbol("####final#465#487")))
                    var"##return#464"
                end
            (head, call, body) = split_function(expr; source)
            (name, args, kw, whereparams, rettype) = let
                    true
                    var"##return#488" = nothing
                    var"##490" = head
                    if var"##490" == :->
                        var"##return#488" = let
                                split_anonymous_function_head(call; source)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#489#491")))
                    end
                    begin
                        var"##return#488" = let h = var"##490"
                                split_function_head(call; source)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#489#491")))
                    end
                    error("matching non-exhaustive, at #= none:49 =#")
                    $(Expr(:symboliclabel, Symbol("####final#489#491")))
                    var"##return#488"
                end
            JLFunction(head, name, args, kw, rettype, generated, whereparams, body, line, doc)
        end
    #= none:56 =# Core.@doc "    JLStruct(ex::Expr)\n\nCreate a `JLStruct` object from a Julia struct `Expr`.\n\n# Example\n\n```julia\njulia> JLStruct(:(struct Foo\n           x::Int\n       end))\nstruct Foo\n    #= REPL[38]:2 =#\n    x::Int\nend\n```\n" function JLStruct(ex::Expr; source = nothing)
            (line, doc, expr) = split_doc(ex)
            if !(isnothing(doc))
                source = line
            end
            (ismutable, typename, typevars, supertype, body) = split_struct(expr; source)
            (fields, constructors, misc) = (JLField[], JLFunction[], [])
            (field_doc, field_source) = (nothing, source)
            body = flatten_blocks(body)
            for each = body.args
                m = split_field_if_match(typename, each; source = field_source)
                if m isa String
                    field_doc = m
                elseif m isa LineNumberNode
                    field_source = m
                elseif m isa NamedTuple
                    push!(fields, JLField(; m..., doc = field_doc, line = field_source))
                    (field_doc, field_source) = (nothing, nothing)
                elseif m isa JLFunction
                    push!(constructors, m)
                else
                    push!(misc, m)
                end
            end
            JLStruct(typename, ismutable, typevars, supertype, fields, constructors, line, doc, misc)
        end
    #= none:103 =# Core.@doc "    JLKwStruct(ex::Expr, typealias=nothing)\n\nCreate a `JLKwStruct` from given Julia struct `Expr`, with an option to attach\nan alias to this type name.\n\n# Example\n\n```julia\njulia> JLKwStruct(:(struct Foo\n           x::Int = 1\n       end))\n#= kw =# struct Foo\n    #= REPL[39]:2 =#\n    x::Int = 1\nend\n```\n" function JLKwStruct(ex::Expr, typealias = nothing; source = nothing)
            (line, doc, expr) = split_doc(ex)
            if !(isnothing(doc))
                source = line
            end
            (ismutable, typename, typevars, supertype, body) = split_struct(expr; source)
            (fields, constructors, misc) = (JLKwField[], JLFunction[], [])
            (field_doc, field_source) = (nothing, source)
            body = flatten_blocks(body)
            for each = body.args
                m = split_field_if_match(typename, each, true; source = field_source)
                if m isa String
                    field_doc = m
                elseif m isa LineNumberNode
                    field_source = m
                elseif m isa NamedTuple
                    field = JLKwField(; m..., doc = field_doc, line = field_source)
                    push!(fields, field)
                    (field_doc, field_source) = (nothing, nothing)
                elseif m isa JLFunction
                    push!(constructors, m)
                else
                    push!(misc, m)
                end
            end
            JLKwStruct(typename, typealias, ismutable, typevars, supertype, fields, constructors, line, doc, misc)
        end
    #= none:150 =# Core.@doc "    JLIfElse(ex::Expr)\n\nCreate a `JLIfElse` from given Julia ifelse `Expr`.\n\n# Example\n\n```julia\njulia> ex = :(if foo(x)\n             x = 1 + 1\n         elseif goo(x)\n             y = 1 + 2\n         else\n             error(\"abc\")\n         end)\n:(if foo(x)\n      #= REPL[41]:2 =#\n      x = 1 + 1\n  elseif #= REPL[41]:3 =# goo(x)\n      #= REPL[41]:4 =#\n      y = 1 + 2\n  else\n      #= REPL[41]:6 =#\n      error(\"abc\")\n  end)\n\njulia> JLIfElse(ex)\nif foo(x)\n    begin\n        #= REPL[41]:2 =#        \n        x = 1 + 1        \n    end\nelseif begin\n    #= REPL[41]:3 =#    \n    goo(x)    \nend\n    begin\n        #= REPL[41]:4 =#        \n        y = 1 + 2        \n    end\nelse\n    begin\n        #= REPL[41]:6 =#        \n        error(\"abc\")        \n    end\nend\n```\n" function JLIfElse(ex::Expr; source = nothing)
            ex.head === :if || throw(SyntaxError("expect an if ... elseif ... else ... end expression", source))
            (conds, stmts, otherwise) = split_ifelse(ex)
            return JLIfElse(conds, stmts, otherwise)
        end
    #= none:206 =# Core.@doc "    JLFor(ex::Expr)\n\nCreate a `JLFor` from given Julia for loop expression.\n\n# Example\n\n```julia\njulia> ex = @expr for i in 1:10, j in 1:j\n           M[i, j] += 1\n       end\n:(for i = 1:10, j = 1:j\n      #= REPL[3]:2 =#\n      M[i, j] += 1\n  end)\n\njulia> jl = JLFor(ex)\nfor i in 1 : 10,\n    j in 1 : j\n    #= loop body =#\n    begin\n        #= REPL[3]:2 =#        \n        M[i, j] += 1        \n    end\nend\n\njulia> jl.vars\n2-element Vector{Any}:\n :i\n :j\n\njulia> jl.iterators\n2-element Vector{Any}:\n :(1:10)\n :(1:j)\n```\n" function JLFor(ex::Expr)
            (vars, itrs, body) = split_forloop(ex)
            return JLFor(vars, itrs, body)
        end
