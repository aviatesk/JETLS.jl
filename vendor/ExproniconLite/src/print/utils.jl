
    function mapjoin(f, xs, sep = ", ")
        for (i, x) = enumerate(xs)
            f(x)
            if i != length(xs)
                f(sep)
            end
        end
        return nothing
    end
    function is_line_no(x)
        x isa LineNumberNode && return true
        x isa Expr && (x.head == :line && return true)
        return false
    end
    function split_body(body)
        return let
                begin
                    var"##cache#1401" = nothing
                end
                var"##return#1398" = nothing
                var"##1400" = body
                if var"##1400" isa Expr && (begin
                                if var"##cache#1401" === nothing
                                    var"##cache#1401" = Some(((var"##1400").head, (var"##1400").args))
                                end
                                var"##1402" = (var"##cache#1401").value
                                var"##1402" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1402"[1] == :block && (begin
                                        var"##1403" = var"##1402"[2]
                                        var"##1403" isa AbstractArray
                                    end && ((ndims(var"##1403") === 1 && length(var"##1403") >= 0) && begin
                                            var"##1404" = SubArray(var"##1403", (1:length(var"##1403"),))
                                            true
                                        end))))
                    var"##return#1398" = let stmts = var"##1404"
                            stmts
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1399#1405")))
                end
                begin
                    var"##return#1398" = let
                            (body,)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1399#1405")))
                end
                error("matching non-exhaustive, at #= none:18 =#")
                $(Expr(:symboliclabel, Symbol("####final#1399#1405")))
                var"##return#1398"
            end
    end
    const expr_infix_wide = Set{Symbol}([:(=), :+=, :-=, :*=, :/=, :\=, :^=, :&=, :|=, :÷=, :%=, :>>>=, :>>=, :<<=, :.=, :.+=, :.-=, :.*=, :./=, :.\=, :.^=, :.&=, :.|=, :.÷=, :.%=, :.>>>=, :.>>=, :.<<=, :&&, :||, :<:, :$=, :⊻=, :>:, :-->])
