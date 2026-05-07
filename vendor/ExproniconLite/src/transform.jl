
    #= none:2 =# Core.@doc "    eval_interp(m::Module, ex)\n\nevaluate the interpolation operator in `ex` inside given module `m`.\n" function eval_interp(m::Module, ex)
            ex isa Expr || return ex
            if ex.head === :$
                x = ex.args[1]
                if x isa Symbol && isdefined(m, x)
                    return Base.eval(m, x)
                else
                    return ex
                end
            end
            return Expr(ex.head, map((x->begin
                                eval_interp(m, x)
                            end), ex.args)...)
        end
    #= none:20 =# Core.@doc "    eval_literal(m::Module, ex)\n\nEvaluate the literal values and insert them back to the expression.\nThe literal value can be checked via [`is_literal`](@ref).\n" function eval_literal(m::Module, ex)
            ex isa Expr || return ex
            if ex.head === :call && all(is_literal, ex.args[2:end])
                return Base.eval(m, ex)
            end
            return Expr(ex.head, map((x->begin
                                eval_literal(m, x)
                            end), ex.args)...)
        end
    #= none:34 =# Core.@doc "    substitute(ex::Expr, old=>new)\n\nSubstitute the old symbol `old` with `new`.\n" function substitute(ex::Expr, replace::Pair)
            (old, new) = replace
            sub = Substitute() do x
                    x == old
                end
            return sub((_->begin
                            new
                        end), ex)
        end
    #= none:47 =# Core.@doc "    name_only(ex)\n\nRemove everything else leaving just names, currently supports\nfunction calls, type with type variables, subtype operator `<:`\nand type annotation `::`.\n\n# Example\n\n```julia\njulia> using Expronicon\n\njulia> name_only(:(sin(2)))\n:sin\n\njulia> name_only(:(Foo{Int}))\n:Foo\n\njulia> name_only(:(Foo{Int} <: Real))\n:Foo\n\njulia> name_only(:(x::Int))\n:x\n```\n" function name_only(#= none:72 =# @nospecialize(ex))
            ex isa Symbol && return ex
            ex isa QuoteNode && return ex.value
            ex isa Expr || error("unsupported expression $(ex)")
            ex.head in [:call, :curly, :<:, :(::), :where, :function, :kw, :(=), :->] && return name_only(ex.args[1])
            ex.head === :. && return name_only(ex.args[2])
            ex.head === :... && return name_only(ex.args[1])
            ex.head === :module && return name_only(ex.args[2])
            error("unsupported expression $(ex)")
        end
    #= none:83 =# Core.@doc "    annotations_only(ex)\n\nReturn type annotations only. See also [`name_only`](@ref).\n" function annotations_only(#= none:88 =# @nospecialize(ex))
            ex isa Symbol && return :(())
            ex isa Expr || error("unsupported expression $(ex)")
            Meta.isexpr(ex, :...) && return annotations_only(ex.args[1])
            Meta.isexpr(ex, :(::)) && return ex.args[end]
            error("unsupported expression $(ex)")
        end
    #= none:96 =# Core.@doc "    rm_lineinfo(ex)\n\nRemove `LineNumberNode` in a given expression.\n\n!!! tips\n\n    the `LineNumberNode` inside macro calls won't be removed since\n    the `macrocall` expression requires a `LineNumberNode`. See also\n    [issues/#9](https://github.com/Roger-luo/Expronicon.jl/issues/9).\n" function rm_lineinfo(ex)
            let
                begin
                    var"##cache#1409" = nothing
                end
                var"##return#1406" = nothing
                var"##1408" = ex
                if var"##1408" isa Expr
                    if begin
                                if var"##cache#1409" === nothing
                                    var"##cache#1409" = Some(((var"##1408").head, (var"##1408").args))
                                end
                                var"##1410" = (var"##cache#1409").value
                                var"##1410" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1410"[1] == :macrocall && (begin
                                        var"##1411" = var"##1410"[2]
                                        var"##1411" isa AbstractArray
                                    end && ((ndims(var"##1411") === 1 && length(var"##1411") >= 2) && begin
                                            var"##1412" = var"##1411"[1]
                                            var"##1413" = var"##1411"[2]
                                            var"##1414" = SubArray(var"##1411", (3:length(var"##1411"),))
                                            true
                                        end)))
                        var"##return#1406" = let line = var"##1413", name = var"##1412", args = var"##1414"
                                Expr(:macrocall, name, line, map(rm_lineinfo, args)...)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1407#1419")))
                    end
                    if begin
                                var"##1415" = (var"##cache#1409").value
                                var"##1415" isa (Tuple{var1, var2} where {var2 <: AbstractArray, var1})
                            end && (begin
                                    var"##1416" = var"##1415"[1]
                                    var"##1417" = var"##1415"[2]
                                    var"##1417" isa AbstractArray
                                end && ((ndims(var"##1417") === 1 && length(var"##1417") >= 0) && begin
                                        var"##1418" = SubArray(var"##1417", (1:length(var"##1417"),))
                                        true
                                    end))
                        var"##return#1406" = let args = var"##1418", head = var"##1416"
                                Expr(head, map(rm_lineinfo, filter((x->begin
                                                    !(x isa LineNumberNode)
                                                end), args))...)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1407#1419")))
                    end
                end
                begin
                    var"##return#1406" = let
                            ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1407#1419")))
                end
                error("matching non-exhaustive, at #= none:108 =#")
                $(Expr(:symboliclabel, Symbol("####final#1407#1419")))
                var"##return#1406"
            end
        end
    #= none:115 =# Base.@kwdef struct PrettifyOptions
            rm_lineinfo::Bool = true
            flatten_blocks::Bool = true
            rm_nothing::Bool = true
            preserve_last_nothing::Bool = false
            rm_single_block::Bool = true
            alias_gensym::Bool = true
            renumber_gensym::Bool = true
        end
    #= none:125 =# Core.@doc "    prettify(ex; kw...)\n\nPrettify given expression, remove all `LineNumberNode` and\nextra code blocks.\n\n# Options (Kwargs)\n\nAll the options are `true` by default.\n\n- `rm_lineinfo`: remove `LineNumberNode`.\n- `flatten_blocks`: flatten `begin ... end` code blocks.\n- `rm_nothing`: remove `nothing` in the `begin ... end`.\n- `preserve_last_nothing`: preserve the last `nothing` in the `begin ... end`.\n- `rm_single_block`: remove single `begin ... end`.\n- `alias_gensym`: replace `##<name>#<num>` with `<name>_<id>`.\n- `renumber_gensym`: renumber the gensym id.\n\n!!! tips\n\n    the `LineNumberNode` inside macro calls won't be removed since\n    the `macrocall` expression requires a `LineNumberNode`. See also\n    [issues/#9](https://github.com/Roger-luo/Expronicon.jl/issues/9).\n" function prettify(ex; kw...)
            prettify(ex, PrettifyOptions(; kw...))
        end
    function prettify(ex, options::PrettifyOptions)
        ex isa Expr || return ex
        ex = if options.renumber_gensym
                renumber_gensym(ex)
            else
                ex
            end
        ex = if options.alias_gensym
                alias_gensym(ex)
            else
                ex
            end
        for _ = 1:10
            curr = prettify_pass(ex, options)
            ex == curr && break
            ex = curr
        end
        return ex
    end
    function prettify_pass(ex, options::PrettifyOptions)
        ex = if options.rm_lineinfo
                rm_lineinfo(ex)
            else
                ex
            end
        ex = if options.flatten_blocks
                flatten_blocks(ex)
            else
                ex
            end
        ex = if options.rm_nothing
                rm_nothing(ex; options.preserve_last_nothing)
            else
                ex
            end
        ex = if options.rm_single_block
                rm_single_block(ex)
            else
                ex
            end
        return ex
    end
    #= none:173 =# Core.@doc "    flatten_blocks(ex)\n\nRemove hierachical expression blocks.\n" function flatten_blocks(ex)
            ex isa Expr || return ex
            ex.head === :block || return Expr(ex.head, map(_flatten_blocks, ex.args)...)
            has_block = any(ex.args) do x
                    x isa Expr && x.head === :block
                end
            if has_block
                return flatten_blocks(_flatten_blocks(ex))
            end
            return Expr(ex.head, map(flatten_blocks, ex.args)...)
        end
    function _flatten_blocks(ex)
        ex isa Expr || return ex
        ex.head === :block || return Expr(ex.head, map(flatten_blocks, ex.args)...)
        args = []
        for stmt = ex.args
            if stmt isa Expr && stmt.head === :block
                for each = stmt.args
                    push!(args, flatten_blocks(each))
                end
            else
                push!(args, flatten_blocks(stmt))
            end
        end
        return Expr(:block, args...)
    end
    #= none:208 =# Core.@doc "    rm_nothing(ex)\n\nRemove the constant value `nothing` in given expression `ex`.\n\n# Keyword Arguments\n\n- `preserve_last_nothing`: if `true`, the last `nothing`\n    will be preserved.\n" function rm_nothing(ex; preserve_last_nothing::Bool = false)
            let
                begin
                    var"##cache#1423" = nothing
                end
                var"##return#1420" = nothing
                var"##1422" = ex
                if var"##1422" isa Expr
                    if begin
                                if var"##cache#1423" === nothing
                                    var"##cache#1423" = Some(((var"##1422").head, (var"##1422").args))
                                end
                                var"##1424" = (var"##cache#1423").value
                                var"##1424" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1424"[1] == :block && (begin
                                        var"##1425" = var"##1424"[2]
                                        var"##1425" isa AbstractArray
                                    end && ((ndims(var"##1425") === 1 && length(var"##1425") >= 0) && begin
                                            var"##1426" = SubArray(var"##1425", (1:length(var"##1425"),))
                                            true
                                        end)))
                        var"##return#1420" = let args = var"##1426"
                                if preserve_last_nothing && (!(isempty(args)) && isnothing(last(args)))
                                    Expr(:block, filter((x->begin
                                                    x !== nothing
                                                end), args)..., nothing)
                                else
                                    Expr(:block, filter((x->begin
                                                    x !== nothing
                                                end), args)...)
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1421#1431")))
                    end
                    if begin
                                var"##1427" = (var"##cache#1423").value
                                var"##1427" isa (Tuple{var1, var2} where {var2 <: AbstractArray, var1})
                            end && (begin
                                    var"##1428" = var"##1427"[1]
                                    var"##1429" = var"##1427"[2]
                                    var"##1429" isa AbstractArray
                                end && ((ndims(var"##1429") === 1 && length(var"##1429") >= 0) && begin
                                        var"##1430" = SubArray(var"##1429", (1:length(var"##1429"),))
                                        true
                                    end))
                        var"##return#1420" = let args = var"##1430", head = var"##1428"
                                Expr(head, map(rm_nothing, args)...)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1421#1431")))
                    end
                end
                begin
                    var"##return#1420" = let
                            ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1421#1431")))
                end
                error("matching non-exhaustive, at #= none:219 =#")
                $(Expr(:symboliclabel, Symbol("####final#1421#1431")))
                var"##return#1420"
            end
        end
    #= none:232 =# Core.@doc "    canonicalize_lambda_head(ex)\n\nCanonicalize the `Expr(:function, Expr(:block, x, Expr(:(=), key, default)), body)` to\n\n```julia\nExpr(:function, Expr(:tuple, Expr(:parameters, Expr(:kw, key, default)), x), body)\n```\n" function canonicalize_lambda_head(ex)
            let
                begin
                    var"##cache#1435" = nothing
                end
                var"##return#1432" = nothing
                var"##1434" = ex
                if var"##1434" isa Expr
                    if begin
                                if var"##cache#1435" === nothing
                                    var"##cache#1435" = Some(((var"##1434").head, (var"##1434").args))
                                end
                                var"##1436" = (var"##cache#1435").value
                                var"##1436" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1436"[1] == :function && (begin
                                        var"##1437" = var"##1436"[2]
                                        var"##1437" isa AbstractArray
                                    end && (length(var"##1437") === 2 && (begin
                                                begin
                                                    var"##cache#1439" = nothing
                                                end
                                                var"##1438" = var"##1437"[1]
                                                var"##1438" isa Expr
                                            end && (begin
                                                    if var"##cache#1439" === nothing
                                                        var"##cache#1439" = Some(((var"##1438").head, (var"##1438").args))
                                                    end
                                                    var"##1440" = (var"##cache#1439").value
                                                    var"##1440" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1440"[1] == :block && (begin
                                                            var"##1441" = var"##1440"[2]
                                                            var"##1441" isa AbstractArray
                                                        end && (length(var"##1441") === 2 && begin
                                                                var"##1442" = var"##1441"[1]
                                                                var"##1443" = var"##1441"[2]
                                                                var"##1444" = var"##1437"[2]
                                                                true
                                                            end))))))))
                        var"##return#1432" = let y = var"##1443", body = var"##1444", x = var"##1442"
                                Expr(:function, Expr(:tuple, Expr(:parameters, y), x), body)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1433#1488")))
                    end
                    if begin
                                var"##1445" = (var"##cache#1435").value
                                var"##1445" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1445"[1] == :function && (begin
                                        var"##1446" = var"##1445"[2]
                                        var"##1446" isa AbstractArray
                                    end && (length(var"##1446") === 2 && (begin
                                                begin
                                                    var"##cache#1448" = nothing
                                                end
                                                var"##1447" = var"##1446"[1]
                                                var"##1447" isa Expr
                                            end && (begin
                                                    if var"##cache#1448" === nothing
                                                        var"##cache#1448" = Some(((var"##1447").head, (var"##1447").args))
                                                    end
                                                    var"##1449" = (var"##cache#1448").value
                                                    var"##1449" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1449"[1] == :block && (begin
                                                            var"##1450" = var"##1449"[2]
                                                            var"##1450" isa AbstractArray
                                                        end && (length(var"##1450") === 3 && (begin
                                                                    var"##1451" = var"##1450"[1]
                                                                    var"##1452" = var"##1450"[2]
                                                                    var"##1452" isa LineNumberNode
                                                                end && begin
                                                                    var"##1453" = var"##1450"[3]
                                                                    var"##1454" = var"##1446"[2]
                                                                    true
                                                                end)))))))))
                        var"##return#1432" = let y = var"##1453", body = var"##1454", x = var"##1451"
                                Expr(:function, Expr(:tuple, Expr(:parameters, y), x), body)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1433#1488")))
                    end
                    if begin
                                var"##1455" = (var"##cache#1435").value
                                var"##1455" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1455"[1] == :function && (begin
                                        var"##1456" = var"##1455"[2]
                                        var"##1456" isa AbstractArray
                                    end && (length(var"##1456") === 2 && (begin
                                                begin
                                                    var"##cache#1458" = nothing
                                                end
                                                var"##1457" = var"##1456"[1]
                                                var"##1457" isa Expr
                                            end && (begin
                                                    if var"##cache#1458" === nothing
                                                        var"##cache#1458" = Some(((var"##1457").head, (var"##1457").args))
                                                    end
                                                    var"##1459" = (var"##cache#1458").value
                                                    var"##1459" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1459"[1] == :block && (begin
                                                            var"##1460" = var"##1459"[2]
                                                            var"##1460" isa AbstractArray
                                                        end && (length(var"##1460") === 2 && (begin
                                                                    var"##1461" = var"##1460"[1]
                                                                    begin
                                                                        var"##cache#1463" = nothing
                                                                    end
                                                                    var"##1462" = var"##1460"[2]
                                                                    var"##1462" isa Expr
                                                                end && (begin
                                                                        if var"##cache#1463" === nothing
                                                                            var"##cache#1463" = Some(((var"##1462").head, (var"##1462").args))
                                                                        end
                                                                        var"##1464" = (var"##cache#1463").value
                                                                        var"##1464" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                    end && (var"##1464"[1] == :(=) && (begin
                                                                                var"##1465" = var"##1464"[2]
                                                                                var"##1465" isa AbstractArray
                                                                            end && (length(var"##1465") === 2 && begin
                                                                                    var"##1466" = var"##1465"[1]
                                                                                    var"##1467" = var"##1465"[2]
                                                                                    var"##1468" = var"##1456"[2]
                                                                                    true
                                                                                end)))))))))))))
                        var"##return#1432" = let default = var"##1467", key = var"##1466", body = var"##1468", x = var"##1461"
                                Expr(:function, Expr(:tuple, Expr(:parameters, Expr(:kw, key, default)), x), body)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1433#1488")))
                    end
                    if begin
                                var"##1469" = (var"##cache#1435").value
                                var"##1469" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1469"[1] == :function && (begin
                                        var"##1470" = var"##1469"[2]
                                        var"##1470" isa AbstractArray
                                    end && (length(var"##1470") === 2 && (begin
                                                begin
                                                    var"##cache#1472" = nothing
                                                end
                                                var"##1471" = var"##1470"[1]
                                                var"##1471" isa Expr
                                            end && (begin
                                                    if var"##cache#1472" === nothing
                                                        var"##cache#1472" = Some(((var"##1471").head, (var"##1471").args))
                                                    end
                                                    var"##1473" = (var"##cache#1472").value
                                                    var"##1473" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1473"[1] == :block && (begin
                                                            var"##1474" = var"##1473"[2]
                                                            var"##1474" isa AbstractArray
                                                        end && (length(var"##1474") === 3 && (begin
                                                                    var"##1475" = var"##1474"[1]
                                                                    var"##1476" = var"##1474"[2]
                                                                    var"##1476" isa LineNumberNode
                                                                end && (begin
                                                                        begin
                                                                            var"##cache#1478" = nothing
                                                                        end
                                                                        var"##1477" = var"##1474"[3]
                                                                        var"##1477" isa Expr
                                                                    end && (begin
                                                                            if var"##cache#1478" === nothing
                                                                                var"##cache#1478" = Some(((var"##1477").head, (var"##1477").args))
                                                                            end
                                                                            var"##1479" = (var"##cache#1478").value
                                                                            var"##1479" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                        end && (var"##1479"[1] == :(=) && (begin
                                                                                    var"##1480" = var"##1479"[2]
                                                                                    var"##1480" isa AbstractArray
                                                                                end && (length(var"##1480") === 2 && begin
                                                                                        var"##1481" = var"##1480"[1]
                                                                                        var"##1482" = var"##1480"[2]
                                                                                        var"##1483" = var"##1470"[2]
                                                                                        true
                                                                                    end))))))))))))))
                        var"##return#1432" = let default = var"##1482", key = var"##1481", body = var"##1483", x = var"##1475"
                                Expr(:function, Expr(:tuple, Expr(:parameters, Expr(:kw, key, default)), x), body)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1433#1488")))
                    end
                    if begin
                                var"##1484" = (var"##cache#1435").value
                                var"##1484" isa (Tuple{var1, var2} where {var2 <: AbstractArray, var1})
                            end && (begin
                                    var"##1485" = var"##1484"[1]
                                    var"##1486" = var"##1484"[2]
                                    var"##1486" isa AbstractArray
                                end && ((ndims(var"##1486") === 1 && length(var"##1486") >= 0) && begin
                                        var"##1487" = SubArray(var"##1486", (1:length(var"##1486"),))
                                        true
                                    end))
                        var"##return#1432" = let args = var"##1487", head = var"##1485"
                                Expr(head, map(canonicalize_lambda_head, args)...)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#1433#1488")))
                    end
                end
                begin
                    var"##return#1432" = let
                            ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1433#1488")))
                end
                error("matching non-exhaustive, at #= none:242 =#")
                $(Expr(:symboliclabel, Symbol("####final#1433#1488")))
                var"##return#1432"
            end
        end
    function rm_single_block(ex)
        let
            begin
                var"##cache#1492" = nothing
            end
            var"##return#1489" = nothing
            var"##1491" = ex
            if var"##1491" isa Expr
                if begin
                            if var"##cache#1492" === nothing
                                var"##cache#1492" = Some(((var"##1491").head, (var"##1491").args))
                            end
                            var"##1493" = (var"##cache#1492").value
                            var"##1493" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1493"[1] == :(=) && (begin
                                    var"##1494" = var"##1493"[2]
                                    var"##1494" isa AbstractArray
                                end && (ndims(var"##1494") === 1 && length(var"##1494") >= 0)))
                    var"##return#1489" = let
                            ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1495" = (var"##cache#1492").value
                            var"##1495" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1495"[1] == :-> && (begin
                                    var"##1496" = var"##1495"[2]
                                    var"##1496" isa AbstractArray
                                end && (ndims(var"##1496") === 1 && length(var"##1496") >= 0)))
                    var"##return#1489" = let
                            ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1497" = (var"##cache#1492").value
                            var"##1497" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1497"[1] == :quote && (begin
                                    var"##1498" = var"##1497"[2]
                                    var"##1498" isa AbstractArray
                                end && ((ndims(var"##1498") === 1 && length(var"##1498") >= 0) && begin
                                        var"##1499" = SubArray(var"##1498", (1:length(var"##1498"),))
                                        true
                                    end)))
                    var"##return#1489" = let xs = var"##1499"
                            ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1500" = (var"##cache#1492").value
                            var"##1500" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1500"[1] == :block && (begin
                                    var"##1501" = var"##1500"[2]
                                    var"##1501" isa AbstractArray
                                end && (length(var"##1501") === 1 && (begin
                                            begin
                                                var"##cache#1503" = nothing
                                            end
                                            var"##1502" = var"##1501"[1]
                                            var"##1502" isa Expr
                                        end && (begin
                                                if var"##cache#1503" === nothing
                                                    var"##cache#1503" = Some(((var"##1502").head, (var"##1502").args))
                                                end
                                                var"##1504" = (var"##cache#1503").value
                                                var"##1504" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1504"[1] == :quote && (begin
                                                        var"##1505" = var"##1504"[2]
                                                        var"##1505" isa AbstractArray
                                                    end && ((ndims(var"##1505") === 1 && length(var"##1505") >= 0) && begin
                                                            var"##1506" = SubArray(var"##1505", (1:length(var"##1505"),))
                                                            true
                                                        end))))))))
                    var"##return#1489" = let xs = var"##1506"
                            ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1507" = (var"##cache#1492").value
                            var"##1507" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1507"[1] == :try && (begin
                                    var"##1508" = var"##1507"[2]
                                    var"##1508" isa AbstractArray
                                end && (length(var"##1508") === 4 && (begin
                                            begin
                                                var"##cache#1510" = nothing
                                            end
                                            var"##1509" = var"##1508"[1]
                                            var"##1509" isa Expr
                                        end && (begin
                                                if var"##cache#1510" === nothing
                                                    var"##cache#1510" = Some(((var"##1509").head, (var"##1509").args))
                                                end
                                                var"##1511" = (var"##cache#1510").value
                                                var"##1511" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1511"[1] == :block && (begin
                                                        var"##1512" = var"##1511"[2]
                                                        var"##1512" isa AbstractArray
                                                    end && ((ndims(var"##1512") === 1 && length(var"##1512") >= 0) && (begin
                                                                var"##1513" = SubArray(var"##1512", (1:length(var"##1512"),))
                                                                var"##1508"[2] === false
                                                            end && (var"##1508"[3] === false && (begin
                                                                        begin
                                                                            var"##cache#1515" = nothing
                                                                        end
                                                                        var"##1514" = var"##1508"[4]
                                                                        var"##1514" isa Expr
                                                                    end && (begin
                                                                            if var"##cache#1515" === nothing
                                                                                var"##cache#1515" = Some(((var"##1514").head, (var"##1514").args))
                                                                            end
                                                                            var"##1516" = (var"##cache#1515").value
                                                                            var"##1516" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                        end && (var"##1516"[1] == :block && (begin
                                                                                    var"##1517" = var"##1516"[2]
                                                                                    var"##1517" isa AbstractArray
                                                                                end && ((ndims(var"##1517") === 1 && length(var"##1517") >= 0) && begin
                                                                                        var"##1518" = SubArray(var"##1517", (1:length(var"##1517"),))
                                                                                        true
                                                                                    end)))))))))))))))
                    var"##return#1489" = let try_stmts = var"##1513", finally_stmts = var"##1518"
                            Expr(:try, Expr(:block, rm_single_block.(try_stmts)...), false, false, Expr(:block, rm_single_block.(finally_stmts)...))
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1519" = (var"##cache#1492").value
                            var"##1519" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1519"[1] == :try && (begin
                                    var"##1520" = var"##1519"[2]
                                    var"##1520" isa AbstractArray
                                end && (length(var"##1520") === 3 && (begin
                                            begin
                                                var"##cache#1522" = nothing
                                            end
                                            var"##1521" = var"##1520"[1]
                                            var"##1521" isa Expr
                                        end && (begin
                                                if var"##cache#1522" === nothing
                                                    var"##cache#1522" = Some(((var"##1521").head, (var"##1521").args))
                                                end
                                                var"##1523" = (var"##cache#1522").value
                                                var"##1523" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1523"[1] == :block && (begin
                                                        var"##1524" = var"##1523"[2]
                                                        var"##1524" isa AbstractArray
                                                    end && ((ndims(var"##1524") === 1 && length(var"##1524") >= 0) && (begin
                                                                var"##1525" = SubArray(var"##1524", (1:length(var"##1524"),))
                                                                var"##1526" = var"##1520"[2]
                                                                begin
                                                                    var"##cache#1528" = nothing
                                                                end
                                                                var"##1527" = var"##1520"[3]
                                                                var"##1527" isa Expr
                                                            end && (begin
                                                                    if var"##cache#1528" === nothing
                                                                        var"##cache#1528" = Some(((var"##1527").head, (var"##1527").args))
                                                                    end
                                                                    var"##1529" = (var"##cache#1528").value
                                                                    var"##1529" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##1529"[1] == :block && (begin
                                                                            var"##1530" = var"##1529"[2]
                                                                            var"##1530" isa AbstractArray
                                                                        end && ((ndims(var"##1530") === 1 && length(var"##1530") >= 0) && begin
                                                                                var"##1531" = SubArray(var"##1530", (1:length(var"##1530"),))
                                                                                true
                                                                            end)))))))))))))
                    var"##return#1489" = let try_stmts = var"##1525", catch_stmts = var"##1531", catch_var = var"##1526"
                            Expr(:try, Expr(:block, rm_single_block.(try_stmts)...), catch_var, Expr(:block, rm_single_block.(catch_stmts)...))
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1532" = (var"##cache#1492").value
                            var"##1532" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1532"[1] == :try && (begin
                                    var"##1533" = var"##1532"[2]
                                    var"##1533" isa AbstractArray
                                end && (length(var"##1533") === 4 && (begin
                                            begin
                                                var"##cache#1535" = nothing
                                            end
                                            var"##1534" = var"##1533"[1]
                                            var"##1534" isa Expr
                                        end && (begin
                                                if var"##cache#1535" === nothing
                                                    var"##cache#1535" = Some(((var"##1534").head, (var"##1534").args))
                                                end
                                                var"##1536" = (var"##cache#1535").value
                                                var"##1536" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1536"[1] == :block && (begin
                                                        var"##1537" = var"##1536"[2]
                                                        var"##1537" isa AbstractArray
                                                    end && ((ndims(var"##1537") === 1 && length(var"##1537") >= 0) && (begin
                                                                var"##1538" = SubArray(var"##1537", (1:length(var"##1537"),))
                                                                var"##1539" = var"##1533"[2]
                                                                begin
                                                                    var"##cache#1541" = nothing
                                                                end
                                                                var"##1540" = var"##1533"[3]
                                                                var"##1540" isa Expr
                                                            end && (begin
                                                                    if var"##cache#1541" === nothing
                                                                        var"##cache#1541" = Some(((var"##1540").head, (var"##1540").args))
                                                                    end
                                                                    var"##1542" = (var"##cache#1541").value
                                                                    var"##1542" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##1542"[1] == :block && (begin
                                                                            var"##1543" = var"##1542"[2]
                                                                            var"##1543" isa AbstractArray
                                                                        end && ((ndims(var"##1543") === 1 && length(var"##1543") >= 0) && (begin
                                                                                    var"##1544" = SubArray(var"##1543", (1:length(var"##1543"),))
                                                                                    begin
                                                                                        var"##cache#1546" = nothing
                                                                                    end
                                                                                    var"##1545" = var"##1533"[4]
                                                                                    var"##1545" isa Expr
                                                                                end && (begin
                                                                                        if var"##cache#1546" === nothing
                                                                                            var"##cache#1546" = Some(((var"##1545").head, (var"##1545").args))
                                                                                        end
                                                                                        var"##1547" = (var"##cache#1546").value
                                                                                        var"##1547" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                                    end && (var"##1547"[1] == :block && (begin
                                                                                                var"##1548" = var"##1547"[2]
                                                                                                var"##1548" isa AbstractArray
                                                                                            end && ((ndims(var"##1548") === 1 && length(var"##1548") >= 0) && begin
                                                                                                    var"##1549" = SubArray(var"##1548", (1:length(var"##1548"),))
                                                                                                    true
                                                                                                end))))))))))))))))))
                    var"##return#1489" = let try_stmts = var"##1538", catch_stmts = var"##1544", catch_var = var"##1539", finally_stmts = var"##1549"
                            Expr(:try, Expr(:block, rm_single_block.(try_stmts)...), catch_var, Expr(:block, rm_single_block.(catch_stmts)...), Expr(:block, rm_single_block.(finally_stmts)...))
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1550" = (var"##cache#1492").value
                            var"##1550" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1550"[1] == :block && (begin
                                    var"##1551" = var"##1550"[2]
                                    var"##1551" isa AbstractArray
                                end && (length(var"##1551") === 1 && begin
                                        var"##1552" = var"##1551"[1]
                                        true
                                    end)))
                    var"##return#1489" = let stmt = var"##1552"
                            stmt
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
                if begin
                            var"##1553" = (var"##cache#1492").value
                            var"##1553" isa (Tuple{var1, var2} where {var2 <: AbstractArray, var1})
                        end && (begin
                                var"##1554" = var"##1553"[1]
                                var"##1555" = var"##1553"[2]
                                var"##1555" isa AbstractArray
                            end && ((ndims(var"##1555") === 1 && length(var"##1555") >= 0) && begin
                                    var"##1556" = SubArray(var"##1555", (1:length(var"##1555"),))
                                    true
                                end))
                    var"##return#1489" = let args = var"##1556", head = var"##1554"
                            Expr(head, map(rm_single_block, args)...)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
                end
            end
            begin
                var"##return#1489" = let
                        ex
                    end
                $(Expr(:symbolicgoto, Symbol("####final#1490#1557")))
            end
            error("matching non-exhaustive, at #= none:258 =#")
            $(Expr(:symboliclabel, Symbol("####final#1490#1557")))
            var"##return#1489"
        end
    end
    #= none:286 =# Core.@doc "    rm_annotations(x)\n\nRemove type annotation of given expression.\n" function rm_annotations(x)
            x isa Expr || return x
            if x.head == :(::)
                if length(x.args) == 1
                    return gensym("::$(x.args[1])")
                else
                    return x.args[1]
                end
            elseif x.head in [:(=), :kw]
                return rm_annotations(x.args[1])
            else
                return Expr(x.head, map(rm_annotations, x.args)...)
            end
        end
    #= none:306 =# Core.@doc "    alias_gensym(ex)\n\nReplace gensym with `<name>_<id>`.\n\n!!! note\n    Borrowed from [MacroTools](https://github.com/FluxML/MacroTools.jl).\n" alias_gensym(ex) = begin
                alias_gensym!(Dict{Symbol, Symbol}(), Dict{Symbol, Int}(), ex)
            end
    function alias_gensym!(d::Dict{Symbol, Symbol}, count::Dict{Symbol, Int}, ex)
        if is_gensym(ex)
            haskey(d, ex) && return d[ex]
            name = Symbol(gensym_name(ex))
            id = get(count, name, 0) + 1
            d[ex] = Symbol(name, :_, id)
            count[name] = id
            return d[ex]
        end
        ex isa Expr || return ex
        args = map(ex.args) do x
                alias_gensym!(d, count, x)
            end
        return Expr(ex.head, args...)
    end
    #= none:334 =# Core.@doc "    renumber_gensym(ex)\n\nRe-number gensym with counter from this expression.\nProduce a deterministic gensym name for testing etc.\nSee also: [`alias_gensym`](@ref)\n" renumber_gensym(ex) = begin
                renumber_gensym!(Dict{Symbol, Symbol}(), Dict{Symbol, Int}(), ex)
            end
    function renumber_gensym!(d::Dict{Symbol, Symbol}, count::Dict{Symbol, Int}, ex)
        function renumber(head, m)
            name = Symbol(m.captures[1])
            id = (count[name] = get(count, name, 0) + 1)
            return d[ex] = Symbol(head, name, "#", id)
        end
        if is_gensym(ex)
            haskey(d, ex) && return d[ex]
            gensym_str = String(ex)
            m = Base.match(r"##(.+)#\d+", gensym_str)
            m === nothing || return renumber("##", m)
            m = Base.match(r"#\d+#(.+)", gensym_str)
            m === nothing || return renumber("#", m)
        end
        ex isa Expr || return ex
        args = map(ex.args) do x
                renumber_gensym!(d, count, x)
            end
        return Expr(ex.head, args...)
    end
    #= none:368 =# Core.@doc "    expr_map(f, c...; skip_nothing::Bool=false)\n\nSimilar to `Base.map`, but expects `f` to return an expression,\nand will concanate these expression as a `Expr(:block, ...)`\nexpression.\n\nSkip `nothing` if `skip_nothing` is `true`.\n\n# Example\n\n```jldoctest\njulia> expr_map(1:10, 2:11) do i,j\n           :(1 + \$i + \$j)\n       end\nquote\n    1 + 1 + 2\n    1 + 2 + 3\n    1 + 3 + 4\n    1 + 4 + 5\n    1 + 5 + 6\n    1 + 6 + 7\n    1 + 7 + 8\n    1 + 8 + 9\n    1 + 9 + 10\n    1 + 10 + 11\nend\n```\n" function expr_map(f, c...; skip_nothing::Bool = false)
            ex = Expr(:block)
            for args = zip(c...)
                ret = f(args...)
                skip_nothing && (isnothing(ret) && continue)
                push!(ex.args, ret)
            end
            return ex
        end
    #= none:407 =# Core.@doc "    nexprs(f, n::Int)\n\nCreate `n` similar expressions by evaluating `f`.\n\n# Example\n\n```jldoctest\njulia> nexprs(5) do k\n           :(1 + \$k)\n       end\nquote\n    1 + 1\n    1 + 2\n    1 + 3\n    1 + 4\n    1 + 5\nend\n```\n" nexprs(f, k::Int) = begin
                expr_map(f, 1:k)
            end
    #= none:429 =# Core.@doc "    Substitute(condition) -> substitute(f(expr), expr)\n\nReturns a function that substitutes `expr` with\n`f(expr)` if `condition(expr)` is true. Applied\nrecursively to all sub-expressions.\n\n# Example\n\n```jldoctest\njulia> sub = Substitute() do expr\n           expr isa Symbol && expr in [:x] && return true\n           return false\n       end;\n\njulia> sub(_->1, :(x + y))\n:(1 + y)\n```\n" struct Substitute
            condition
        end
    (sub::Substitute)(f) = begin
            Base.Fix1(sub, f)
        end
    function (sub::Substitute)(f, expr)
        if sub.condition(expr)
            return f(expr)
        elseif expr isa Expr
            return Expr(expr.head, map(sub(f), expr.args)...)
        else
            return expr
        end
    end
