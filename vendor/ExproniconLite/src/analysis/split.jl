
    #= none:1 =# Core.@doc "    split_doc(ex::Expr) -> line, doc, expr\n\nSplit doc string from given expression.\n" function split_doc(ex)
            begin
                begin
                    var"##cache#524" = nothing
                end
                var"##523" = ex
                if var"##523" isa Expr
                    if begin
                                if var"##cache#524" === nothing
                                    var"##cache#524" = Some(((var"##523").head, (var"##523").args))
                                end
                                var"##525" = (var"##cache#524").value
                                var"##525" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##525"[1] == :macrocall && (begin
                                        var"##526" = var"##525"[2]
                                        var"##526" isa AbstractArray
                                    end && (length(var"##526") === 4 && (begin
                                                var"##527" = var"##526"[1]
                                                var"##527" == GlobalRef(Core, Symbol("@doc"))
                                            end && begin
                                                var"##528" = var"##526"[2]
                                                var"##529" = var"##526"[3]
                                                var"##530" = var"##526"[4]
                                                true
                                            end))))
                        line = var"##528"
                        expr = var"##530"
                        doc = var"##529"
                        var"##return#521" = begin
                                return (line, doc, expr)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#522#551")))
                    end
                    if begin
                                var"##531" = (var"##cache#524").value
                                var"##531" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##531"[1] == :macrocall && (begin
                                        var"##532" = var"##531"[2]
                                        var"##532" isa AbstractArray
                                    end && (length(var"##532") === 4 && (begin
                                                var"##533" = var"##532"[1]
                                                var"##533" == Symbol("@doc")
                                            end && begin
                                                var"##534" = var"##532"[2]
                                                var"##535" = var"##532"[3]
                                                var"##536" = var"##532"[4]
                                                true
                                            end))))
                        line = var"##534"
                        expr = var"##536"
                        doc = var"##535"
                        var"##return#521" = begin
                                return (line, doc, expr)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#522#551")))
                    end
                    if begin
                                var"##537" = (var"##cache#524").value
                                var"##537" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##537"[1] == :macrocall && (begin
                                        var"##538" = var"##537"[2]
                                        var"##538" isa AbstractArray
                                    end && (length(var"##538") === 4 && (begin
                                                begin
                                                    var"##cache#540" = nothing
                                                end
                                                var"##539" = var"##538"[1]
                                                var"##539" isa Expr
                                            end && (begin
                                                    if var"##cache#540" === nothing
                                                        var"##cache#540" = Some(((var"##539").head, (var"##539").args))
                                                    end
                                                    var"##541" = (var"##cache#540").value
                                                    var"##541" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##541"[1] == :. && (begin
                                                            var"##542" = var"##541"[2]
                                                            var"##542" isa AbstractArray
                                                        end && (length(var"##542") === 2 && (var"##542"[1] == :Core && (begin
                                                                        var"##543" = var"##542"[2]
                                                                        var"##543" == QuoteNode(Symbol("@doc"))
                                                                    end && begin
                                                                        var"##544" = var"##538"[2]
                                                                        var"##545" = var"##538"[3]
                                                                        var"##546" = var"##538"[4]
                                                                        true
                                                                    end))))))))))
                        line = var"##544"
                        expr = var"##546"
                        doc = var"##545"
                        var"##return#521" = begin
                                return (line, doc, expr)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#522#551")))
                    end
                    if begin
                                var"##547" = (var"##cache#524").value
                                var"##547" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##547"[1] == :block && (begin
                                        var"##548" = var"##547"[2]
                                        var"##548" isa AbstractArray
                                    end && (length(var"##548") === 2 && (begin
                                                var"##549" = var"##548"[1]
                                                var"##549" isa LineNumberNode
                                            end && begin
                                                var"##550" = var"##548"[2]
                                                true
                                            end))))
                        stmt = var"##550"
                        var"##return#521" = begin
                                (line, doc, expr) = split_doc(stmt)
                                return (line, doc, expr)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#522#551")))
                    end
                end
                begin
                    var"##return#521" = begin
                            return (nothing, nothing, ex)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#522#551")))
                end
                error("matching non-exhaustive, at #= none:7 =#")
                $(Expr(:symboliclabel, Symbol("####final#522#551")))
                var"##return#521"
            end
        end
    #= none:24 =# Core.@doc "    split_function(ex::Expr) -> head, call, body\n\nSplit function head declaration with function body.\n" function split_function(ex; source = nothing)
            ret = split_function_nothrow(ex)
            isnothing(ret) && throw(SyntaxError("expect a function expr, got $(ex)", source))
            ret
        end
    function split_function_nothrow(ex)
        let
            begin
                var"##cache#555" = nothing
            end
            var"##return#552" = nothing
            var"##554" = ex
            if var"##554" isa Expr
                if begin
                            if var"##cache#555" === nothing
                                var"##cache#555" = Some(((var"##554").head, (var"##554").args))
                            end
                            var"##556" = (var"##cache#555").value
                            var"##556" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##556"[1] == :function && (begin
                                    var"##557" = var"##556"[2]
                                    var"##557" isa AbstractArray
                                end && (length(var"##557") === 2 && begin
                                        var"##558" = var"##557"[1]
                                        var"##559" = var"##557"[2]
                                        true
                                    end)))
                    var"##return#552" = let call = var"##558", body = var"##559"
                            (:function, call, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#553#572")))
                end
                if begin
                            var"##560" = (var"##cache#555").value
                            var"##560" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##560"[1] == :function && (begin
                                    var"##561" = var"##560"[2]
                                    var"##561" isa AbstractArray
                                end && (length(var"##561") === 2 && begin
                                        var"##562" = var"##561"[1]
                                        var"##563" = var"##561"[2]
                                        true
                                    end)))
                    var"##return#552" = let call = var"##562", body = var"##563"
                            (:function, call, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#553#572")))
                end
                if begin
                            var"##564" = (var"##cache#555").value
                            var"##564" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##564"[1] == :(=) && (begin
                                    var"##565" = var"##564"[2]
                                    var"##565" isa AbstractArray
                                end && (length(var"##565") === 2 && begin
                                        var"##566" = var"##565"[1]
                                        var"##567" = var"##565"[2]
                                        true
                                    end)))
                    var"##return#552" = let call = var"##566", body = var"##567"
                            let
                                begin
                                    var"##cache#576" = nothing
                                end
                                var"##return#573" = nothing
                                var"##575" = call
                                if var"##575" isa Expr
                                    if begin
                                                if var"##cache#576" === nothing
                                                    var"##cache#576" = Some(((var"##575").head, (var"##575").args))
                                                end
                                                var"##577" = (var"##cache#576").value
                                                var"##577" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##577"[1] == :call && (begin
                                                        var"##578" = var"##577"[2]
                                                        var"##578" isa AbstractArray
                                                    end && ((ndims(var"##578") === 1 && length(var"##578") >= 1) && begin
                                                            var"##579" = var"##578"[1]
                                                            var"##580" = SubArray(var"##578", (2:length(var"##578"),))
                                                            true
                                                        end)))
                                        var"##return#573" = let f = var"##579", args = var"##580"
                                                true
                                            end
                                        $(Expr(:symbolicgoto, Symbol("####final#574#613")))
                                    end
                                    if begin
                                                var"##581" = (var"##cache#576").value
                                                var"##581" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##581"[1] == :(::) && (begin
                                                        var"##582" = var"##581"[2]
                                                        var"##582" isa AbstractArray
                                                    end && (length(var"##582") === 2 && (begin
                                                                begin
                                                                    var"##cache#584" = nothing
                                                                end
                                                                var"##583" = var"##582"[1]
                                                                var"##583" isa Expr
                                                            end && (begin
                                                                    if var"##cache#584" === nothing
                                                                        var"##cache#584" = Some(((var"##583").head, (var"##583").args))
                                                                    end
                                                                    var"##585" = (var"##cache#584").value
                                                                    var"##585" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##585"[1] == :call && (begin
                                                                            var"##586" = var"##585"[2]
                                                                            var"##586" isa AbstractArray
                                                                        end && ((ndims(var"##586") === 1 && length(var"##586") >= 1) && begin
                                                                                var"##587" = var"##586"[1]
                                                                                var"##588" = SubArray(var"##586", (2:length(var"##586"),))
                                                                                var"##589" = var"##582"[2]
                                                                                true
                                                                            end))))))))
                                        var"##return#573" = let f = var"##587", args = var"##588", rettype = var"##589"
                                                true
                                            end
                                        $(Expr(:symbolicgoto, Symbol("####final#574#613")))
                                    end
                                    if begin
                                                var"##590" = (var"##cache#576").value
                                                var"##590" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##590"[1] == :where && (begin
                                                        var"##591" = var"##590"[2]
                                                        var"##591" isa AbstractArray
                                                    end && ((ndims(var"##591") === 1 && length(var"##591") >= 1) && (begin
                                                                begin
                                                                    var"##cache#593" = nothing
                                                                end
                                                                var"##592" = var"##591"[1]
                                                                var"##592" isa Expr
                                                            end && (begin
                                                                    if var"##cache#593" === nothing
                                                                        var"##cache#593" = Some(((var"##592").head, (var"##592").args))
                                                                    end
                                                                    var"##594" = (var"##cache#593").value
                                                                    var"##594" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##594"[1] == :call && (begin
                                                                            var"##595" = var"##594"[2]
                                                                            var"##595" isa AbstractArray
                                                                        end && ((ndims(var"##595") === 1 && length(var"##595") >= 1) && begin
                                                                                var"##596" = var"##595"[1]
                                                                                var"##597" = SubArray(var"##595", (2:length(var"##595"),))
                                                                                var"##598" = SubArray(var"##591", (2:length(var"##591"),))
                                                                                true
                                                                            end))))))))
                                        var"##return#573" = let f = var"##596", params = var"##598", args = var"##597"
                                                true
                                            end
                                        $(Expr(:symbolicgoto, Symbol("####final#574#613")))
                                    end
                                    if begin
                                                var"##599" = (var"##cache#576").value
                                                var"##599" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##599"[1] == :where && (begin
                                                        var"##600" = var"##599"[2]
                                                        var"##600" isa AbstractArray
                                                    end && ((ndims(var"##600") === 1 && length(var"##600") >= 1) && (begin
                                                                begin
                                                                    var"##cache#602" = nothing
                                                                end
                                                                var"##601" = var"##600"[1]
                                                                var"##601" isa Expr
                                                            end && (begin
                                                                    if var"##cache#602" === nothing
                                                                        var"##cache#602" = Some(((var"##601").head, (var"##601").args))
                                                                    end
                                                                    var"##603" = (var"##cache#602").value
                                                                    var"##603" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##603"[1] == :(::) && (begin
                                                                            var"##604" = var"##603"[2]
                                                                            var"##604" isa AbstractArray
                                                                        end && (length(var"##604") === 2 && (begin
                                                                                    begin
                                                                                        var"##cache#606" = nothing
                                                                                    end
                                                                                    var"##605" = var"##604"[1]
                                                                                    var"##605" isa Expr
                                                                                end && (begin
                                                                                        if var"##cache#606" === nothing
                                                                                            var"##cache#606" = Some(((var"##605").head, (var"##605").args))
                                                                                        end
                                                                                        var"##607" = (var"##cache#606").value
                                                                                        var"##607" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                                    end && (var"##607"[1] == :call && (begin
                                                                                                var"##608" = var"##607"[2]
                                                                                                var"##608" isa AbstractArray
                                                                                            end && ((ndims(var"##608") === 1 && length(var"##608") >= 1) && begin
                                                                                                    var"##609" = var"##608"[1]
                                                                                                    var"##610" = SubArray(var"##608", (2:length(var"##608"),))
                                                                                                    var"##611" = var"##604"[2]
                                                                                                    var"##612" = SubArray(var"##600", (2:length(var"##600"),))
                                                                                                    true
                                                                                                end)))))))))))))
                                        var"##return#573" = let f = var"##609", params = var"##612", args = var"##610", rettype = var"##611"
                                                true
                                            end
                                        $(Expr(:symbolicgoto, Symbol("####final#574#613")))
                                    end
                                end
                                begin
                                    var"##return#573" = let
                                            return nothing
                                        end
                                    $(Expr(:symbolicgoto, Symbol("####final#574#613")))
                                end
                                error("matching non-exhaustive, at #= none:40 =#")
                                $(Expr(:symboliclabel, Symbol("####final#574#613")))
                                var"##return#573"
                            end
                            (:(=), call, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#553#572")))
                end
                if begin
                            var"##568" = (var"##cache#555").value
                            var"##568" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##568"[1] == :-> && (begin
                                    var"##569" = var"##568"[2]
                                    var"##569" isa AbstractArray
                                end && (length(var"##569") === 2 && begin
                                        var"##570" = var"##569"[1]
                                        var"##571" = var"##569"[2]
                                        true
                                    end)))
                    var"##return#552" = let call = var"##570", body = var"##571"
                            (:->, call, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#553#572")))
                end
            end
            begin
                var"##return#552" = let
                        nothing
                    end
                $(Expr(:symbolicgoto, Symbol("####final#553#572")))
            end
            error("matching non-exhaustive, at #= none:36 =#")
            $(Expr(:symboliclabel, Symbol("####final#553#572")))
            var"##return#552"
        end
    end
    #= none:54 =# Core.@doc "    split_function_head(ex::Expr) -> name, args, kw, whereparams, rettype\n\nSplit function head to name, arguments, keyword arguments and where parameters.\n" function split_function_head(ex::Expr; source = nothing)
            split_head_tuple = split_function_head_nothrow(ex)
            isnothing(split_head_tuple) && throw(SyntaxError("expect a function head, got $(ex)", source))
            split_head_tuple
        end
    function split_function_head_nothrow(ex::Expr)
        let
            begin
                var"##cache#617" = nothing
            end
            var"##return#614" = nothing
            var"##616" = ex
            if var"##616" isa Expr
                if begin
                            if var"##cache#617" === nothing
                                var"##cache#617" = Some(((var"##616").head, (var"##616").args))
                            end
                            var"##618" = (var"##cache#617").value
                            var"##618" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##618"[1] == :tuple && (begin
                                    var"##619" = var"##618"[2]
                                    var"##619" isa AbstractArray
                                end && ((ndims(var"##619") === 1 && length(var"##619") >= 1) && (begin
                                            begin
                                                var"##cache#621" = nothing
                                            end
                                            var"##620" = var"##619"[1]
                                            var"##620" isa Expr
                                        end && (begin
                                                if var"##cache#621" === nothing
                                                    var"##cache#621" = Some(((var"##620").head, (var"##620").args))
                                                end
                                                var"##622" = (var"##cache#621").value
                                                var"##622" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##622"[1] == :parameters && (begin
                                                        var"##623" = var"##622"[2]
                                                        var"##623" isa AbstractArray
                                                    end && ((ndims(var"##623") === 1 && length(var"##623") >= 0) && begin
                                                            var"##624" = SubArray(var"##623", (1:length(var"##623"),))
                                                            var"##625" = SubArray(var"##619", (2:length(var"##619"),))
                                                            true
                                                        end))))))))
                    var"##return#614" = let args = var"##625", kw = var"##624"
                            (nothing, args, kw, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
                if begin
                            var"##626" = (var"##cache#617").value
                            var"##626" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##626"[1] == :tuple && (begin
                                    var"##627" = var"##626"[2]
                                    var"##627" isa AbstractArray
                                end && ((ndims(var"##627") === 1 && length(var"##627") >= 0) && begin
                                        var"##628" = SubArray(var"##627", (1:length(var"##627"),))
                                        true
                                    end)))
                    var"##return#614" = let args = var"##628"
                            (nothing, args, nothing, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
                if begin
                            var"##629" = (var"##cache#617").value
                            var"##629" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##629"[1] == :call && (begin
                                    var"##630" = var"##629"[2]
                                    var"##630" isa AbstractArray
                                end && ((ndims(var"##630") === 1 && length(var"##630") >= 2) && (begin
                                            var"##631" = var"##630"[1]
                                            begin
                                                var"##cache#633" = nothing
                                            end
                                            var"##632" = var"##630"[2]
                                            var"##632" isa Expr
                                        end && (begin
                                                if var"##cache#633" === nothing
                                                    var"##cache#633" = Some(((var"##632").head, (var"##632").args))
                                                end
                                                var"##634" = (var"##cache#633").value
                                                var"##634" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##634"[1] == :parameters && (begin
                                                        var"##635" = var"##634"[2]
                                                        var"##635" isa AbstractArray
                                                    end && ((ndims(var"##635") === 1 && length(var"##635") >= 0) && begin
                                                            var"##636" = SubArray(var"##635", (1:length(var"##635"),))
                                                            var"##637" = SubArray(var"##630", (3:length(var"##630"),))
                                                            true
                                                        end))))))))
                    var"##return#614" = let name = var"##631", args = var"##637", kw = var"##636"
                            (name, args, kw, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
                if begin
                            var"##638" = (var"##cache#617").value
                            var"##638" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##638"[1] == :call && (begin
                                    var"##639" = var"##638"[2]
                                    var"##639" isa AbstractArray
                                end && ((ndims(var"##639") === 1 && length(var"##639") >= 1) && begin
                                        var"##640" = var"##639"[1]
                                        var"##641" = SubArray(var"##639", (2:length(var"##639"),))
                                        true
                                    end)))
                    var"##return#614" = let name = var"##640", args = var"##641"
                            (name, args, nothing, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
                if begin
                            var"##642" = (var"##cache#617").value
                            var"##642" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##642"[1] == :block && (begin
                                    var"##643" = var"##642"[2]
                                    var"##643" isa AbstractArray
                                end && (length(var"##643") === 3 && (begin
                                            var"##644" = var"##643"[1]
                                            var"##645" = var"##643"[2]
                                            var"##645" isa LineNumberNode
                                        end && (begin
                                                begin
                                                    var"##cache#647" = nothing
                                                end
                                                var"##646" = var"##643"[3]
                                                var"##646" isa Expr
                                            end && (begin
                                                    if var"##cache#647" === nothing
                                                        var"##cache#647" = Some(((var"##646").head, (var"##646").args))
                                                    end
                                                    var"##648" = (var"##cache#647").value
                                                    var"##648" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##648"[1] == :(=) && (begin
                                                            var"##649" = var"##648"[2]
                                                            var"##649" isa AbstractArray
                                                        end && (length(var"##649") === 2 && begin
                                                                var"##650" = var"##649"[1]
                                                                var"##651" = var"##649"[2]
                                                                true
                                                            end)))))))))
                    var"##return#614" = let value = var"##651", kw = var"##650", x = var"##644"
                            (nothing, Any[x], Any[Expr(:kw, kw, value)], nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
                if begin
                            var"##652" = (var"##cache#617").value
                            var"##652" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##652"[1] == :block && (begin
                                    var"##653" = var"##652"[2]
                                    var"##653" isa AbstractArray
                                end && (length(var"##653") === 3 && (begin
                                            var"##654" = var"##653"[1]
                                            var"##655" = var"##653"[2]
                                            var"##655" isa LineNumberNode
                                        end && begin
                                            var"##656" = var"##653"[3]
                                            true
                                        end))))
                    var"##return#614" = let kw = var"##656", x = var"##654"
                            (nothing, Any[x], Any[kw], nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
                if begin
                            var"##657" = (var"##cache#617").value
                            var"##657" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##657"[1] == :(::) && (begin
                                    var"##658" = var"##657"[2]
                                    var"##658" isa AbstractArray
                                end && (length(var"##658") === 2 && (begin
                                            var"##659" = var"##658"[1]
                                            var"##659" isa Expr
                                        end && begin
                                            var"##660" = var"##658"[2]
                                            true
                                        end))))
                    var"##return#614" = let call = var"##659", rettype = var"##660"
                            sub_tuple = split_function_head_nothrow(call)
                            isnothing(sub_tuple) && return nothing
                            (name, args, kw, whereparams, _) = split_function_head_nothrow(call)
                            (name, args, kw, whereparams, rettype)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
                if begin
                            var"##661" = (var"##cache#617").value
                            var"##661" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##661"[1] == :where && (begin
                                    var"##662" = var"##661"[2]
                                    var"##662" isa AbstractArray
                                end && ((ndims(var"##662") === 1 && length(var"##662") >= 1) && begin
                                        var"##663" = var"##662"[1]
                                        var"##664" = SubArray(var"##662", (2:length(var"##662"),))
                                        true
                                    end)))
                    var"##return#614" = let call = var"##663", whereparams = var"##664"
                            sub_tuple = split_function_head_nothrow(call)
                            isnothing(sub_tuple) && return nothing
                            (name, args, kw, _, rettype) = sub_tuple
                            (name, args, kw, whereparams, rettype)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#615#665")))
                end
            end
            begin
                var"##return#614" = let
                        nothing
                    end
                $(Expr(:symbolicgoto, Symbol("####final#615#665")))
            end
            error("matching non-exhaustive, at #= none:66 =#")
            $(Expr(:symboliclabel, Symbol("####final#615#665")))
            var"##return#614"
        end
    end
    split_function_head_nothrow(s::Symbol) = begin
            (nothing, Any[s], nothing, nothing, nothing)
        end
    #= none:90 =# Core.@doc "    split_anonymous_function_head(ex::Expr) -> nothing, args, kw, whereparams, rettype\n\nSplit anonymous function head to arguments, keyword arguments and where parameters.\n" function split_anonymous_function_head(ex::Expr; source = nothing)
            split_head_tuple = split_anonymous_function_head_nothrow(ex)
            isnothing(split_head_tuple) && throw(SyntaxError("expect an anonymous function head, got $(ex)", source))
            split_head_tuple
        end
    split_anonymous_function_head(ex::Symbol; source = nothing) = begin
            split_anonymous_function_head_nothrow(ex)
        end
    function split_anonymous_function_head_nothrow(ex::Expr)
        let
            begin
                var"##cache#669" = nothing
            end
            var"##return#666" = nothing
            var"##668" = ex
            if var"##668" isa Expr
                if begin
                            if var"##cache#669" === nothing
                                var"##cache#669" = Some(((var"##668").head, (var"##668").args))
                            end
                            var"##670" = (var"##cache#669").value
                            var"##670" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##670"[1] == :tuple && (begin
                                    var"##671" = var"##670"[2]
                                    var"##671" isa AbstractArray
                                end && ((ndims(var"##671") === 1 && length(var"##671") >= 1) && (begin
                                            begin
                                                var"##cache#673" = nothing
                                            end
                                            var"##672" = var"##671"[1]
                                            var"##672" isa Expr
                                        end && (begin
                                                if var"##cache#673" === nothing
                                                    var"##cache#673" = Some(((var"##672").head, (var"##672").args))
                                                end
                                                var"##674" = (var"##cache#673").value
                                                var"##674" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##674"[1] == :parameters && (begin
                                                        var"##675" = var"##674"[2]
                                                        var"##675" isa AbstractArray
                                                    end && ((ndims(var"##675") === 1 && length(var"##675") >= 0) && begin
                                                            var"##676" = SubArray(var"##675", (1:length(var"##675"),))
                                                            var"##677" = SubArray(var"##671", (2:length(var"##671"),))
                                                            true
                                                        end))))))))
                    var"##return#666" = let args = var"##677", kw = var"##676"
                            (nothing, args, kw, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
                if begin
                            var"##678" = (var"##cache#669").value
                            var"##678" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##678"[1] == :tuple && (begin
                                    var"##679" = var"##678"[2]
                                    var"##679" isa AbstractArray
                                end && ((ndims(var"##679") === 1 && length(var"##679") >= 0) && begin
                                        var"##680" = SubArray(var"##679", (1:length(var"##679"),))
                                        true
                                    end)))
                    var"##return#666" = let args = var"##680"
                            (nothing, args, nothing, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
                if begin
                            var"##681" = (var"##cache#669").value
                            var"##681" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##681"[1] == :block && (begin
                                    var"##682" = var"##681"[2]
                                    var"##682" isa AbstractArray
                                end && (length(var"##682") === 3 && (begin
                                            var"##683" = var"##682"[1]
                                            var"##684" = var"##682"[2]
                                            var"##684" isa LineNumberNode
                                        end && (begin
                                                begin
                                                    var"##cache#686" = nothing
                                                end
                                                var"##685" = var"##682"[3]
                                                var"##685" isa Expr
                                            end && (begin
                                                    if var"##cache#686" === nothing
                                                        var"##cache#686" = Some(((var"##685").head, (var"##685").args))
                                                    end
                                                    var"##687" = (var"##cache#686").value
                                                    var"##687" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##687"[1] == :(=) && (begin
                                                            var"##688" = var"##687"[2]
                                                            var"##688" isa AbstractArray
                                                        end && (length(var"##688") === 2 && begin
                                                                var"##689" = var"##688"[1]
                                                                var"##690" = var"##688"[2]
                                                                true
                                                            end)))))))))
                    var"##return#666" = let value = var"##690", kw = var"##689", x = var"##683"
                            (nothing, Any[x], Any[Expr(:kw, kw, value)], nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
                if begin
                            var"##691" = (var"##cache#669").value
                            var"##691" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##691"[1] == :block && (begin
                                    var"##692" = var"##691"[2]
                                    var"##692" isa AbstractArray
                                end && (length(var"##692") === 3 && (begin
                                            var"##693" = var"##692"[1]
                                            var"##694" = var"##692"[2]
                                            var"##694" isa LineNumberNode
                                        end && begin
                                            var"##695" = var"##692"[3]
                                            true
                                        end))))
                    var"##return#666" = let kw = var"##695", x = var"##693"
                            (nothing, Any[x], Any[kw], nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
                if begin
                            var"##696" = (var"##cache#669").value
                            var"##696" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##696"[1] == :(::) && (begin
                                    var"##697" = var"##696"[2]
                                    var"##697" isa AbstractArray
                                end && (length(var"##697") === 2 && (begin
                                            var"##698" = var"##697"[1]
                                            var"##698" isa Expr
                                        end && begin
                                            var"##699" = var"##697"[2]
                                            true
                                        end))))
                    var"##return#666" = let rettype = var"##699", fh = var"##698"
                            sub_tuple = split_anonymous_function_head_nothrow(fh)
                            isnothing(sub_tuple) && return nothing
                            (name, args, kw, whereparams, _) = sub_tuple
                            (name, args, kw, whereparams, rettype)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
                if begin
                            var"##700" = (var"##cache#669").value
                            var"##700" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##700"[1] == :(::) && (begin
                                    var"##701" = var"##700"[2]
                                    var"##701" isa AbstractArray
                                end && (length(var"##701") === 2 && (begin
                                            var"##702" = var"##701"[1]
                                            var"##702" isa Symbol
                                        end && begin
                                            var"##703" = var"##701"[2]
                                            true
                                        end))))
                    var"##return#666" = let arg = var"##702", argtype = var"##703"
                            (nothing, Any[ex], nothing, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
                if begin
                            var"##704" = (var"##cache#669").value
                            var"##704" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##704"[1] == :(::) && (begin
                                    var"##705" = var"##704"[2]
                                    var"##705" isa AbstractArray
                                end && (length(var"##705") === 1 && begin
                                        var"##706" = var"##705"[1]
                                        true
                                    end)))
                    var"##return#666" = let argtype = var"##706"
                            (nothing, Any[ex], nothing, nothing, nothing)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
                if begin
                            var"##707" = (var"##cache#669").value
                            var"##707" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##707"[1] == :where && (begin
                                    var"##708" = var"##707"[2]
                                    var"##708" isa AbstractArray
                                end && ((ndims(var"##708") === 1 && length(var"##708") >= 1) && begin
                                        var"##709" = var"##708"[1]
                                        var"##710" = SubArray(var"##708", (2:length(var"##708"),))
                                        true
                                    end)))
                    var"##return#666" = let call = var"##709", whereparams = var"##710"
                            sub_tuple = split_anonymous_function_head_nothrow(call)
                            isnothing(sub_tuple) && return nothing
                            (name, args, kw, _, rettype) = sub_tuple
                            (name, args, kw, whereparams, rettype)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#667#711")))
                end
            end
            begin
                var"##return#666" = let
                        nothing
                    end
                $(Expr(:symbolicgoto, Symbol("####final#667#711")))
            end
            error("matching non-exhaustive, at #= none:105 =#")
            $(Expr(:symboliclabel, Symbol("####final#667#711")))
            var"##return#666"
        end
    end
    split_anonymous_function_head_nothrow(s::Symbol) = begin
            (nothing, Any[s], nothing, nothing, nothing)
        end
    #= none:129 =# Core.@doc "    split_struct_name(ex::Expr) -> name, typevars, supertype\n\nSplit the name, type parameters and supertype definition from `struct`\ndeclaration head.\n" function split_struct_name(#= none:135 =# @nospecialize(ex); source = nothing)
            return let
                    begin
                        var"##cache#715" = nothing
                    end
                    var"##return#712" = nothing
                    var"##714" = ex
                    if var"##714" isa Expr
                        if begin
                                    if var"##cache#715" === nothing
                                        var"##cache#715" = Some(((var"##714").head, (var"##714").args))
                                    end
                                    var"##716" = (var"##cache#715").value
                                    var"##716" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##716"[1] == :curly && (begin
                                            var"##717" = var"##716"[2]
                                            var"##717" isa AbstractArray
                                        end && ((ndims(var"##717") === 1 && length(var"##717") >= 1) && begin
                                                var"##718" = var"##717"[1]
                                                var"##719" = SubArray(var"##717", (2:length(var"##717"),))
                                                true
                                            end)))
                            var"##return#712" = let typevars = var"##719", name = var"##718"
                                    (name, typevars, nothing)
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#713#733")))
                        end
                        if begin
                                    var"##720" = (var"##cache#715").value
                                    var"##720" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##720"[1] == :<: && (begin
                                            var"##721" = var"##720"[2]
                                            var"##721" isa AbstractArray
                                        end && (length(var"##721") === 2 && (begin
                                                    begin
                                                        var"##cache#723" = nothing
                                                    end
                                                    var"##722" = var"##721"[1]
                                                    var"##722" isa Expr
                                                end && (begin
                                                        if var"##cache#723" === nothing
                                                            var"##cache#723" = Some(((var"##722").head, (var"##722").args))
                                                        end
                                                        var"##724" = (var"##cache#723").value
                                                        var"##724" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                    end && (var"##724"[1] == :curly && (begin
                                                                var"##725" = var"##724"[2]
                                                                var"##725" isa AbstractArray
                                                            end && ((ndims(var"##725") === 1 && length(var"##725") >= 1) && begin
                                                                    var"##726" = var"##725"[1]
                                                                    var"##727" = SubArray(var"##725", (2:length(var"##725"),))
                                                                    var"##728" = var"##721"[2]
                                                                    true
                                                                end))))))))
                            var"##return#712" = let typevars = var"##727", type = var"##728", name = var"##726"
                                    (name, typevars, type)
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#713#733")))
                        end
                        if begin
                                    var"##729" = (var"##cache#715").value
                                    var"##729" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                end && (var"##729"[1] == :<: && (begin
                                            var"##730" = var"##729"[2]
                                            var"##730" isa AbstractArray
                                        end && (length(var"##730") === 2 && begin
                                                var"##731" = var"##730"[1]
                                                var"##732" = var"##730"[2]
                                                true
                                            end)))
                            var"##return#712" = let type = var"##732", name = var"##731"
                                    (name, [], type)
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#713#733")))
                        end
                    end
                    if var"##714" isa Symbol
                        begin
                            var"##return#712" = let
                                    (ex, [], nothing)
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#713#733")))
                        end
                    end
                    begin
                        var"##return#712" = let
                                throw(SyntaxError("expect struct got $(ex)", source))
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#713#733")))
                    end
                    error("matching non-exhaustive, at #= none:136 =#")
                    $(Expr(:symboliclabel, Symbol("####final#713#733")))
                    var"##return#712"
                end
        end
    #= none:145 =# Core.@doc "    split_struct(ex::Expr) -> ismutable, name, typevars, supertype, body\n\nSplit struct definition head and body.\n" function split_struct(ex::Expr; source = nothing)
            ex.head === :struct || throw(SyntaxError("expect a struct expr, got $(ex)", source))
            (name, typevars, supertype) = split_struct_name(ex.args[2]; source)
            body = ex.args[3]
            return (ex.args[1], name, typevars, supertype, body)
        end
    function split_ifelse(ex::Expr)
        (conds, stmts) = ([], [])
        otherwise = split_ifelse!((conds, stmts), ex)
        return (conds, stmts, otherwise)
    end
    function split_ifelse!((conds, stmts), ex::Expr)
        ex.head in [:if, :elseif] || return ex
        push!(conds, ex.args[1])
        push!(stmts, ex.args[2])
        if length(ex.args) == 3
            return split_ifelse!((conds, stmts), ex.args[3])
        end
        return nothing
    end
    function split_forloop(ex::Expr)
        ex.head === :for || error("expect a for loop expr, got $(ex)")
        lhead = ex.args[1]
        lbody = ex.args[2]
        return (split_for_head(lhead)..., lbody)
    end
    function split_for_head(ex::Expr)
        if ex.head === :block
            (vars, itrs) = ([], [])
            for each = ex.args
                each isa Expr || continue
                (var, itr) = split_single_for_head(each)
                push!(vars, var)
                push!(itrs, itr)
            end
            return (vars, itrs)
        else
            (var, itr) = split_single_for_head(ex)
            return (Any[var], Any[itr])
        end
    end
    function split_single_for_head(ex::Expr)
        ex.head === :(=) || error("expect a single loop head, got $(ex)")
        return (ex.args[1], ex.args[2])
    end
    #= none:202 =# Core.@doc "    uninferrable_typevars(def::Union{JLStruct, JLKwStruct}; leading_inferable::Bool=true)\n\nReturn the type variables that are not inferrable in given struct definition.\n" function uninferrable_typevars(def::Union{JLStruct, JLKwStruct}; leading_inferable::Bool = true)
            typevars = name_only.(def.typevars)
            field_types = [field.type for field = def.fields]
            if leading_inferable
                idx = findfirst(typevars) do t
                        !(any(map((f->begin
                                            has_symbol(f, t)
                                        end), field_types)))
                    end
                idx === nothing && return []
            else
                idx = 0
            end
            uninferrable = typevars[1:idx]
            for T = typevars[idx + 1:end]
                any(map((f->begin
                                    has_symbol(f, T)
                                end), field_types)) || push!(uninferrable, T)
            end
            return uninferrable
        end
    #= none:227 =# Core.@doc "    split_field_if_match(typename::Symbol, expr, default::Bool=false)\n\nSplit the field definition if it matches the given type name.\nReturns `NamedTuple` with `name`, `type`, `default` and `isconst` fields\nif it matches, otherwise return `nothing`.\n" function split_field_if_match(typename::Symbol, expr, default::Bool = false; source = nothing)
            begin
                begin
                    var"##cache#737" = nothing
                end
                var"##736" = expr
                if var"##736" isa Expr
                    if begin
                                if var"##cache#737" === nothing
                                    var"##cache#737" = Some(((var"##736").head, (var"##736").args))
                                end
                                var"##738" = (var"##cache#737").value
                                var"##738" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##738"[1] == :const && (begin
                                        var"##739" = var"##738"[2]
                                        var"##739" isa AbstractArray
                                    end && (length(var"##739") === 1 && (begin
                                                begin
                                                    var"##cache#741" = nothing
                                                end
                                                var"##740" = var"##739"[1]
                                                var"##740" isa Expr
                                            end && (begin
                                                    if var"##cache#741" === nothing
                                                        var"##cache#741" = Some(((var"##740").head, (var"##740").args))
                                                    end
                                                    var"##742" = (var"##cache#741").value
                                                    var"##742" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##742"[1] == :(=) && (begin
                                                            var"##743" = var"##742"[2]
                                                            var"##743" isa AbstractArray
                                                        end && (length(var"##743") === 2 && (begin
                                                                    begin
                                                                        var"##cache#745" = nothing
                                                                    end
                                                                    var"##744" = var"##743"[1]
                                                                    var"##744" isa Expr
                                                                end && (begin
                                                                        if var"##cache#745" === nothing
                                                                            var"##cache#745" = Some(((var"##744").head, (var"##744").args))
                                                                        end
                                                                        var"##746" = (var"##cache#745").value
                                                                        var"##746" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                    end && (var"##746"[1] == :(::) && (begin
                                                                                var"##747" = var"##746"[2]
                                                                                var"##747" isa AbstractArray
                                                                            end && (length(var"##747") === 2 && (begin
                                                                                        var"##748" = var"##747"[1]
                                                                                        var"##748" isa Symbol
                                                                                    end && begin
                                                                                        var"##749" = var"##747"[2]
                                                                                        var"##750" = var"##743"[2]
                                                                                        true
                                                                                    end))))))))))))))
                        value = var"##750"
                        type = var"##749"
                        name = var"##748"
                        var"##return#734" = begin
                                default && return (; name, type, isconst = true, default = value)
                                throw(SyntaxError("default value syntax is not allowed", source))
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                    if begin
                                var"##751" = (var"##cache#737").value
                                var"##751" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##751"[1] == :const && (begin
                                        var"##752" = var"##751"[2]
                                        var"##752" isa AbstractArray
                                    end && (length(var"##752") === 1 && (begin
                                                begin
                                                    var"##cache#754" = nothing
                                                end
                                                var"##753" = var"##752"[1]
                                                var"##753" isa Expr
                                            end && (begin
                                                    if var"##cache#754" === nothing
                                                        var"##cache#754" = Some(((var"##753").head, (var"##753").args))
                                                    end
                                                    var"##755" = (var"##cache#754").value
                                                    var"##755" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##755"[1] == :(=) && (begin
                                                            var"##756" = var"##755"[2]
                                                            var"##756" isa AbstractArray
                                                        end && (length(var"##756") === 2 && (begin
                                                                    var"##757" = var"##756"[1]
                                                                    var"##757" isa Symbol
                                                                end && begin
                                                                    var"##758" = var"##756"[2]
                                                                    true
                                                                end)))))))))
                        value = var"##758"
                        name = var"##757"
                        var"##return#734" = begin
                                default && return (; name, type = Any, isconst = true, default = value)
                                throw(SyntaxError("default value syntax is not allowed", source))
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                    if begin
                                var"##759" = (var"##cache#737").value
                                var"##759" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##759"[1] == :(=) && (begin
                                        var"##760" = var"##759"[2]
                                        var"##760" isa AbstractArray
                                    end && (length(var"##760") === 2 && (begin
                                                begin
                                                    var"##cache#762" = nothing
                                                end
                                                var"##761" = var"##760"[1]
                                                var"##761" isa Expr
                                            end && (begin
                                                    if var"##cache#762" === nothing
                                                        var"##cache#762" = Some(((var"##761").head, (var"##761").args))
                                                    end
                                                    var"##763" = (var"##cache#762").value
                                                    var"##763" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##763"[1] == :(::) && (begin
                                                            var"##764" = var"##763"[2]
                                                            var"##764" isa AbstractArray
                                                        end && (length(var"##764") === 2 && (begin
                                                                    var"##765" = var"##764"[1]
                                                                    var"##765" isa Symbol
                                                                end && begin
                                                                    var"##766" = var"##764"[2]
                                                                    var"##767" = var"##760"[2]
                                                                    true
                                                                end)))))))))
                        value = var"##767"
                        type = var"##766"
                        name = var"##765"
                        var"##return#734" = begin
                                default && return (; name, type, isconst = false, default = value)
                                throw(SyntaxError("default value syntax is not allowed", source))
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                    if begin
                                var"##768" = (var"##cache#737").value
                                var"##768" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##768"[1] == :(=) && (begin
                                        var"##769" = var"##768"[2]
                                        var"##769" isa AbstractArray
                                    end && (length(var"##769") === 2 && (begin
                                                var"##770" = var"##769"[1]
                                                var"##770" isa Symbol
                                            end && begin
                                                var"##771" = var"##769"[2]
                                                true
                                            end))))
                        value = var"##771"
                        name = var"##770"
                        var"##return#734" = begin
                                default && return (; name, type = Any, isconst = false, default = value)
                                throw(SyntaxError("default value syntax is not allowed", source))
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                    if begin
                                var"##772" = (var"##cache#737").value
                                var"##772" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##772"[1] == :const && (begin
                                        var"##773" = var"##772"[2]
                                        var"##773" isa AbstractArray
                                    end && (length(var"##773") === 1 && (begin
                                                begin
                                                    var"##cache#775" = nothing
                                                end
                                                var"##774" = var"##773"[1]
                                                var"##774" isa Expr
                                            end && (begin
                                                    if var"##cache#775" === nothing
                                                        var"##cache#775" = Some(((var"##774").head, (var"##774").args))
                                                    end
                                                    var"##776" = (var"##cache#775").value
                                                    var"##776" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##776"[1] == :(::) && (begin
                                                            var"##777" = var"##776"[2]
                                                            var"##777" isa AbstractArray
                                                        end && (length(var"##777") === 2 && (begin
                                                                    var"##778" = var"##777"[1]
                                                                    var"##778" isa Symbol
                                                                end && begin
                                                                    var"##779" = var"##777"[2]
                                                                    true
                                                                end)))))))))
                        type = var"##779"
                        name = var"##778"
                        var"##return#734" = begin
                                default && return (; name, type, isconst = true, default = no_default)
                                return (; name, type, isconst = true)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                    if begin
                                var"##780" = (var"##cache#737").value
                                var"##780" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##780"[1] == :const && (begin
                                        var"##781" = var"##780"[2]
                                        var"##781" isa AbstractArray
                                    end && (length(var"##781") === 1 && begin
                                            var"##782" = var"##781"[1]
                                            var"##782" isa Symbol
                                        end)))
                        name = var"##782"
                        var"##return#734" = begin
                                default && return (; name, type = Any, isconst = true, default = no_default)
                                return (; name, type = Any, isconst = true)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                    if begin
                                var"##783" = (var"##cache#737").value
                                var"##783" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##783"[1] == :(::) && (begin
                                        var"##784" = var"##783"[2]
                                        var"##784" isa AbstractArray
                                    end && (length(var"##784") === 2 && (begin
                                                var"##785" = var"##784"[1]
                                                var"##785" isa Symbol
                                            end && begin
                                                var"##786" = var"##784"[2]
                                                true
                                            end))))
                        type = var"##786"
                        name = var"##785"
                        var"##return#734" = begin
                                default && return (; name, type, isconst = false, default = no_default)
                                return (; name, type, isconst = false)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                end
                if var"##736" isa Symbol
                    begin
                        name = var"##736"
                        var"##return#734" = begin
                                default && return (; name, type = Any, isconst = false, default = no_default)
                                return (; name, type = Any, isconst = false)
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                end
                if var"##736" isa String
                    begin
                        var"##return#734" = begin
                                return expr
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                end
                if var"##736" isa LineNumberNode
                    begin
                        var"##return#734" = begin
                                return expr
                            end
                        $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                    end
                end
                if is_function(expr)
                    var"##return#734" = begin
                            if name_only(expr) === typename
                                return JLFunction(expr)
                            else
                                return expr
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                end
                begin
                    var"##return#734" = begin
                            return expr
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#735#787")))
                end
                error("matching non-exhaustive, at #= none:235 =#")
                $(Expr(:symboliclabel, Symbol("####final#735#787")))
                var"##return#734"
            end
        end
    function split_signature(call::Expr)
        if Meta.isexpr(call, :where)
            Expr(:where, split_signature(call.args[1]), call.args[2:end]...)
        elseif Meta.isexpr(call, :call)
            :(($Base).Tuple{($Base).typeof($(call.args[1])), $(arg2type.(call.args[2:end])...)})
        elseif Meta.isexpr(call, :(::))
            return split_signature(call.args[1])
        else
            error("invalid signature: $(call)")
        end
    end
    function arg2type(arg)
        let
            begin
                var"##cache#791" = nothing
            end
            var"##return#788" = nothing
            var"##790" = arg
            if var"##790" isa Expr
                if begin
                            if var"##cache#791" === nothing
                                var"##cache#791" = Some(((var"##790").head, (var"##790").args))
                            end
                            var"##792" = (var"##cache#791").value
                            var"##792" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##792"[1] == :(::) && (begin
                                    var"##793" = var"##792"[2]
                                    var"##793" isa AbstractArray
                                end && (length(var"##793") === 1 && begin
                                        var"##794" = var"##793"[1]
                                        true
                                    end)))
                    var"##return#788" = let type = var"##794"
                            type
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#789#811")))
                end
                if begin
                            var"##795" = (var"##cache#791").value
                            var"##795" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##795"[1] == :(::) && (begin
                                    var"##796" = var"##795"[2]
                                    var"##796" isa AbstractArray
                                end && (length(var"##796") === 2 && begin
                                        var"##797" = var"##796"[2]
                                        true
                                    end)))
                    var"##return#788" = let type = var"##797"
                            type
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#789#811")))
                end
                if begin
                            var"##798" = (var"##cache#791").value
                            var"##798" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##798"[1] == :... && (begin
                                    var"##799" = var"##798"[2]
                                    var"##799" isa AbstractArray
                                end && (length(var"##799") === 1 && (begin
                                            begin
                                                var"##cache#801" = nothing
                                            end
                                            var"##800" = var"##799"[1]
                                            var"##800" isa Expr
                                        end && (begin
                                                if var"##cache#801" === nothing
                                                    var"##cache#801" = Some(((var"##800").head, (var"##800").args))
                                                end
                                                var"##802" = (var"##cache#801").value
                                                var"##802" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##802"[1] == :(::) && (begin
                                                        var"##803" = var"##802"[2]
                                                        var"##803" isa AbstractArray
                                                    end && (length(var"##803") === 2 && begin
                                                            var"##804" = var"##803"[2]
                                                            true
                                                        end))))))))
                    var"##return#788" = let type = var"##804"
                            Core._expr(:curly, Core._expr(:., Base, $(Expr(:copyast, :($(QuoteNode(:(:Vararg))))))), type)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#789#811")))
                end
                if begin
                            var"##805" = (var"##cache#791").value
                            var"##805" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##805"[1] == :... && (begin
                                    var"##806" = var"##805"[2]
                                    var"##806" isa AbstractArray
                                end && length(var"##806") === 1))
                    var"##return#788" = let
                            Core._expr(:curly, Core._expr(:., Base, $(Expr(:copyast, :($(QuoteNode(:(:Vararg))))))), Any)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#789#811")))
                end
                if begin
                            var"##807" = (var"##cache#791").value
                            var"##807" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##807"[1] == :kw && (begin
                                    var"##808" = var"##807"[2]
                                    var"##808" isa AbstractArray
                                end && (length(var"##808") === 2 && begin
                                        var"##809" = var"##808"[1]
                                        var"##810" = var"##808"[2]
                                        true
                                    end)))
                    var"##return#788" = let arg = var"##809", value = var"##810"
                            arg2type(arg)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#789#811")))
                end
            end
            if var"##790" isa Symbol
                begin
                    var"##return#788" = let
                            Any
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#789#811")))
                end
            end
            begin
                var"##return#788" = let
                        error("invalid argument type: $(arg)")
                    end
                $(Expr(:symbolicgoto, Symbol("####final#789#811")))
            end
            error("matching non-exhaustive, at #= none:286 =#")
            $(Expr(:symboliclabel, Symbol("####final#789#811")))
            var"##return#788"
        end
    end
