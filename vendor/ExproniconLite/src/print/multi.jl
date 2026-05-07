
    #= none:2 =# Base.@kwdef mutable struct PrinterState
            indent::Int = 0
            level::Int = 0
            no_first_line_indent::Bool = false
            block::Bool = true
            quoted::Bool = false
        end
    function with(f, ps::PrinterState, name::Symbol, new)
        old = getfield(ps, name)
        setfield!(ps, name, new)
        f()
        setfield!(ps, name, old)
        return nothing
    end
    struct Printer{IO_t <: IO}
        io::IO_t
        color::ColorScheme
        line::Bool
        always_begin_end::Bool
        state::PrinterState
    end
    function Printer(io::IO; indent::Int = get(io, :indent, 0), color::ColorScheme = Monokai256(), line::Bool = false, always_begin_end = false, root::Bool = true)
        state = PrinterState(; indent, level = if root
                        0
                    else
                        1
                    end)
        Printer(io, color, line, always_begin_end, state)
    end
    function (p::Printer)(ex)
        c = p.color
        inline = InlinePrinter(p.io, color = c, line = p.line)
        print(xs...) = begin
                Base.print(p.io, xs...)
            end
        println(xs...) = begin
                Base.println(p.io, xs...)
            end
        printstyled(xs...; kw...) = begin
                Base.printstyled(p.io, xs...; kw...)
            end
        keyword(s) = begin
                printstyled(s, color = c.keyword)
            end
        tab() = begin
                print(" " ^ p.state.indent)
            end
        leading_tab() = begin
                p.state.no_first_line_indent || tab()
            end
        function indent(f; size::Int = 4, level::Int = 1)
            with(p.state, :level, p.state.level + level) do 
                with(f, p.state, :indent, p.state.indent + size)
            end
        end
        function print_stmts(stmts; leading_indent::Bool = true)
            first_line = true
            if !(p.line)
                stmts = filter(!is_line_no, stmts)
            end
            for (i, stmt) = enumerate(stmts)
                if !leading_indent && first_line
                    first_line = false
                else
                    tab()
                end
                no_first_line_indent() do 
                    p(stmt)
                end
                if i < length(stmts)
                    println()
                end
            end
        end
        noblock(f) = begin
                with(f, p.state, :block, false)
            end
        quoted(f) = begin
                with(f, p.state, :quoted, true)
            end
        is_root() = begin
                p.state.level == 0
            end
        no_first_line_indent(f) = begin
                with(f, p.state, :no_first_line_indent, true)
            end
        function print_if(cond, body, otherwise = nothing)
            stmts = split_body(body)
            leading_tab()
            keyword("if ")
            inline(cond)
            println()
            indent() do 
                print_stmts(stmts)
            end
            isnothing(otherwise) || print_else(otherwise)
            println()
            tab()
            keyword("end")
        end
        function print_else(otherwise)
            println()
            Meta.isexpr(otherwise, :elseif) && return p(otherwise)
            tab()
            keyword("else")
            println()
            let
                begin
                    var"##cache#1158" = nothing
                end
                var"##return#1155" = nothing
                var"##1157" = otherwise
                if var"##1157" isa Expr && (begin
                                if var"##cache#1158" === nothing
                                    var"##cache#1158" = Some(((var"##1157").head, (var"##1157").args))
                                end
                                var"##1159" = (var"##cache#1158").value
                                var"##1159" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                            end && (var"##1159"[1] == :block && (begin
                                        var"##1160" = var"##1159"[2]
                                        var"##1160" isa AbstractArray
                                    end && ((ndims(var"##1160") === 1 && length(var"##1160") >= 0) && begin
                                            var"##1161" = SubArray(var"##1160", (1:length(var"##1160"),))
                                            true
                                        end))))
                    var"##return#1155" = let stmts = var"##1161"
                            indent() do 
                                print_stmts(stmts)
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1156#1162")))
                end
                begin
                    var"##return#1155" = let
                            indent() do 
                                tab()
                                no_first_line_indent() do 
                                    p(otherwise)
                                end
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1156#1162")))
                end
                error("matching non-exhaustive, at #= none:98 =#")
                $(Expr(:symboliclabel, Symbol("####final#1156#1162")))
                var"##return#1155"
            end
        end
        function print_elseif(cond, body, line = nothing, otherwise = nothing)
            stmts = split_body(body)
            tab()
            keyword("elseif ")
            isnothing(line) || p.line && begin
                        inline(line)
                        print(" ")
                    end
            inline(cond)
            println()
            indent() do 
                print_stmts(stmts)
            end
            isnothing(otherwise) || print_else(otherwise)
        end
        function print_function(head, call, body)
            stmts = split_body(body)
            leading_tab()
            keyword("$(head) ")
            inline(call)
            println()
            indent() do 
                print_stmts(stmts)
            end
            println()
            tab()
            keyword("end")
        end
        function print_try(body)
            body == false && return nothing
            stmts = split_body(body)
            leading_tab()
            keyword("try")
            println()
            indent() do 
                print_stmts(stmts)
            end
        end
        function print_catch(body, vars)
            body == false && return nothing
            stmts = split_body(body)
            println()
            tab()
            keyword("catch")
            if vars != false
                print(" ")
                inline(vars)
            end
            println()
            indent() do 
                print_stmts(stmts)
            end
        end
        function print_finally(body)
            body == false && return nothing
            stmts = split_body(body)
            println()
            tab()
            keyword("finally")
            println()
            indent() do 
                print_stmts(stmts)
            end
        end
        function print_macrocall(name, line, args)
            leading_tab()
            p.line && begin
                    inline(line)
                    print(" ")
                end
            with(inline.state, :macrocall, true) do 
                inline(name)
            end
            p.state.level += 1
            foreach(args) do arg
                print(" ")
                p(arg)
            end
        end
        function print_switch(item, line, stmts)
            leading_tab()
            p.line && begin
                    inline(line)
                    print(" ")
                end
            any(stmts) do stmt
                    let
                        begin
                            var"##cache#1166" = nothing
                        end
                        var"##return#1163" = nothing
                        var"##1165" = stmt
                        if var"##1165" isa Expr && (begin
                                        if var"##cache#1166" === nothing
                                            var"##cache#1166" = Some(((var"##1165").head, (var"##1165").args))
                                        end
                                        var"##1167" = (var"##cache#1166").value
                                        var"##1167" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                    end && (var"##1167"[1] == :macrocall && (begin
                                                var"##1168" = var"##1167"[2]
                                                var"##1168" isa AbstractArray
                                            end && ((ndims(var"##1168") === 1 && length(var"##1168") >= 1) && begin
                                                    var"##1169" = var"##1168"[1]
                                                    var"##1169" == Symbol("@case")
                                                end))))
                            var"##return#1163" = let
                                    true
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#1164#1170")))
                        end
                        begin
                            var"##return#1163" = let
                                    false
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#1164#1170")))
                        end
                        error("matching non-exhaustive, at #= none:181 =#")
                        $(Expr(:symboliclabel, Symbol("####final#1164#1170")))
                        var"##return#1163"
                    end
                end || return print_macrocall("@switch", line, (item, Expr(:block, stmts...)))
            is_case(stmt) = begin
                    let
                        begin
                            var"##cache#1174" = nothing
                        end
                        var"##return#1171" = nothing
                        var"##1173" = stmt
                        if var"##1173" isa Expr && (begin
                                        if var"##cache#1174" === nothing
                                            var"##cache#1174" = Some(((var"##1173").head, (var"##1173").args))
                                        end
                                        var"##1175" = (var"##cache#1174").value
                                        var"##1175" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                    end && (var"##1175"[1] == :macrocall && (begin
                                                var"##1176" = var"##1175"[2]
                                                var"##1176" isa AbstractArray
                                            end && ((ndims(var"##1176") === 1 && length(var"##1176") >= 1) && begin
                                                    var"##1177" = var"##1176"[1]
                                                    var"##1177" == Symbol("@case")
                                                end))))
                            var"##return#1171" = let
                                    true
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#1172#1178")))
                        end
                        begin
                            var"##return#1171" = let
                                    false
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#1172#1178")))
                        end
                        error("matching non-exhaustive, at #= none:187 =#")
                        $(Expr(:symboliclabel, Symbol("####final#1172#1178")))
                        var"##return#1171"
                    end
                end
            keyword("@switch ")
            p(item)
            keyword(" begin")
            println()
            indent() do 
                ptr = 1
                while ptr <= length(stmts)
                    stmt = stmts[ptr]
                    let
                        begin
                            var"##cache#1182" = nothing
                        end
                        var"##return#1179" = nothing
                        var"##1181" = stmt
                        if var"##1181" isa Expr && (begin
                                        if var"##cache#1182" === nothing
                                            var"##cache#1182" = Some(((var"##1181").head, (var"##1181").args))
                                        end
                                        var"##1183" = (var"##cache#1182").value
                                        var"##1183" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                    end && (var"##1183"[1] == :macrocall && (begin
                                                var"##1184" = var"##1183"[2]
                                                var"##1184" isa AbstractArray
                                            end && (length(var"##1184") === 3 && (begin
                                                        var"##1185" = var"##1184"[1]
                                                        var"##1185" == Symbol("@case")
                                                    end && begin
                                                        var"##1186" = var"##1184"[2]
                                                        var"##1187" = var"##1184"[3]
                                                        true
                                                    end)))))
                            var"##return#1179" = let pattern = var"##1187", line = var"##1186"
                                    tab()
                                    keyword("@case ")
                                    inline(pattern)
                                    println()
                                    case_ptr = ptr + 1
                                    case_ptr <= length(stmts) || continue
                                    case_stmt = stmts[case_ptr]
                                    indent() do 
                                        while case_ptr <= length(stmts)
                                            case_stmt = stmts[case_ptr]
                                            if is_case(case_stmt)
                                                case_ptr -= 1
                                                break
                                            end
                                            tab()
                                            no_first_line_indent() do 
                                                p(case_stmt)
                                            end
                                            println()
                                            case_ptr += 1
                                        end
                                    end
                                    ptr = case_ptr
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#1180#1188")))
                        end
                        begin
                            var"##return#1179" = let
                                    p(stmt)
                                    println()
                                end
                            $(Expr(:symbolicgoto, Symbol("####final#1180#1188")))
                        end
                        error("matching non-exhaustive, at #= none:197 =#")
                        $(Expr(:symboliclabel, Symbol("####final#1180#1188")))
                        var"##return#1179"
                    end
                    ptr += 1
                end
            end
            println()
            tab()
            keyword("end")
        end
        function print_multi_lines(s::AbstractString)
            buf = IOBuffer(s)
            line_buf = IOBuffer()
            while !(eof(buf))
                ch = read(buf, Char)
                if ch == '\n'
                    printstyled(String(take!(line_buf)), color = c.string)
                    println()
                    tab()
                else
                    ch in ('$',) && write(line_buf, '\\')
                    write(line_buf, ch)
                end
            end
            last_line = String(take!(line_buf))
            isempty(last_line) || printstyled(last_line, color = c.string)
        end
        begin
            begin
                var"##cache#1192" = nothing
            end
            var"##1191" = ex
            if var"##1191" isa Expr
                if begin
                            if var"##cache#1192" === nothing
                                var"##cache#1192" = Some(((var"##1191").head, (var"##1191").args))
                            end
                            var"##1193" = (var"##cache#1192").value
                            var"##1193" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1193"[1] == :string && (begin
                                    var"##1194" = var"##1193"[2]
                                    var"##1194" isa AbstractArray
                                end && ((ndims(var"##1194") === 1 && length(var"##1194") >= 0) && begin
                                        var"##1195" = SubArray(var"##1194", (1:length(var"##1194"),))
                                        true
                                    end)))
                    args = var"##1195"
                    var"##return#1189" = begin
                            leading_tab()
                            any((arg->begin
                                            arg isa AbstractString && occursin('\n', arg)
                                        end), args) || return inline(ex)
                            printstyled("\"\"\"\n", color = c.string)
                            tab()
                            for arg = args
                                if arg isa AbstractString
                                    print_multi_lines(arg)
                                elseif arg isa Symbol
                                    keyword("\$")
                                    inline(arg)
                                else
                                    keyword("\$")
                                    print("(")
                                    inline(arg)
                                    print(")")
                                end
                            end
                            printstyled("\"\"\"", color = c.string)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1196" = (var"##cache#1192").value
                            var"##1196" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1196"[1] == :block && (begin
                                    var"##1197" = var"##1196"[2]
                                    var"##1197" isa AbstractArray
                                end && ((ndims(var"##1197") === 1 && length(var"##1197") >= 0) && begin
                                        var"##1198" = SubArray(var"##1197", (1:length(var"##1197"),))
                                        true
                                    end)))
                    stmts = var"##1198"
                    var"##return#1189" = begin
                            leading_tab()
                            show_begin_end = if p.always_begin_end
                                    true
                                else
                                    !(is_root())
                                end
                            if show_begin_end
                                if p.state.quoted
                                    keyword("quote")
                                else
                                    keyword("begin")
                                end
                                println()
                            end
                            indent(size = if show_begin_end
                                        4
                                    else
                                        0
                                    end, level = 0) do 
                                print_stmts(stmts; leading_indent = show_begin_end)
                            end
                            show_begin_end && begin
                                    println()
                                    tab()
                                    keyword("end")
                                end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1199" = (var"##cache#1192").value
                            var"##1199" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1199"[1] == :quote && (begin
                                    var"##1200" = var"##1199"[2]
                                    var"##1200" isa AbstractArray
                                end && (length(var"##1200") === 1 && (begin
                                            begin
                                                var"##cache#1202" = nothing
                                            end
                                            var"##1201" = var"##1200"[1]
                                            var"##1201" isa Expr
                                        end && (begin
                                                if var"##cache#1202" === nothing
                                                    var"##cache#1202" = Some(((var"##1201").head, (var"##1201").args))
                                                end
                                                var"##1203" = (var"##cache#1202").value
                                                var"##1203" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1203"[1] == :block && (begin
                                                        var"##1204" = var"##1203"[2]
                                                        var"##1204" isa AbstractArray
                                                    end && ((ndims(var"##1204") === 1 && length(var"##1204") >= 0) && begin
                                                            var"##1205" = SubArray(var"##1204", (1:length(var"##1204"),))
                                                            let stmts = var"##1205"
                                                                is_root()
                                                            end
                                                        end))))))))
                    stmts = var"##1205"
                    var"##return#1189" = begin
                            leading_tab()
                            keyword("quote")
                            println()
                            indent(size = 4) do 
                                print_stmts(stmts)
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1206" = (var"##cache#1192").value
                            var"##1206" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1206"[1] == :quote && (begin
                                    var"##1207" = var"##1206"[2]
                                    var"##1207" isa AbstractArray
                                end && (length(var"##1207") === 1 && (begin
                                            begin
                                                var"##cache#1209" = nothing
                                            end
                                            var"##1208" = var"##1207"[1]
                                            var"##1208" isa Expr
                                        end && (begin
                                                if var"##cache#1209" === nothing
                                                    var"##cache#1209" = Some(((var"##1208").head, (var"##1208").args))
                                                end
                                                var"##1210" = (var"##cache#1209").value
                                                var"##1210" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1210"[1] == :block && (begin
                                                        var"##1211" = var"##1210"[2]
                                                        var"##1211" isa AbstractArray
                                                    end && ((ndims(var"##1211") === 1 && length(var"##1211") >= 0) && begin
                                                            var"##1212" = SubArray(var"##1211", (1:length(var"##1211"),))
                                                            true
                                                        end))))))))
                    stmts = var"##1212"
                    var"##return#1189" = begin
                            leading_tab()
                            keyword("quote")
                            println()
                            indent(size = if p.state.quoted
                                        4
                                    else
                                        0
                                    end) do 
                                p.state.quoted && begin
                                        tab()
                                        keyword("quote")
                                        println()
                                    end
                                indent() do 
                                    quoted() do 
                                        print_stmts(stmts; leading_indent = !(is_root()))
                                    end
                                end
                                p.state.quoted && begin
                                        println()
                                        tab()
                                        keyword("end")
                                    end
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1213" = (var"##cache#1192").value
                            var"##1213" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1213"[1] == :quote && (begin
                                    var"##1214" = var"##1213"[2]
                                    var"##1214" isa AbstractArray
                                end && (length(var"##1214") === 1 && begin
                                        var"##1215" = var"##1214"[1]
                                        true
                                    end)))
                    code = var"##1215"
                    var"##return#1189" = begin
                            is_root() || begin
                                    leading_tab()
                                    keyword("quote")
                                    println()
                                end
                            indent(size = if is_root()
                                        0
                                    else
                                        4
                                    end) do 
                                quoted() do 
                                    tab()
                                    no_first_line_indent() do 
                                        p(code)
                                    end
                                end
                            end
                            is_root() || begin
                                    println()
                                    tab()
                                    keyword("end")
                                end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1216" = (var"##cache#1192").value
                            var"##1216" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1216"[1] == :let && (begin
                                    var"##1217" = var"##1216"[2]
                                    var"##1217" isa AbstractArray
                                end && (length(var"##1217") === 2 && (begin
                                            begin
                                                var"##cache#1219" = nothing
                                            end
                                            var"##1218" = var"##1217"[1]
                                            var"##1218" isa Expr
                                        end && (begin
                                                if var"##cache#1219" === nothing
                                                    var"##cache#1219" = Some(((var"##1218").head, (var"##1218").args))
                                                end
                                                var"##1220" = (var"##cache#1219").value
                                                var"##1220" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1220"[1] == :block && (begin
                                                        var"##1221" = var"##1220"[2]
                                                        var"##1221" isa AbstractArray
                                                    end && ((ndims(var"##1221") === 1 && length(var"##1221") >= 0) && (begin
                                                                var"##1222" = SubArray(var"##1221", (1:length(var"##1221"),))
                                                                begin
                                                                    var"##cache#1224" = nothing
                                                                end
                                                                var"##1223" = var"##1217"[2]
                                                                var"##1223" isa Expr
                                                            end && (begin
                                                                    if var"##cache#1224" === nothing
                                                                        var"##cache#1224" = Some(((var"##1223").head, (var"##1223").args))
                                                                    end
                                                                    var"##1225" = (var"##cache#1224").value
                                                                    var"##1225" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##1225"[1] == :block && (begin
                                                                            var"##1226" = var"##1225"[2]
                                                                            var"##1226" isa AbstractArray
                                                                        end && ((ndims(var"##1226") === 1 && length(var"##1226") >= 0) && begin
                                                                                var"##1227" = SubArray(var"##1226", (1:length(var"##1226"),))
                                                                                true
                                                                            end)))))))))))))
                    args = var"##1222"
                    stmts = var"##1227"
                    var"##return#1189" = begin
                            leading_tab()
                            keyword("let ")
                            isempty(args) || inline(args...)
                            println()
                            indent() do 
                                print_stmts(stmts)
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1228" = (var"##cache#1192").value
                            var"##1228" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1228"[1] == :if && (begin
                                    var"##1229" = var"##1228"[2]
                                    var"##1229" isa AbstractArray
                                end && (length(var"##1229") === 2 && begin
                                        var"##1230" = var"##1229"[1]
                                        var"##1231" = var"##1229"[2]
                                        true
                                    end)))
                    cond = var"##1230"
                    body = var"##1231"
                    var"##return#1189" = begin
                            print_if(cond, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1232" = (var"##cache#1192").value
                            var"##1232" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1232"[1] == :if && (begin
                                    var"##1233" = var"##1232"[2]
                                    var"##1233" isa AbstractArray
                                end && (length(var"##1233") === 3 && begin
                                        var"##1234" = var"##1233"[1]
                                        var"##1235" = var"##1233"[2]
                                        var"##1236" = var"##1233"[3]
                                        true
                                    end)))
                    cond = var"##1234"
                    body = var"##1235"
                    otherwise = var"##1236"
                    var"##return#1189" = begin
                            print_if(cond, body, otherwise)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1237" = (var"##cache#1192").value
                            var"##1237" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1237"[1] == :elseif && (begin
                                    var"##1238" = var"##1237"[2]
                                    var"##1238" isa AbstractArray
                                end && (length(var"##1238") === 2 && (begin
                                            begin
                                                var"##cache#1240" = nothing
                                            end
                                            var"##1239" = var"##1238"[1]
                                            var"##1239" isa Expr
                                        end && (begin
                                                if var"##cache#1240" === nothing
                                                    var"##cache#1240" = Some(((var"##1239").head, (var"##1239").args))
                                                end
                                                var"##1241" = (var"##cache#1240").value
                                                var"##1241" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1241"[1] == :block && (begin
                                                        var"##1242" = var"##1241"[2]
                                                        var"##1242" isa AbstractArray
                                                    end && (length(var"##1242") === 2 && begin
                                                            var"##1243" = var"##1242"[1]
                                                            var"##1244" = var"##1242"[2]
                                                            var"##1245" = var"##1238"[2]
                                                            true
                                                        end))))))))
                    line = var"##1243"
                    cond = var"##1244"
                    body = var"##1245"
                    var"##return#1189" = begin
                            print_elseif(cond, body, line)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1246" = (var"##cache#1192").value
                            var"##1246" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1246"[1] == :elseif && (begin
                                    var"##1247" = var"##1246"[2]
                                    var"##1247" isa AbstractArray
                                end && (length(var"##1247") === 2 && begin
                                        var"##1248" = var"##1247"[1]
                                        var"##1249" = var"##1247"[2]
                                        true
                                    end)))
                    cond = var"##1248"
                    body = var"##1249"
                    var"##return#1189" = begin
                            print_elseif(cond, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1250" = (var"##cache#1192").value
                            var"##1250" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1250"[1] == :elseif && (begin
                                    var"##1251" = var"##1250"[2]
                                    var"##1251" isa AbstractArray
                                end && (length(var"##1251") === 3 && (begin
                                            begin
                                                var"##cache#1253" = nothing
                                            end
                                            var"##1252" = var"##1251"[1]
                                            var"##1252" isa Expr
                                        end && (begin
                                                if var"##cache#1253" === nothing
                                                    var"##cache#1253" = Some(((var"##1252").head, (var"##1252").args))
                                                end
                                                var"##1254" = (var"##cache#1253").value
                                                var"##1254" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1254"[1] == :block && (begin
                                                        var"##1255" = var"##1254"[2]
                                                        var"##1255" isa AbstractArray
                                                    end && (length(var"##1255") === 2 && begin
                                                            var"##1256" = var"##1255"[1]
                                                            var"##1257" = var"##1255"[2]
                                                            var"##1258" = var"##1251"[2]
                                                            var"##1259" = var"##1251"[3]
                                                            true
                                                        end))))))))
                    line = var"##1256"
                    cond = var"##1257"
                    body = var"##1258"
                    otherwise = var"##1259"
                    var"##return#1189" = begin
                            print_elseif(cond, body, line, otherwise)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1260" = (var"##cache#1192").value
                            var"##1260" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1260"[1] == :elseif && (begin
                                    var"##1261" = var"##1260"[2]
                                    var"##1261" isa AbstractArray
                                end && (length(var"##1261") === 3 && begin
                                        var"##1262" = var"##1261"[1]
                                        var"##1263" = var"##1261"[2]
                                        var"##1264" = var"##1261"[3]
                                        true
                                    end)))
                    cond = var"##1262"
                    body = var"##1263"
                    otherwise = var"##1264"
                    var"##return#1189" = begin
                            print_elseif(cond, body, nothing, otherwise)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1265" = (var"##cache#1192").value
                            var"##1265" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1265"[1] == :for && (begin
                                    var"##1266" = var"##1265"[2]
                                    var"##1266" isa AbstractArray
                                end && (length(var"##1266") === 2 && begin
                                        var"##1267" = var"##1266"[1]
                                        var"##1268" = var"##1266"[2]
                                        true
                                    end)))
                    body = var"##1268"
                    iteration = var"##1267"
                    var"##return#1189" = begin
                            leading_tab()
                            inline.state.loop_iterator = true
                            preced = inline.state.precedence
                            inline.state.precedence = 0
                            keyword("for ")
                            inline(split_body(iteration)...)
                            println()
                            inline.state.loop_iterator = false
                            inline.state.precedence = preced
                            stmts = split_body(body)
                            indent() do 
                                print_stmts(stmts)
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1269" = (var"##cache#1192").value
                            var"##1269" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1269"[1] == :while && (begin
                                    var"##1270" = var"##1269"[2]
                                    var"##1270" isa AbstractArray
                                end && (length(var"##1270") === 2 && begin
                                        var"##1271" = var"##1270"[1]
                                        var"##1272" = var"##1270"[2]
                                        true
                                    end)))
                    cond = var"##1271"
                    body = var"##1272"
                    var"##return#1189" = begin
                            leading_tab()
                            keyword("while ")
                            inline(cond)
                            println()
                            stmts = split_body(body)
                            indent() do 
                                print_stmts(stmts)
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1273" = (var"##cache#1192").value
                            var"##1273" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1273"[1] == :(=) && (begin
                                    var"##1274" = var"##1273"[2]
                                    var"##1274" isa AbstractArray
                                end && (length(var"##1274") === 2 && (begin
                                            var"##1275" = var"##1274"[1]
                                            begin
                                                var"##cache#1277" = nothing
                                            end
                                            var"##1276" = var"##1274"[2]
                                            var"##1276" isa Expr
                                        end && (begin
                                                if var"##cache#1277" === nothing
                                                    var"##cache#1277" = Some(((var"##1276").head, (var"##1276").args))
                                                end
                                                var"##1278" = (var"##cache#1277").value
                                                var"##1278" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1278"[1] == :block && (begin
                                                        var"##1279" = var"##1278"[2]
                                                        var"##1279" isa AbstractArray
                                                    end && (length(var"##1279") === 2 && (begin
                                                                var"##1280" = var"##1279"[1]
                                                                begin
                                                                    var"##cache#1282" = nothing
                                                                end
                                                                var"##1281" = var"##1279"[2]
                                                                var"##1281" isa Expr
                                                            end && (begin
                                                                    if var"##cache#1282" === nothing
                                                                        var"##cache#1282" = Some(((var"##1281").head, (var"##1281").args))
                                                                    end
                                                                    var"##1283" = (var"##cache#1282").value
                                                                    var"##1283" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##1283"[1] == :if && (begin
                                                                            var"##1284" = var"##1283"[2]
                                                                            var"##1284" isa AbstractArray
                                                                        end && ((ndims(var"##1284") === 1 && length(var"##1284") >= 0) && let line = var"##1280", lhs = var"##1275"
                                                                                is_line_no(line)
                                                                            end)))))))))))))
                    line = var"##1280"
                    lhs = var"##1275"
                    var"##return#1189" = begin
                            leading_tab()
                            inline(lhs)
                            keyword(" = ")
                            inline(line)
                            p(ex.args[2])
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1285" = (var"##cache#1192").value
                            var"##1285" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1285"[1] == :(=) && (begin
                                    var"##1286" = var"##1285"[2]
                                    var"##1286" isa AbstractArray
                                end && (length(var"##1286") === 2 && (begin
                                            var"##1287" = var"##1286"[1]
                                            begin
                                                var"##cache#1289" = nothing
                                            end
                                            var"##1288" = var"##1286"[2]
                                            var"##1288" isa Expr
                                        end && (begin
                                                if var"##cache#1289" === nothing
                                                    var"##cache#1289" = Some(((var"##1288").head, (var"##1288").args))
                                                end
                                                var"##1290" = (var"##cache#1289").value
                                                var"##1290" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1290"[1] == :block && (begin
                                                        var"##1291" = var"##1290"[2]
                                                        var"##1291" isa AbstractArray
                                                    end && (length(var"##1291") === 2 && begin
                                                            var"##1292" = var"##1291"[1]
                                                            var"##1293" = var"##1291"[2]
                                                            let rhs = var"##1293", line = var"##1292", lhs = var"##1287"
                                                                is_line_no(line)
                                                            end
                                                        end))))))))
                    rhs = var"##1293"
                    line = var"##1292"
                    lhs = var"##1287"
                    var"##return#1189" = begin
                            leading_tab()
                            inline(ex)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1294" = (var"##cache#1192").value
                            var"##1294" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1294"[1] == :(=) && (begin
                                    var"##1295" = var"##1294"[2]
                                    var"##1295" isa AbstractArray
                                end && (length(var"##1295") === 2 && begin
                                        var"##1296" = var"##1295"[1]
                                        var"##1297" = var"##1295"[2]
                                        true
                                    end)))
                    rhs = var"##1297"
                    lhs = var"##1296"
                    var"##return#1189" = begin
                            leading_tab()
                            inline(lhs)
                            print(" = ")
                            p(rhs)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1298" = (var"##cache#1192").value
                            var"##1298" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1298"[1] == :function && (begin
                                    var"##1299" = var"##1298"[2]
                                    var"##1299" isa AbstractArray
                                end && (length(var"##1299") === 2 && begin
                                        var"##1300" = var"##1299"[1]
                                        var"##1301" = var"##1299"[2]
                                        true
                                    end)))
                    call = var"##1300"
                    body = var"##1301"
                    var"##return#1189" = begin
                            print_function(:function, call, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1302" = (var"##cache#1192").value
                            var"##1302" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1302"[1] == :-> && (begin
                                    var"##1303" = var"##1302"[2]
                                    var"##1303" isa AbstractArray
                                end && (length(var"##1303") === 2 && begin
                                        var"##1304" = var"##1303"[1]
                                        var"##1305" = var"##1303"[2]
                                        true
                                    end)))
                    call = var"##1304"
                    body = var"##1305"
                    var"##return#1189" = begin
                            leading_tab()
                            inline(call)
                            keyword(" -> ")
                            p(body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1306" = (var"##cache#1192").value
                            var"##1306" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1306"[1] == :do && (begin
                                    var"##1307" = var"##1306"[2]
                                    var"##1307" isa AbstractArray
                                end && (length(var"##1307") === 2 && (begin
                                            var"##1308" = var"##1307"[1]
                                            begin
                                                var"##cache#1310" = nothing
                                            end
                                            var"##1309" = var"##1307"[2]
                                            var"##1309" isa Expr
                                        end && (begin
                                                if var"##cache#1310" === nothing
                                                    var"##cache#1310" = Some(((var"##1309").head, (var"##1309").args))
                                                end
                                                var"##1311" = (var"##cache#1310").value
                                                var"##1311" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1311"[1] == :-> && (begin
                                                        var"##1312" = var"##1311"[2]
                                                        var"##1312" isa AbstractArray
                                                    end && (length(var"##1312") === 2 && (begin
                                                                begin
                                                                    var"##cache#1314" = nothing
                                                                end
                                                                var"##1313" = var"##1312"[1]
                                                                var"##1313" isa Expr
                                                            end && (begin
                                                                    if var"##cache#1314" === nothing
                                                                        var"##cache#1314" = Some(((var"##1313").head, (var"##1313").args))
                                                                    end
                                                                    var"##1315" = (var"##cache#1314").value
                                                                    var"##1315" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##1315"[1] == :tuple && (begin
                                                                            var"##1316" = var"##1315"[2]
                                                                            var"##1316" isa AbstractArray
                                                                        end && ((ndims(var"##1316") === 1 && length(var"##1316") >= 0) && begin
                                                                                var"##1317" = SubArray(var"##1316", (1:length(var"##1316"),))
                                                                                var"##1318" = var"##1312"[2]
                                                                                true
                                                                            end)))))))))))))
                    call = var"##1308"
                    args = var"##1317"
                    body = var"##1318"
                    var"##return#1189" = begin
                            leading_tab()
                            inline(call)
                            keyword(" do ")
                            isempty(args) || inline(args...)
                            println()
                            stmts = split_body(body)
                            indent() do 
                                print_stmts(stmts)
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1319" = (var"##cache#1192").value
                            var"##1319" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1319"[1] == :macro && (begin
                                    var"##1320" = var"##1319"[2]
                                    var"##1320" isa AbstractArray
                                end && (length(var"##1320") === 2 && begin
                                        var"##1321" = var"##1320"[1]
                                        var"##1322" = var"##1320"[2]
                                        true
                                    end)))
                    call = var"##1321"
                    body = var"##1322"
                    var"##return#1189" = begin
                            print_function(:macro, call, body)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1323" = (var"##cache#1192").value
                            var"##1323" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1323"[1] == :macrocall && (begin
                                    var"##1324" = var"##1323"[2]
                                    var"##1324" isa AbstractArray
                                end && (length(var"##1324") === 4 && (begin
                                            var"##1325" = var"##1324"[1]
                                            var"##1325" == Symbol("@switch")
                                        end && (begin
                                                var"##1326" = var"##1324"[2]
                                                var"##1327" = var"##1324"[3]
                                                begin
                                                    var"##cache#1329" = nothing
                                                end
                                                var"##1328" = var"##1324"[4]
                                                var"##1328" isa Expr
                                            end && (begin
                                                    if var"##cache#1329" === nothing
                                                        var"##cache#1329" = Some(((var"##1328").head, (var"##1328").args))
                                                    end
                                                    var"##1330" = (var"##cache#1329").value
                                                    var"##1330" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                end && (var"##1330"[1] == :block && (begin
                                                            var"##1331" = var"##1330"[2]
                                                            var"##1331" isa AbstractArray
                                                        end && ((ndims(var"##1331") === 1 && length(var"##1331") >= 0) && begin
                                                                var"##1332" = SubArray(var"##1331", (1:length(var"##1331"),))
                                                                true
                                                            end)))))))))
                    item = var"##1327"
                    line = var"##1326"
                    stmts = var"##1332"
                    var"##return#1189" = begin
                            print_switch(item, line, stmts)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1333" = (var"##cache#1192").value
                            var"##1333" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1333"[1] == :macrocall && (begin
                                    var"##1334" = var"##1333"[2]
                                    var"##1334" isa AbstractArray
                                end && (length(var"##1334") === 4 && (begin
                                            var"##1335" = var"##1334"[1]
                                            var"##1335" == GlobalRef(Core, Symbol("@doc"))
                                        end && begin
                                            var"##1336" = var"##1334"[2]
                                            var"##1337" = var"##1334"[3]
                                            var"##1338" = var"##1334"[4]
                                            true
                                        end))))
                    line = var"##1336"
                    code = var"##1338"
                    doc = var"##1337"
                    var"##return#1189" = begin
                            leading_tab()
                            p.line && begin
                                    inline(line)
                                    println()
                                end
                            no_first_line_indent() do 
                                p(doc)
                            end
                            println()
                            tab()
                            no_first_line_indent() do 
                                p(code)
                            end
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1339" = (var"##cache#1192").value
                            var"##1339" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1339"[1] == :macrocall && (begin
                                    var"##1340" = var"##1339"[2]
                                    var"##1340" isa AbstractArray
                                end && ((ndims(var"##1340") === 1 && length(var"##1340") >= 2) && begin
                                        var"##1341" = var"##1340"[1]
                                        var"##1342" = var"##1340"[2]
                                        var"##1343" = SubArray(var"##1340", (3:length(var"##1340"),))
                                        true
                                    end)))
                    line = var"##1342"
                    name = var"##1341"
                    args = var"##1343"
                    var"##return#1189" = begin
                            print_macrocall(name, line, args)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1344" = (var"##cache#1192").value
                            var"##1344" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1344"[1] == :struct && (begin
                                    var"##1345" = var"##1344"[2]
                                    var"##1345" isa AbstractArray
                                end && (length(var"##1345") === 3 && begin
                                        var"##1346" = var"##1345"[1]
                                        var"##1347" = var"##1345"[2]
                                        var"##1348" = var"##1345"[3]
                                        true
                                    end)))
                    ismutable = var"##1346"
                    body = var"##1348"
                    head = var"##1347"
                    var"##return#1189" = begin
                            stmts = split_body(body)
                            leading_tab()
                            keyword(if ismutable
                                    "mutable struct"
                                else
                                    "struct"
                                end)
                            print(" ")
                            inline(head)
                            println()
                            indent(level = 0) do 
                                print_stmts(stmts)
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1349" = (var"##cache#1192").value
                            var"##1349" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1349"[1] == :try && (begin
                                    var"##1350" = var"##1349"[2]
                                    var"##1350" isa AbstractArray
                                end && (length(var"##1350") === 3 && begin
                                        var"##1351" = var"##1350"[1]
                                        var"##1352" = var"##1350"[2]
                                        var"##1353" = var"##1350"[3]
                                        true
                                    end)))
                    catch_vars = var"##1352"
                    catch_body = var"##1353"
                    try_body = var"##1351"
                    var"##return#1189" = begin
                            print_try(try_body)
                            print_catch(catch_body, catch_vars)
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1354" = (var"##cache#1192").value
                            var"##1354" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1354"[1] == :try && (begin
                                    var"##1355" = var"##1354"[2]
                                    var"##1355" isa AbstractArray
                                end && (length(var"##1355") === 4 && begin
                                        var"##1356" = var"##1355"[1]
                                        var"##1357" = var"##1355"[2]
                                        var"##1358" = var"##1355"[3]
                                        var"##1359" = var"##1355"[4]
                                        true
                                    end)))
                    catch_vars = var"##1357"
                    catch_body = var"##1358"
                    try_body = var"##1356"
                    finally_body = var"##1359"
                    var"##return#1189" = begin
                            print_try(try_body)
                            print_catch(catch_body, catch_vars)
                            print_finally(finally_body)
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1360" = (var"##cache#1192").value
                            var"##1360" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1360"[1] == :try && (begin
                                    var"##1361" = var"##1360"[2]
                                    var"##1361" isa AbstractArray
                                end && (length(var"##1361") === 5 && begin
                                        var"##1362" = var"##1361"[1]
                                        var"##1363" = var"##1361"[2]
                                        var"##1364" = var"##1361"[3]
                                        var"##1365" = var"##1361"[4]
                                        var"##1366" = var"##1361"[5]
                                        true
                                    end)))
                    catch_vars = var"##1363"
                    catch_body = var"##1364"
                    try_body = var"##1362"
                    finally_body = var"##1365"
                    else_body = var"##1366"
                    var"##return#1189" = begin
                            print_try(try_body)
                            print_catch(catch_body, catch_vars)
                            stmts = split_body(else_body)
                            println()
                            tab()
                            keyword("else")
                            println()
                            indent() do 
                                print_stmts(stmts)
                            end
                            print_finally(finally_body)
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1367" = (var"##cache#1192").value
                            var"##1367" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1367"[1] == :module && (begin
                                    var"##1368" = var"##1367"[2]
                                    var"##1368" isa AbstractArray
                                end && (length(var"##1368") === 3 && begin
                                        var"##1369" = var"##1368"[1]
                                        var"##1370" = var"##1368"[2]
                                        var"##1371" = var"##1368"[3]
                                        true
                                    end)))
                    name = var"##1370"
                    body = var"##1371"
                    notbare = var"##1369"
                    var"##return#1189" = begin
                            leading_tab()
                            keyword(if notbare
                                    "module "
                                else
                                    "baremodule "
                                end)
                            inline(name)
                            println()
                            stmts = split_body(body)
                            indent() do 
                                print_stmts(stmts)
                            end
                            println()
                            tab()
                            keyword("end")
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1372" = (var"##cache#1192").value
                            var"##1372" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1372"[1] == :const && (begin
                                    var"##1373" = var"##1372"[2]
                                    var"##1373" isa AbstractArray
                                end && (length(var"##1373") === 1 && begin
                                        var"##1374" = var"##1373"[1]
                                        true
                                    end)))
                    code = var"##1374"
                    var"##return#1189" = begin
                            leading_tab()
                            keyword("const ")
                            p(code)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1375" = (var"##cache#1192").value
                            var"##1375" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1375"[1] == :return && (begin
                                    var"##1376" = var"##1375"[2]
                                    var"##1376" isa AbstractArray
                                end && (length(var"##1376") === 1 && (begin
                                            begin
                                                var"##cache#1378" = nothing
                                            end
                                            var"##1377" = var"##1376"[1]
                                            var"##1377" isa Expr
                                        end && (begin
                                                if var"##cache#1378" === nothing
                                                    var"##cache#1378" = Some(((var"##1377").head, (var"##1377").args))
                                                end
                                                var"##1379" = (var"##cache#1378").value
                                                var"##1379" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1379"[1] == :tuple && (begin
                                                        var"##1380" = var"##1379"[2]
                                                        var"##1380" isa AbstractArray
                                                    end && ((ndims(var"##1380") === 1 && length(var"##1380") >= 1) && (begin
                                                                begin
                                                                    var"##cache#1382" = nothing
                                                                end
                                                                var"##1381" = var"##1380"[1]
                                                                var"##1381" isa Expr
                                                            end && (begin
                                                                    if var"##cache#1382" === nothing
                                                                        var"##cache#1382" = Some(((var"##1381").head, (var"##1381").args))
                                                                    end
                                                                    var"##1383" = (var"##cache#1382").value
                                                                    var"##1383" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                                                end && (var"##1383"[1] == :parameters && (begin
                                                                            var"##1384" = var"##1383"[2]
                                                                            var"##1384" isa AbstractArray
                                                                        end && (ndims(var"##1384") === 1 && length(var"##1384") >= 0)))))))))))))
                    var"##return#1189" = begin
                            inline(ex)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1385" = (var"##cache#1192").value
                            var"##1385" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1385"[1] == :return && (begin
                                    var"##1386" = var"##1385"[2]
                                    var"##1386" isa AbstractArray
                                end && (length(var"##1386") === 1 && (begin
                                            begin
                                                var"##cache#1388" = nothing
                                            end
                                            var"##1387" = var"##1386"[1]
                                            var"##1387" isa Expr
                                        end && (begin
                                                if var"##cache#1388" === nothing
                                                    var"##cache#1388" = Some(((var"##1387").head, (var"##1387").args))
                                                end
                                                var"##1389" = (var"##cache#1388").value
                                                var"##1389" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                                            end && (var"##1389"[1] == :tuple && (begin
                                                        var"##1390" = var"##1389"[2]
                                                        var"##1390" isa AbstractArray
                                                    end && (ndims(var"##1390") === 1 && length(var"##1390") >= 0))))))))
                    var"##return#1189" = begin
                            inline(ex)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1391" = (var"##cache#1192").value
                            var"##1391" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1391"[1] == :return && (begin
                                    var"##1392" = var"##1391"[2]
                                    var"##1392" isa AbstractArray
                                end && (length(var"##1392") === 1 && begin
                                        var"##1393" = var"##1392"[1]
                                        true
                                    end)))
                    code = var"##1393"
                    var"##return#1189" = begin
                            leading_tab()
                            keyword("return ")
                            p(code)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
                if begin
                            var"##1394" = (var"##cache#1192").value
                            var"##1394" isa (Tuple{Symbol, var2} where var2 <: AbstractArray)
                        end && (var"##1394"[1] == :toplevel && (begin
                                    var"##1395" = var"##1394"[2]
                                    var"##1395" isa AbstractArray
                                end && (length(var"##1395") === 1 && begin
                                        var"##1396" = var"##1395"[1]
                                        true
                                    end)))
                    code = var"##1396"
                    var"##return#1189" = begin
                            leading_tab()
                            printstyled("#= meta: toplevel =#", color = c.comment)
                            println()
                            p(code)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
            end
            if var"##1191" isa String
                begin
                    var"##return#1189" = begin
                            leading_tab()
                            occursin('\n', ex) || return inline(ex)
                            printstyled("\"\"\"\n", color = c.string)
                            tab()
                            print_multi_lines(ex)
                            printstyled("\"\"\"", color = c.string)
                        end
                    $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
                end
            end
            begin
                var"##return#1189" = begin
                        inline(ex)
                    end
                $(Expr(:symbolicgoto, Symbol("####final#1190#1397")))
            end
            error("matching non-exhaustive, at #= none:246 =#")
            $(Expr(:symboliclabel, Symbol("####final#1190#1397")))
            var"##return#1189"
        end
        return nothing
    end
    #= none:468 =# Core.@doc "    print_expr([io::IO], ex; kw...)\n\nPrint a given expression. `ex` can be a `Expr` or a syntax type `JLExpr`.\n" print_expr(io::IO, ex; kw...) = begin
                (Printer(io; kw...))(ex)
            end
    print_expr(ex; kw...) = begin
            print_expr(stdout, ex; kw...)
        end
