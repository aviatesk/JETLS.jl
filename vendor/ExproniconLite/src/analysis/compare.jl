
    struct EmptyLine
    end
    const empty_line = EmptyLine()
    Base.show(io::IO, ::EmptyLine) = begin
            print(io, "<empty line>")
        end
    #= none:5 =# Core.@doc "    struct Variable\n\nMarks a `Symbol` as a variable. So that [`compare_expr`](@ref)\nwill always return `true`.\n" struct Variable
            name::Symbol
        end
    Base.show(io::IO, x::Variable) = begin
            printstyled(io, "<", x.name, ">"; color = :light_blue)
        end
    function locate_inequal_expr(m::Module, lhs, rhs)
        lhs isa Expr && rhs isa Expr || return (lhs, rhs)
        if length(lhs.args) > length(rhs.args)
            (lhs, rhs) = (rhs, lhs)
        end
        not_equals = Tuple{Any, Any}[]
        for (l, r) = zip(lhs.args, rhs.args)
            if !(compare_expr(m, l, r))
                push!(not_equals, (l, r))
            end
        end
        for each = rhs.args[length(lhs.args) + 1:end]
            push!(not_equals, (empty_line, each))
        end
        if length(not_equals) == length(rhs.args)
            return (lhs, rhs)
        else
            return locate_inequal_expr(m, first(not_equals)...)
        end
    end
    #= none:46 =# Core.@doc "    assert_equal_expr(m::Module, lhs, rhs)\n\nAssert that `lhs` and `rhs` are equal in `m`.\nThrow an `ExprNotEqual` if they are not equal.\n" function assert_equal_expr(m::Module, lhs, rhs)
            lhs = prettify(lhs; preserve_last_nothing = true, alias_gensym = false)
            rhs = prettify(rhs; preserve_last_nothing = true, alias_gensym = false)
            lhs = renumber_gensym(lhs)
            rhs = renumber_gensym(rhs)
            compare_expr(m, lhs, rhs) && return true
            (lhs, rhs) = locate_inequal_expr(m, lhs, rhs)
            throw(ExprNotEqual(lhs, rhs))
        end
    #= none:62 =# Core.@doc "    @test_expr <type> <ex>\n\nTest if the syntax type generates the same expression `ex`. Returns the\ncorresponding syntax type instance. Requires `using Test` before using\nthis macro.\n\n# Example\n\n```julia\ndef = @test_expr JLFunction function (x, y)\n    return 2\nend\n@test is_kw_fn(def) == false\n```\n" macro test_expr(type, ex)
            #= none:79 =# @gensym def generated_expr original_expr
            quote
                    $def = #= none:81 =# ExproniconLite.@expr($type, $ex)
                    ($Base).show(stdout, (MIME"text/plain")(), $def)
                    $generated_expr = ($codegen_ast)($def)
                    $original_expr = $(Expr(:quote, ex))
                    #= none:85 =# @test $(Expr(:block, __source__, :(($assert_equal_expr)($__module__, $generated_expr, $original_expr))))
                    $def
                end |> esc
        end
    #= none:93 =# Core.@doc "    @test_expr <expr> == <expr>\n\nTest if two expression is equivalent semantically, this uses `compare_expr`\nto decide if they are equivalent, ignores things such as `LineNumberNode`\ngenerated `Symbol` in `Expr(:curly, ...)` or `Expr(:where, ...)`.\n\n!!! note\n\n    This macro requires one `using Test` to import the `Test` module\n    name.\n" macro test_expr(ex::Expr)
            esc(test_expr_m(__module__, __source__, ex))
        end
    function test_expr_m(__module__, __source__, ex::Expr)
        ex.head === :call && ex.args[1] === :(==) || error("expect <expr> == <expr>, got $(ex)")
        (lhs, rhs) = (ex.args[2], ex.args[3])
        #= none:112 =# @gensym result cmp_result err
        return quote
                $result = try
                        $cmp_result = ($assert_equal_expr)($__module__, $lhs, $rhs)
                        Test.Returned($cmp_result, nothing, $(QuoteNode(__source__)))
                    catch $err
                        $err isa Test.InterruptException && Test.rethrow()
                        Test.Threw($err, ($Base).current_exceptions(), $(QuoteNode(__source__)))
                    end
                Test.do_test($result, $(QuoteNode(ex)))
            end
    end
    macro compare_expr(lhs, rhs)
        return quote
                    ($ExproniconLite).compare_expr($__module__, $lhs, $rhs)
                end |> esc
    end
    #= none:137 =# Core.@doc "    compare_expr([m=Main], lhs, rhs)\n\nCompare two expression of type `Expr` or `Symbol` semantically, which:\n\n1. ignore the detail value `LineNumberNode` in comparision;\n2. ignore the detailed name of typevars declared by `where`;\n3. recognize inserted objects and `Symbol`, e.g `:(\$Int)` is equal to `:(Int)`;\n4. recognize `QuoteNode(:x)` and `Symbol(\"x\")` as equal;\n5. will guess module and type objects and compare their value directly\n    instead of their expression;\n\n!!! tips\n\n    This function is usually combined with [`prettify`](@ref)\n    with `preserve_last_nothing=true` and `alias_gensym=false`.\n\nThis gives a way to compare two Julia expression semantically which means\nalthough some details of the expression is different but they should\nproduce the same lowered code.\n" compare_expr(lhs, rhs) = begin
                compare_expr(Main, lhs, rhs)
            end
    function compare_expr(m::Module, lhs, rhs)
        begin
            true
            var"##322" = (lhs, rhs)
            if var"##322" isa Tuple{Any, Any}
                if var"##322" isa Tuple{Symbol, Symbol} && (begin
                                var"##323" = var"##322"[1]
                                var"##323" isa Symbol
                            end && begin
                                var"##324" = var"##322"[2]
                                var"##324" isa Symbol
                            end)
                    var"##return#320" = begin
                            return lhs === rhs
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa Tuple{Module, Module} && (begin
                                var"##325" = var"##322"[1]
                                var"##325" isa Module
                            end && begin
                                var"##326" = var"##322"[2]
                                var"##326" isa Module
                            end)
                    var"##return#320" = begin
                            return lhs === rhs
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa Tuple{QuoteNode, Expr} && (begin
                                var"##327" = var"##322"[1]
                                var"##327" isa QuoteNode
                            end && (begin
                                    begin
                                        var"##cache#329" = nothing
                                    end
                                    var"##328" = var"##322"[2]
                                    var"##328" isa Expr
                                end && (begin
                                        if var"##cache#329" === nothing
                                            var"##cache#329" = Some(((var"##328").head, (var"##328").args))
                                        end
                                        var"##330" = (var"##cache#329").value
                                        var"##330" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                    end && (var"##330"[1] == :call && (begin
                                                var"##331" = var"##330"[2]
                                                var"##331" isa AbstractArray
                                            end && (length(var"##331") === 2 && (var"##331"[1] == :Symbol && begin
                                                        var"##332" = var"##331"[2]
                                                        true
                                                    end)))))))
                    a = var"##327"
                    b = var"##332"
                    var"##return#320" = begin
                            isdefined(m, :Symbol) || return false
                            return a.value === Symbol(b)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa Tuple{Expr, QuoteNode} && (begin
                                begin
                                    var"##cache#334" = nothing
                                end
                                var"##333" = var"##322"[1]
                                var"##333" isa Expr
                            end && (begin
                                    if var"##cache#334" === nothing
                                        var"##cache#334" = Some(((var"##333").head, (var"##333").args))
                                    end
                                    var"##335" = (var"##cache#334").value
                                    var"##335" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##335"[1] == :call && (begin
                                            var"##336" = var"##335"[2]
                                            var"##336" isa AbstractArray
                                        end && (length(var"##336") === 2 && (var"##336"[1] == :Symbol && begin
                                                    var"##337" = var"##336"[2]
                                                    var"##338" = var"##322"[2]
                                                    var"##338" isa QuoteNode
                                                end))))))
                    a = var"##338"
                    b = var"##337"
                    var"##return#320" = begin
                            isdefined(m, :Symbol) || return false
                            return a.value === Symbol(b)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa Tuple{Expr, Expr} && (begin
                                var"##339" = var"##322"[1]
                                var"##339" isa Expr
                            end && begin
                                var"##340" = var"##322"[2]
                                var"##340" isa Expr
                            end)
                    var"##return#320" = begin
                            return compare_expr_object(m, lhs, rhs)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{Expr, var2} where var2 <: Type) && (begin
                                begin
                                    var"##cache#342" = nothing
                                end
                                var"##341" = var"##322"[1]
                                var"##341" isa Expr
                            end && (begin
                                    if var"##cache#342" === nothing
                                        var"##cache#342" = Some(((var"##341").head, (var"##341").args))
                                    end
                                    var"##343" = (var"##cache#342").value
                                    var"##343" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##343"[1] == :curly && (begin
                                            var"##344" = var"##343"[2]
                                            var"##344" isa AbstractArray
                                        end && ((ndims(var"##344") === 1 && length(var"##344") >= 0) && begin
                                                var"##345" = var"##322"[2]
                                                var"##345" isa Type
                                            end)))))
                    var"##return#320" = begin
                            return guess_type(m, lhs) == rhs
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{var1, Expr} where var1 <: Type) && (begin
                                var"##346" = var"##322"[1]
                                var"##346" isa Type
                            end && (begin
                                    begin
                                        var"##cache#348" = nothing
                                    end
                                    var"##347" = var"##322"[2]
                                    var"##347" isa Expr
                                end && (begin
                                        if var"##cache#348" === nothing
                                            var"##cache#348" = Some(((var"##347").head, (var"##347").args))
                                        end
                                        var"##349" = (var"##cache#348").value
                                        var"##349" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                    end && (var"##349"[1] == :curly && (begin
                                                var"##350" = var"##349"[2]
                                                var"##350" isa AbstractArray
                                            end && (ndims(var"##350") === 1 && length(var"##350") >= 0))))))
                    var"##return#320" = begin
                            return lhs == guess_type(m, rhs)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{var1, Symbol} where var1) && begin
                            var"##351" = var"##322"[1]
                            var"##352" = var"##322"[2]
                            var"##352" isa Symbol
                        end
                    a = var"##351"
                    b = var"##352"
                    var"##return#320" = begin
                            isdefined(m, b) || return false
                            return getfield(m, b) === a
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{Symbol, var2} where var2) && (begin
                                var"##353" = var"##322"[1]
                                var"##353" isa Symbol
                            end && begin
                                var"##354" = var"##322"[2]
                                true
                            end)
                    a = var"##354"
                    b = var"##353"
                    var"##return#320" = begin
                            isdefined(m, b) || return false
                            return getfield(m, b) === a
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{var1, Expr} where var1) && begin
                            var"##355" = var"##322"[1]
                            var"##356" = var"##322"[2]
                            var"##356" isa Expr
                        end
                    a = var"##355"
                    b = var"##356"
                    var"##return#320" = begin
                            try
                                return a == Base.eval(m, b)
                            catch _
                                return false
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{Expr, var2} where var2) && (begin
                                var"##357" = var"##322"[1]
                                var"##357" isa Expr
                            end && begin
                                var"##358" = var"##322"[2]
                                true
                            end)
                    a = var"##358"
                    b = var"##357"
                    var"##return#320" = begin
                            try
                                return a == Base.eval(m, b)
                            catch _
                                return false
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{Module, var2} where var2) && (begin
                                var"##359" = var"##322"[1]
                                var"##359" isa Module
                            end && begin
                                var"##360" = var"##322"[2]
                                true
                            end)
                    a = var"##359"
                    b = var"##360"
                    var"##return#320" = begin
                            mod = guess_module(m, b)
                            isnothing(mod) && return false
                            return a === mod
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
                if var"##322" isa (Tuple{var1, Module} where var1) && begin
                            var"##361" = var"##322"[1]
                            var"##362" = var"##322"[2]
                            var"##362" isa Module
                        end
                    a = var"##362"
                    b = var"##361"
                    var"##return#320" = begin
                            mod = guess_module(m, b)
                            isnothing(mod) && return false
                            return a === mod
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
            end
            if var"##322" isa Tuple{TypeVar, TypeVar}
                if begin
                            var"##363" = var"##322"[1]
                            var"##363" isa TypeVar
                        end && begin
                            var"##364" = var"##322"[2]
                            var"##364" isa TypeVar
                        end
                    var"##return#320" = begin
                            compare_expr(m, lhs.lb, rhs.lb) || return false
                            compare_expr(m, lhs.ub, rhs.ub) || return false
                            return true
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
            end
            if var"##322" isa Tuple{LineNumberNode, LineNumberNode}
                if begin
                            var"##365" = var"##322"[1]
                            var"##365" isa LineNumberNode
                        end && begin
                            var"##366" = var"##322"[2]
                            var"##366" isa LineNumberNode
                        end
                    var"##return#320" = begin
                            return true
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
            end
            if var"##322" isa Tuple{Variable, Variable}
                if begin
                            var"##367" = var"##322"[1]
                            var"##367" isa Variable
                        end && begin
                            var"##368" = var"##322"[2]
                            var"##368" isa Variable
                        end
                    var"##return#320" = begin
                            return true
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
            end
            if var"##322" isa Tuple{GlobalRef, GlobalRef}
                if begin
                            var"##369" = var"##322"[1]
                            var"##369" isa GlobalRef
                        end && begin
                            var"##370" = var"##322"[2]
                            var"##370" isa GlobalRef
                        end
                    var"##return#320" = begin
                            return lhs === rhs
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#321#371")))
                end
            end
            begin
                var"##return#320" = begin
                        return lhs == rhs
                    end
                $(Expr(:symbolicgoto, Symbol("####final#321#371")))
            end
            error("matching non-exhaustive, at #= none:161 =#")
            $(Expr(:symboliclabel, Symbol("####final#321#371")))
            var"##return#320"
        end
    end
    function compare_expr_object(m::Module, lhs::Expr, rhs::Expr)
        begin
            true
            var"##374" = (lhs, rhs)
            if var"##374" isa Tuple{Expr, Expr}
                if begin
                            begin
                                var"##cache#376" = nothing
                            end
                            var"##375" = var"##374"[1]
                            var"##375" isa Expr
                        end && (begin
                                if var"##cache#376" === nothing
                                    var"##cache#376" = Some(((var"##375").head, (var"##375").args))
                                end
                                var"##377" = (var"##cache#376").value
                                var"##377" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##377"[1] == :(::) && (begin
                                        var"##378" = var"##377"[2]
                                        var"##378" isa AbstractArray
                                    end && (length(var"##378") === 1 && (begin
                                                var"##379" = var"##378"[1]
                                                begin
                                                    var"##cache#381" = nothing
                                                end
                                                var"##380" = var"##374"[2]
                                                var"##380" isa Expr
                                            end && (begin
                                                    if var"##cache#381" === nothing
                                                        var"##cache#381" = Some(((var"##380").head, (var"##380").args))
                                                    end
                                                    var"##382" = (var"##cache#381").value
                                                    var"##382" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##382"[1] == :(::) && (begin
                                                            var"##383" = var"##382"[2]
                                                            var"##383" isa AbstractArray
                                                        end && (length(var"##383") === 1 && begin
                                                                var"##384" = var"##383"[1]
                                                                true
                                                            end)))))))))
                    tx = var"##379"
                    ty = var"##384"
                    var"##return#372" = begin
                            tx = guess_type(m, tx)
                            ty = guess_type(m, ty)
                            return compare_expr(m, tx, ty)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
                if begin
                            begin
                                var"##cache#386" = nothing
                            end
                            var"##385" = var"##374"[1]
                            var"##385" isa Expr
                        end && (begin
                                if var"##cache#386" === nothing
                                    var"##cache#386" = Some(((var"##385").head, (var"##385").args))
                                end
                                var"##387" = (var"##cache#386").value
                                var"##387" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##387"[1] == :(::) && (begin
                                        var"##388" = var"##387"[2]
                                        var"##388" isa AbstractArray
                                    end && (length(var"##388") === 2 && (begin
                                                var"##389" = var"##388"[1]
                                                var"##390" = var"##388"[2]
                                                begin
                                                    var"##cache#392" = nothing
                                                end
                                                var"##391" = var"##374"[2]
                                                var"##391" isa Expr
                                            end && (begin
                                                    if var"##cache#392" === nothing
                                                        var"##cache#392" = Some(((var"##391").head, (var"##391").args))
                                                    end
                                                    var"##393" = (var"##cache#392").value
                                                    var"##393" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##393"[1] == :(::) && (begin
                                                            var"##394" = var"##393"[2]
                                                            var"##394" isa AbstractArray
                                                        end && (length(var"##394") === 2 && begin
                                                                var"##395" = var"##394"[1]
                                                                var"##396" = var"##394"[2]
                                                                true
                                                            end)))))))))
                    tx = var"##390"
                    y = var"##395"
                    ty = var"##396"
                    x = var"##389"
                    var"##return#372" = begin
                            tx = guess_type(m, tx)
                            ty = guess_type(m, ty)
                            return compare_expr(m, x, y) && compare_expr(m, tx, ty)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
                if begin
                            begin
                                var"##cache#398" = nothing
                            end
                            var"##397" = var"##374"[1]
                            var"##397" isa Expr
                        end && (begin
                                if var"##cache#398" === nothing
                                    var"##cache#398" = Some(((var"##397").head, (var"##397").args))
                                end
                                var"##399" = (var"##cache#398").value
                                var"##399" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##399"[1] == :. && (begin
                                        var"##400" = var"##399"[2]
                                        var"##400" isa AbstractArray
                                    end && (length(var"##400") === 2 && (begin
                                                var"##401" = var"##400"[1]
                                                var"##402" = var"##400"[2]
                                                var"##402" isa QuoteNode
                                            end && (begin
                                                    var"##403" = (var"##402").value
                                                    begin
                                                        var"##cache#405" = nothing
                                                    end
                                                    var"##404" = var"##374"[2]
                                                    var"##404" isa Expr
                                                end && (begin
                                                        if var"##cache#405" === nothing
                                                            var"##cache#405" = Some(((var"##404").head, (var"##404").args))
                                                        end
                                                        var"##406" = (var"##cache#405").value
                                                        var"##406" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                    end && (var"##406"[1] == :. && (begin
                                                                var"##407" = var"##406"[2]
                                                                var"##407" isa AbstractArray
                                                            end && (length(var"##407") === 2 && (begin
                                                                        var"##408" = var"##407"[1]
                                                                        var"##409" = var"##407"[2]
                                                                        var"##409" isa QuoteNode
                                                                    end && begin
                                                                        var"##410" = (var"##409").value
                                                                        true
                                                                    end)))))))))))
                    sub_a = var"##403"
                    sub_b = var"##410"
                    mod_b = var"##408"
                    mod_a = var"##401"
                    var"##return#372" = begin
                            mod_a = guess_module(m, mod_a)
                            mod_b = guess_module(m, mod_b)
                            compare_expr(m, mod_a, mod_b) || return false
                            return compare_expr(m, sub_a, sub_b)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
                if begin
                            begin
                                var"##cache#412" = nothing
                            end
                            var"##411" = var"##374"[1]
                            var"##411" isa Expr
                        end && (begin
                                if var"##cache#412" === nothing
                                    var"##cache#412" = Some(((var"##411").head, (var"##411").args))
                                end
                                var"##413" = (var"##cache#412").value
                                var"##413" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##413"[1] == :where && (begin
                                        var"##414" = var"##413"[2]
                                        var"##414" isa AbstractArray
                                    end && ((ndims(var"##414") === 1 && length(var"##414") >= 0) && (begin
                                                begin
                                                    var"##cache#416" = nothing
                                                end
                                                var"##415" = var"##374"[2]
                                                var"##415" isa Expr
                                            end && (begin
                                                    if var"##cache#416" === nothing
                                                        var"##cache#416" = Some(((var"##415").head, (var"##415").args))
                                                    end
                                                    var"##417" = (var"##cache#416").value
                                                    var"##417" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##417"[1] == :where && (begin
                                                            var"##418" = var"##417"[2]
                                                            var"##418" isa AbstractArray
                                                        end && (ndims(var"##418") === 1 && length(var"##418") >= 0)))))))))
                    var"##return#372" = begin
                            return compare_where(m, lhs, rhs)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
                if begin
                            begin
                                var"##cache#420" = nothing
                            end
                            var"##419" = var"##374"[1]
                            var"##419" isa Expr
                        end && (begin
                                if var"##cache#420" === nothing
                                    var"##cache#420" = Some(((var"##419").head, (var"##419").args))
                                end
                                var"##421" = (var"##cache#420").value
                                var"##421" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##421"[1] == :curly && (begin
                                        var"##422" = var"##421"[2]
                                        var"##422" isa AbstractArray
                                    end && ((ndims(var"##422") === 1 && length(var"##422") >= 0) && (begin
                                                begin
                                                    var"##cache#424" = nothing
                                                end
                                                var"##423" = var"##374"[2]
                                                var"##423" isa Expr
                                            end && (begin
                                                    if var"##cache#424" === nothing
                                                        var"##cache#424" = Some(((var"##423").head, (var"##423").args))
                                                    end
                                                    var"##425" = (var"##cache#424").value
                                                    var"##425" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##425"[1] == :curly && (begin
                                                            var"##426" = var"##425"[2]
                                                            var"##426" isa AbstractArray
                                                        end && (ndims(var"##426") === 1 && length(var"##426") >= 0)))))))))
                    var"##return#372" = begin
                            return compare_curly(m, lhs, rhs)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
                if begin
                            begin
                                var"##cache#428" = nothing
                            end
                            var"##427" = var"##374"[1]
                            var"##427" isa Expr
                        end && (begin
                                if var"##cache#428" === nothing
                                    var"##cache#428" = Some(((var"##427").head, (var"##427").args))
                                end
                                var"##429" = (var"##cache#428").value
                                var"##429" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##429"[1] == :macrocall && (begin
                                        var"##430" = var"##429"[2]
                                        var"##430" isa AbstractArray
                                    end && ((ndims(var"##430") === 1 && length(var"##430") >= 0) && (begin
                                                begin
                                                    var"##cache#432" = nothing
                                                end
                                                var"##431" = var"##374"[2]
                                                var"##431" isa Expr
                                            end && (begin
                                                    if var"##cache#432" === nothing
                                                        var"##cache#432" = Some(((var"##431").head, (var"##431").args))
                                                    end
                                                    var"##433" = (var"##cache#432").value
                                                    var"##433" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##433"[1] == :macrocall && (begin
                                                            var"##434" = var"##433"[2]
                                                            var"##434" isa AbstractArray
                                                        end && (ndims(var"##434") === 1 && length(var"##434") >= 0)))))))))
                    var"##return#372" = begin
                            return compare_macrocall(m, lhs, rhs)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
                if begin
                            begin
                                var"##cache#436" = nothing
                            end
                            var"##435" = var"##374"[1]
                            var"##435" isa Expr
                        end && (begin
                                if var"##cache#436" === nothing
                                    var"##cache#436" = Some(((var"##435").head, (var"##435").args))
                                end
                                var"##437" = (var"##cache#436").value
                                var"##437" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##437"[1] == :function && (begin
                                        var"##438" = var"##437"[2]
                                        var"##438" isa AbstractArray
                                    end && ((ndims(var"##438") === 1 && length(var"##438") >= 0) && (begin
                                                begin
                                                    var"##cache#440" = nothing
                                                end
                                                var"##439" = var"##374"[2]
                                                var"##439" isa Expr
                                            end && (begin
                                                    if var"##cache#440" === nothing
                                                        var"##cache#440" = Some(((var"##439").head, (var"##439").args))
                                                    end
                                                    var"##441" = (var"##cache#440").value
                                                    var"##441" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##441"[1] == :function && (begin
                                                            var"##442" = var"##441"[2]
                                                            var"##442" isa AbstractArray
                                                        end && (ndims(var"##442") === 1 && length(var"##442") >= 0)))))))))
                    var"##return#372" = begin
                            return compare_function(m, lhs, rhs)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
                if begin
                            var"##443" = var"##374"[1]
                            var"##443" isa Expr
                        end && begin
                            var"##444" = var"##374"[2]
                            var"##444" isa Expr
                        end
                    var"##return#372" = begin
                            lhs.head === rhs.head || return false
                            length(lhs.args) == length(rhs.args) || return false
                            for (a, b) = zip(lhs.args, rhs.args)
                                compare_expr(m, a, b) || return false
                            end
                            return true
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#373#445")))
                end
            end
            begin
                var"##return#372" = begin
                        return lhs == rhs
                    end
                $(Expr(:symbolicgoto, Symbol("####final#373#445")))
            end
            error("matching non-exhaustive, at #= none:206 =#")
            $(Expr(:symboliclabel, Symbol("####final#373#445")))
            var"##return#372"
        end
    end
    function compare_macrocall(m::Module, lhs::Expr, rhs::Expr)
        length(lhs.args) == length(rhs.args) || return false
        compare_expr(lhs.args[1], rhs.args[1]) || return false
        for (a, b) = zip(lhs.args[3:end], rhs.args[3:end])
            compare_expr(m, a, b) || return false
        end
        return true
    end
    function compare_function(m::Module, lhs::Expr, rhs::Expr)
        (lhs, rhs) = (canonicalize_lambda_head(lhs), canonicalize_lambda_head(rhs))
        compare_expr(m, lhs.args[1], rhs.args[1]) || return false
        length(lhs.args) == length(rhs.args) == 1 && return true
        function is_all_lineno(ex)
            Meta.isexpr(ex, :block) || return false
            return all((x->begin
                            x isa LineNumberNode
                        end), ex.args)
        end
        if length(lhs.args) == 1
            is_all_lineno(rhs.args[2]) && return true
        elseif length(rhs.args) == 1
            is_all_lineno(lhs.args[2]) && return true
        end
        return compare_expr(m, lhs.args[2], rhs.args[2])
    end
    function compare_curly(m::Module, lhs::Expr, rhs::Expr)
        type_a = guess_type(m, lhs)
        type_b = guess_type(m, rhs)
        (name_a, name_b) = (lhs.args[1], rhs.args[1])
        (typevars_a, typevars_b) = (lhs.args[2:end], rhs.args[2:end])
        if type_a isa Type || type_b isa Type
            return type_a === type_b
        else
            compare_expr(m, guess_type(m, name_a), guess_type(m, name_b)) || return false
            length(typevars_a) == length(typevars_b) || return false
            return all(zip(typevars_a, typevars_b)) do (a, b)
                    compare_expr(m, guess_type(m, a), guess_type(m, b))
                end
        end
    end
    function compare_where(m::Module, lhs::Expr, rhs::Expr)
        (lbody, lparams) = (lhs.args[1], lhs.args[2:end])
        (rbody, rparams) = (rhs.args[1], rhs.args[2:end])
        lbody = mark_typevars(lbody, name_only.(lparams))
        rbody = mark_typevars(rbody, name_only.(rparams))
        compare_expr(m, lbody, rbody) || return false
        return all(zip(lparams, rparams)) do (l, r)
                l isa Symbol && (r isa Symbol && return true)
                Meta.isexpr(l, :<:) && Meta.isexpr(r, :<:) || return false
                return compare_expr(m, l.args[2], r.args[2])
            end
    end
    function mark_typevars(expr, typevars::Vector{Symbol})
        sub = Substitute() do expr
                expr isa Symbol && (expr in typevars && return true)
                return false
            end
        return sub(Variable, expr)
    end
