
    #= none:1 =# Core.@doc "    guess_module(m, ex)\n\nGuess the module of given expression `ex` (of a module)\nin module `m`. If `ex` is not a module, or cannot be\ndetermined return `nothing`.\n" function guess_module(m::Module, ex)
            begin
                begin
                    var"##cache#495" = nothing
                end
                var"##494" = ex
                if var"##494" isa Expr
                    if begin
                                if var"##cache#495" === nothing
                                    var"##cache#495" = Some(((var"##494").head, (var"##494").args))
                                end
                                var"##496" = (var"##cache#495").value
                                var"##496" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##496"[1] == :. && (begin
                                        var"##497" = var"##496"[2]
                                        var"##497" isa AbstractArray
                                    end && (length(var"##497") === 2 && (begin
                                                var"##498" = var"##497"[1]
                                                var"##499" = var"##497"[2]
                                                var"##499" isa QuoteNode
                                            end && begin
                                                var"##500" = (var"##499").value
                                                true
                                            end))))
                        name = var"##498"
                        sub = var"##500"
                        var"##return#492" = begin
                                mod = guess_module(m, name)
                                if mod isa Module
                                    return guess_module(mod, sub)
                                else
                                    return ex
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#493#501")))
                    end
                end
                if var"##494" isa Symbol
                    if isdefined(m, ex)
                        var"##return#492" = begin
                                maybe_m = getproperty(m, ex)
                                maybe_m isa Module && return maybe_m
                                return ex
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#493#501")))
                    end
                end
                if var"##494" isa Module
                    begin
                        var"##return#492" = begin
                                return ex
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#493#501")))
                    end
                end
                begin
                    var"##return#492" = begin
                            return ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#493#501")))
                end
                error("matching non-exhaustive, at #= none:9 =#")
                $(Expr(:symboliclabel, Symbol("####final#493#501")))
                var"##return#492"
            end
        end
    #= none:28 =# Core.@doc "    guess_type(m::Module, ex)\n\nGuess the actual type of expression `ex` (of a type) in module `m`.\nReturns the type if it can be determined, otherwise returns the\nexpression. This function is used in [`compare_expr`](@ref).\n" function guess_type(m::Module, ex)
            begin
                begin
                    var"##cache#505" = nothing
                end
                var"##504" = ex
                if var"##504" isa Expr
                    if begin
                                if var"##cache#505" === nothing
                                    var"##cache#505" = Some(((var"##504").head, (var"##504").args))
                                end
                                var"##506" = (var"##cache#505").value
                                var"##506" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##506"[1] == :curly && (begin
                                        var"##507" = var"##506"[2]
                                        var"##507" isa AbstractArray
                                    end && ((ndims(var"##507") === 1 && length(var"##507") >= 1) && begin
                                            var"##508" = var"##507"[1]
                                            var"##509" = SubArray(var"##507", (2:length(var"##507"),))
                                            true
                                        end)))
                        typevars = var"##509"
                        name = var"##508"
                        var"##return#502" = begin
                                type = guess_type(m, name)
                                typevars = map(typevars) do typevar
                                        guess_type(m, typevar)
                                    end
                                if type === Union
                                    all((x->begin
                                                    x isa Type
                                                end), typevars) || return ex
                                    return Union{typevars...}
                                elseif type isa Type && all(is_valid_typevar, typevars)
                                    return type{typevars...}
                                else
                                    return ex
                                end
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#503#510")))
                    end
                end
                if var"##504" isa Symbol
                    begin
                        var"##return#502" = begin
                                isdefined(m, ex) || return ex
                                return getproperty(m, ex)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#503#510")))
                    end
                end
                if var"##504" isa Type
                    begin
                        var"##return#502" = begin
                                return ex
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#503#510")))
                    end
                end
                if var"##504" isa QuoteNode
                    begin
                        var"##return#502" = begin
                                return ex
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#503#510")))
                    end
                end
                begin
                    var"##return#502" = begin
                            return ex
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#503#510")))
                end
                error("matching non-exhaustive, at #= none:36 =#")
                $(Expr(:symboliclabel, Symbol("####final#503#510")))
                var"##return#502"
            end
        end
    function guess_value(m::Module, ex)
        let
            begin
                var"##cache#514" = nothing
            end
            var"##return#511" = nothing
            var"##513" = ex
            if var"##513" isa Expr
                if begin
                            if var"##cache#514" === nothing
                                var"##cache#514" = Some(((var"##513").head, (var"##513").args))
                            end
                            var"##515" = (var"##cache#514").value
                            var"##515" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##515"[1] == :. && (begin
                                    var"##516" = var"##515"[2]
                                    var"##516" isa AbstractArray
                                end && (length(var"##516") === 2 && (begin
                                            var"##517" = var"##516"[1]
                                            var"##518" = var"##516"[2]
                                            var"##518" isa QuoteNode
                                        end && begin
                                            var"##519" = (var"##518").value
                                            true
                                        end))))
                    var"##return#511" = let name = var"##517", sub = var"##519"
                            mod = guess_module(m, name)
                            if mod isa Module
                                return guess_value(mod, sub)
                            else
                                return ex
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#512#520")))
                end
            end
            if var"##513" isa Symbol
                begin
                    var"##return#511" = let
                            if isdefined(m, ex)
                                getfield(m, ex)
                            else
                                ex
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#512#520")))
                end
            end
            begin
                var"##return#511" = let
                        ex
                    end
                $(Expr(:symbolicgoto, Symbol("####final#512#520")))
            end
            error("matching non-exhaustive, at #= none:62 =#")
            $(Expr(:symboliclabel, Symbol("####final#512#520")))
            var"##return#511"
        end
    end
