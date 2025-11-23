## Simple utils

# Note: to avoid dynamic dispatch, many of these are coded as a single method using isa statements

function scopeof(@nospecialize(x))::Union{Method,Module}
    (isa(x, Method) || isa(x, Module)) && return x
    isa(x, FrameCode) && return x.scope
    isa(x, Frame) && return x.framecode.scope
    error("unknown scope for ", x)
end

function moduleof(@nospecialize(x))
    s = scopeof(x)
    return isa(s, Module) ? s : s.module
end

function Base.nameof(frame::Frame)
    s = frame.framecode.scope
    isa(s, Method) ? s.name : nameof(s)
end

_Typeof(x) = isa(x, Type) ? Type{x} : typeof(x)

function to_function(@nospecialize(x))
    isa(x, GlobalRef) ? invokelatest(getfield, x.mod, x.name) : x
end

"""
    method = whichtt(tt, mt = nothing)

Like `which` except it operates on the complete tuple-type `tt`,
and doesn't throw when there is no matching method.
"""
function whichtt(@nospecialize(tt), mt::Union{Nothing,MethodTable}=nothing)
    # TODO: provide explicit control over world age? In case we ever need to call "old" methods.
    # TODO Use `CachedMethodTable` for better performance once `teh/worldage` is merged
    match, _ = findsup_mt(tt, Base.get_world_counter(), mt)
    match === nothing && return nothing
    return match.method
end

@static if VERSION ≥ v"1.12-"
using Base.Compiler: findsup_mt
else
function findsup_mt(@nospecialize(tt), world, method_table)
    if method_table === nothing
        table = Core.Compiler.InternalMethodTable(world)
    elseif method_table isa Core.MethodTable
        table = Core.Compiler.OverlayMethodTable(world, method_table)
    else
        table = method_table
    end
    return Core.Compiler.findsup(tt, table)
end
end

instantiate_type_in_env(arg, spsig::UnionAll, spvals::Vector{Any}) =
    ccall(:jl_instantiate_type_in_env, Any, (Any, Any, Ptr{Any}), arg, spsig, spvals)

function sparam_syms(meth::Method)
    s = Symbol[]
    sig = meth.sig
    while sig isa UnionAll
        push!(s, Symbol(sig.var.name))
        sig = sig.body
    end
    return s
end

separate_kwargs(args...; kwargs...) = (args, values(kwargs))

pc_expr(src::CodeInfo, pc) = src.code[pc]
pc_expr(framecode::FrameCode, pc) = pc_expr(framecode.src, pc)
pc_expr(frame::Frame, pc) = pc_expr(frame.framecode, pc)
pc_expr(frame::Frame) = pc_expr(frame, frame.pc)

function find_used(code::CodeInfo)
    used = BitSet()
    stmts = code.code
    for stmt in stmts
        scan_ssa_use!(used, stmt)
    end
    return used
end

function scan_ssa_use!(used::BitSet, @nospecialize(stmt))
    if isa(stmt, SSAValue)
        push!(used, stmt.id)
    end
    iter = Core.Compiler.userefs(stmt)
    iterval = Core.Compiler.iterate(iter)
    while iterval !== nothing
        useref, state = iterval
        val = Core.Compiler.getindex(useref)
        if (@static VERSION < v"1.11.0-DEV.1180" && true) && isexpr(val, :call)
            # work around for a linearization bug in Julia (https://github.com/JuliaLang/julia/pull/52497)
            scan_ssa_use!(used, val)
        end
        if isa(val, SSAValue)
            push!(used, val.id)
        end
        iterval = Core.Compiler.iterate(iter, state)
    end
end

function hasarg(predicate, args)
    predicate(args) && return true
    for a in args
        predicate(a) && return true
        if isa(a, Expr)
            hasarg(predicate, a.args) && return true
        elseif isa(a, QuoteNode)
            predicate(a.value) && return true
        elseif isa(a, GlobalRef)
            predicate(a.name) && return true
        end
    end
    return false
end

function wrap_params(expr, sparams::Vector{Symbol})
    isempty(sparams) && return expr
    params = []
    for p in sparams
        hasarg(isidentical(p), expr.args) && push!(params, p)
    end
    return isempty(params) ? expr : Expr(:where, expr, params...)
end

function scopename(tn::TypeName)
    modpath = Base.fullname(tn.module)
    if isa(modpath, Tuple{Symbol})
        return Expr(:., modpath[1], QuoteNode(tn.name))
    end
    ex = Expr(:., modpath[end-1], QuoteNode(modpath[end]))
    for i = length(modpath)-2:-1:1
        ex = Expr(:., modpath[i], ex)
    end
    return Expr(:., ex, QuoteNode(tn.name))
end

## Predicates

isidentical(x) = Base.Fix2(===, x)   # recommended over isequal(::Symbol) since it cannot be invalidated

is_return(@nospecialize(node)) = node isa ReturnNode

is_loc_meta(@nospecialize(expr), @nospecialize(kind)) = isexpr(expr, :meta) && length(expr.args) >= 1 && expr.args[1] === kind

"""
    is_global_ref(g, mod, name)

Tests whether `g` is equal to `GlobalRef(mod, name)`.
"""
is_global_ref(@nospecialize(g), mod::Module, name::Symbol) = isa(g, GlobalRef) && g.mod === mod && g.name == name

function is_global_ref_egal(@nospecialize(g), name::Symbol, @nospecialize(ref))
    # Identifying GlobalRefs regardless of how the caller scopes them
    isa(g, GlobalRef) || return false
    g.name === name || return false
    gref = getglobal(g.mod, g.name)
    return gref === ref
end

is_quotenode(@nospecialize(q), @nospecialize(val)) = isa(q, QuoteNode) && q.value == val
is_quotenode_egal(@nospecialize(q), @nospecialize(val)) = isa(q, QuoteNode) && q.value === val

function is_quoted_type(@nospecialize(a), name::Symbol)
    if isa(a, QuoteNode)
        T = a.value
        if isa(T, UnionAll)
            T = Base.unwrap_unionall(T)
        end
        isa(T, DataType) && return T.name.name === name
    end
    return false
end

function is_call(@nospecialize(node))
    isexpr(node, :call) ||
        (isexpr(node, :(=)) && (isexpr(node.args[2], :call)))
end

is_call_or_return(@nospecialize(node)) = is_call(node) || node isa ReturnNode

is_dummy(bpref::BreakpointRef) = bpref.stmtidx == 0 && bpref.err === nothing

function unpack_splatcall(stmt)
    if isexpr(stmt, :call) && length(stmt.args) >= 3 && (is_quotenode_egal(stmt.args[1], Core._apply_iterate) || is_global_ref(stmt.args[1], Core, :_apply_iterate))
        return true, stmt.args[3]
    end
    return false, nothing
end
function unpack_splatcall(stmt, src::CodeInfo)
    issplatcall, callee = unpack_splatcall(stmt)
    if isa(callee, SSAValue)
        callee = src.code[callee.id]
    end
    return issplatcall, callee
end

function is_bodyfunc(@nospecialize(arg))
    if isa(arg, QuoteNode)
        arg = arg.value
    elseif isa(arg, GlobalRef)
        arg = getproperty(arg.mod, arg.name)
    end
    if isa(arg, Function)
        fname = String((typeof(arg).name::Core.TypeName).name)
        return startswith(fname, "##") && match(r"#\d+$", fname) !== nothing
    end
    return false
end

"""
Determine whether we are calling a function for which the current function
is a wrapper (either because of optional arguments or because of keyword arguments).
"""
function is_wrapper_call(@nospecialize(expr))
    isexpr(expr, :(=)) && (expr = expr.args[2])
    isexpr(expr, :call) && any(x->x==SlotNumber(1), expr.args)
end

is_generated(meth::Method) = isdefined(meth, :generator)

get_staged(mi::MethodInstance) = Core.Compiler.get_staged(mi, Base.get_world_counter())

"""
    is_doc_expr(ex)

Test whether expression `ex` is a `@doc` expression.
"""
function is_doc_expr(@nospecialize(ex))
    docsym = Symbol("@doc")
    if isexpr(ex, :macrocall)
        length(ex.args) == 4 || return false
        a = ex.args[1]
        if isa(a, Symbol) && a === docsym
            return true
        elseif is_global_ref(a, Core, docsym)
            return true
        elseif isexpr(a, :.)
            mod, name = a.args[1], a.args[2]
            return mod === :Core && isa(name, QuoteNode) && name.value === docsym
        end
    end
    return false
end

is_leaf(frame::Frame) = frame.callee === nothing

is_vararg_type(@nospecialize x) = x isa Core.TypeofVararg

## Location info

# These getters improve inference since fieldtype(CodeInfo, :linetable)
# and fieldtype(CodeInfo, :codelocs) are both Any
@static if VERSION ≥ v"1.12.0-DEV.173"
    const LineTypes = Union{LineNumberNode,Base.IRShow.LineInfoNode}
else
    const LineTypes = Union{LineNumberNode,Core.LineInfoNode}
end
function linetable(arg)
    if isa(arg, Frame)
        arg = arg.framecode
    end
    if isa(arg, FrameCode)
        arg = arg.src
    end
    ci = arg::CodeInfo
    @static if VERSION ≥ v"1.12.0-DEV.173"
    return ci.debuginfo
    else # VERSION < v"1.12.0-DEV.173"
    return ci.linetable::Union{Vector{Core.LineInfoNode},Vector{Any}} # issue #264
    end # @static if
end
function linetable(arg, i::Integer; macro_caller::Bool=false, def=:var"n/a")::Union{Expr,Nothing,LineTypes}
    lt = linetable(arg)
    @static if VERSION ≥ v"1.12.0-DEV.173"
    # TODO: decode the linetable at this frame efficiently by reimplementing this here
    nodes = Base.IRShow.buildLineInfoNode(lt, def, i)
    isempty(nodes) && return nothing
    return nodes[macro_caller ? 1 : end]
    else # VERSION < v"1.12.0-DEV.173"
    lin = lt[i]::Union{Expr,LineTypes}
    if macro_caller
        while lin isa Core.LineInfoNode && lin.method === Symbol("macro expansion") && lin.inlined_at != 0
            lin = lt[lin.inlined_at]::Union{Expr,LineTypes}
        end
    end
    return lin
    end # @static if
end

@static if VERSION ≥ v"1.12.0-DEV.173"

getlastline(arg) = getlastline(linetable(arg))
function getlastline(debuginfo::Core.DebugInfo)
    while true
        ltnext = debuginfo.linetable
        ltnext === nothing && break
        debuginfo = ltnext
    end
    lastline = 0
    for k = 0:typemax(Int)
        codeloc = Core.Compiler.getdebugidx(debuginfo, k)
        line::Int = codeloc[1]
        line < 0 && break
        lastline = max(lastline, line)
    end
    return lastline
end
function codelocs(arg, i::Integer)
    debuginfo = linetable(arg)
    codeloc = Core.Compiler.getdebugidx(debuginfo, i)
    line::Int = codeloc[1]
    line < 0 && return 0# broken or disabled debug info?
    if line == 0 && codeloc[2] == 0
        return 0 # no line number update
    end
    return i
end

else # VERSION < v"1.12.0-DEV.173"

getfirstline(arg) = getline(linetable(arg)[begin])
getlastline(arg) = getline(linetable(arg)[end])
function codelocs(arg)
    if isa(arg, Frame)
        arg = arg.framecode
    end
    if isa(arg, FrameCode)
        arg = arg.src
    end
    ci = arg::CodeInfo
    return ci.codelocs
end
codelocs(arg, i::Integer) = codelocs(arg)[i]

end # @static if

function lineoffset(framecode::FrameCode)
    offset = 0
    scope = framecode.scope
    if isa(scope, Method)
        _, line1 = whereis(scope)
        offset = line1 - scope.line
    end
    return offset
end

function getline(ln::Union{LineTypes,Expr,Nothing})
    _getline(ln::LineTypes) = Int(ln.line)
    _getline(ln::Expr)      = ln.args[1]::Int # assuming ln.head === :line
    _getline(::Nothing)     = nothing
    return _getline(ln)
end
function getfile(ln::Union{LineTypes,Expr})
    _getfile(ln::LineTypes) = ln.file::Symbol
    _getfile(ln::Expr)      = ln.args[2]::Symbol # assuming ln.head === :line
    return CodeTracking.maybe_fixup_stdlib_path(String(_getfile(ln)))
end

function firstline(ex::Expr)
    for a in ex.args
        isa(a, LineNumberNode) && return a
        if isa(a, Expr)
            line = firstline(a)
            isa(line, LineNumberNode) && return line
        end
    end
    return nothing
end

"""
    loc = whereis(frame, pc::Int=frame.pc; macro_caller=false)

Return the file and line number for `frame` at `pc`.  If this cannot be
determined, `loc == nothing`. Otherwise `loc == (filepath, line)`.

By default, any statements expanded from a macro are attributed to the macro
definition, but with`macro_caller=true` you can obtain the location within the
method that issued the macro.
"""
function CodeTracking.whereis(framecode::FrameCode, pc::Int; kwargs...)
    codeloc = codelocation(framecode.src, pc)
    codeloc == 0 && return nothing
    m = framecode.scope
    lineinfo = linetable(framecode, codeloc; kwargs..., def=isa(m, Method) ? m : :var"n/a")
    if m isa Method
        return lineinfo === nothing ? (String(m.file), m.line) : whereis(lineinfo, m)
    else
        return lineinfo === nothing ? nothing : (getfile(lineinfo), getline(lineinfo))
    end
end
CodeTracking.whereis(frame::Frame, pc::Int=frame.pc; kwargs...) = whereis(frame.framecode, pc; kwargs...)

"""
    line = linenumber(framecode, pc)

Return the "static" line number at statement index `pc`. The static line number
is the location at the time the method was most recently defined.
See [`CodeTracking.whereis`](@ref) for dynamic line information.
"""
function linenumber(framecode::FrameCode, pc)
    codeloc = codelocation(framecode.src, pc)
    codeloc == 0 && return nothing
    return getline(linetable(framecode, codeloc))
end
linenumber(frame::Frame, pc=frame.pc) = linenumber(frame.framecode, pc)

function getfile(framecode::FrameCode, pc)
    codeloc = codelocation(framecode.src, pc)
    codeloc == 0 && return nothing
    return getfile(linetable(framecode, codeloc))
end
getfile(frame::Frame, pc=frame.pc) = getfile(frame.framecode, pc)

function codelocation(code::CodeInfo, idx::Int)
    idx′ = idx
    # look ahead if we are on a meta line
    while idx′ < length(code.code)
        codeloc = codelocs(code, idx′)
        codeloc == 0 || return codeloc
        ex = code.code[idx′]
        ex === nothing || isexpr(ex, :meta) || break
        idx′ += 1
    end
    idx′ = idx - 1
    # if zero, look behind until we find where we last might have had a line
    while idx′ > 0
        ex = code.code[idx′]
        codeloc = codelocs(code, idx′)
        codeloc == 0 || return codeloc
        idx′ -= 1
    end
    # for the start of the function, return index 1
    return 1
end

function compute_corrected_linerange(method::Method)
    _, line1 = whereis(method)
    offset = line1 - method.line
    @assert !is_generated(method)
    src = JuliaInterpreter.get_source(method)
    lastline = getlastline(src)
    return line1:lastline + offset
end

compute_linerange(framecode) = getfirstline(framecode):getlastline(framecode)

function statementnumbers(framecode::FrameCode, line::Integer, file::Symbol)
    # Check to see if this framecode really contains that line. Methods that fill in a default positional argument,
    # keyword arguments, and @generated sections may not contain the line.
    scope = framecode.scope
    offset = if scope isa Method
        method = scope
        _, line1 = whereis(method)
        Int(line1 - method.line)
    else
        0
    end

    linetarget = line - offset

    lts = CodeTracking.linetable_scopes(framecode.src, scope)
    for lt in lts
        filter!(l -> l.file === file, lt) # filter out line scopes that do not match the file we are looking for
    end

    stmtidxs = Int[] # will store the statement indices that match the line
    first_in_block, block_recorded = nothing, false
    for (i, lt) in enumerate(lts)
        # If someone asks for a breakpoint on, e.g., `end`, there may not be a line that matches exactly.
        # In this case, we should make sure that the scope encompasses the requested line and then return the first statement index
        # immediately after.
        if isempty(lt)
            first_in_block = nothing   # start new block
            continue
        end
        thisscope = first(lt)
        if first_in_block === nothing && !iszero(thisscope.line)
            first_in_block, block_recorded = thisscope.line, false
        end
        if !block_recorded   # only record the first match in a contiguous block
            # if it's either an exact match or it's the first larger line in a block that spans the requested line, store it
            if thisscope.line == linetarget || (thisscope.line > linetarget && something(first_in_block, typemax(typeof(thisscope.line))) < linetarget)
                push!(stmtidxs, i)
                block_recorded = true
            end
        end
    end
    return stmtidxs
end

## Printing

function framecode_lines(src::CodeInfo)
    buf = IOBuffer()
    lines = String[]
    src = replace_coretypes!(copy(src); rev=true)
    reverse_lookup_globalref!(src.code)
    io = IOContext(buf, :displaysize => displaysize(stdout),
                    :SOURCE_SLOTNAMES => Base.sourceinfo_slotnames(src))
    used = BitSet()
    cfg = Core.Compiler.compute_basic_blocks(src.code)
    for stmt in src.code
        Core.Compiler.scan_ssa_use!(push!, used, stmt)
    end
    line_info_preprinter = Base.IRShow.lineinfo_disabled
    line_info_postprinter = Base.IRShow.default_expr_type_printer
    bb_idx = 1
    for idx = 1:length(src.code)
        @static if VERSION >= v"1.12.0-DEV.1359"
            parent = src.parent
            sptypes = if parent isa MethodInstance
                Core.Compiler.sptypes_from_meth_instance(parent)
            else Core.Compiler.EMPTY_SPTYPES end
            bb_idx = Base.IRShow.show_ir_stmt(io, src, idx, line_info_preprinter, line_info_postprinter, sptypes, used, cfg, bb_idx)
        else
            bb_idx = Base.IRShow.show_ir_stmt(io, src, idx, line_info_preprinter, line_info_postprinter, used, cfg, bb_idx)
        end
        push!(lines, chomp(String(take!(buf))))
    end
    return lines
    show(buf, src)
    code = filter!(split(String(take!(buf)), '\n')) do line
        !(line == "CodeInfo(" || line == ")" || isempty(line) || occursin("within `", line))
    end
    code .= replace.(code, Ref(r"\$\(QuoteNode\((.+?)\)\)" => s"\1"))
    return code
end
framecode_lines(framecode::FrameCode) = framecode_lines(framecode.src)

breakpointchar(framecode, stmtidx) =
    isassigned(framecode.breakpoints, stmtidx) ? breakpointchar(framecode.breakpoints[stmtidx]) : ' '

function print_framecode(io::IO, framecode::FrameCode; pc=0, range=1:nstatements(framecode), kwargs...)
    iscolor = get(io, :color, false)
    ndstmt = ndigits(nstatements(framecode))
    ndline = ndigits(getlastline(framecode) + lineoffset(framecode))
    nullline = " "^ndline
    src = copy(framecode.src)
    replace_coretypes!(src; rev=true)
    code = framecode_lines(src)
    isfirst = true
    for (stmtidx, stmtline) in enumerate(code)
        stmtidx ∈ range || continue
        bpc = breakpointchar(framecode, stmtidx)
        isfirst || print(io, '\n')
        isfirst = false
        print(io, bpc, ' ')
        if iscolor
            color = stmtidx == pc ? Base.warn_color() : :normal
            printstyled(io, lpad(stmtidx, ndstmt); color=color, kwargs...)
        else
            print(io, lpad(stmtidx, ndstmt), stmtidx == pc ? '*' : ' ')
        end
        line = linenumber(framecode, stmtidx)
        print(io, ' ', line === nothing ? nullline : lpad(line, ndline), "  ", stmtline)
    end
end

"""
    local_variables = locals(frame::Frame)::Vector{Variable}

Return the local variables as a vector of [`Variable`](@ref).
"""
function locals(frame::Frame)
    vars, var_counter = Variable[], Int[]
    varlookup = Dict{Symbol,Int}()
    data, code = frame.framedata, frame.framecode
    slotnames = code.src.slotnames
    for (sym, counter, val) in zip(slotnames, data.last_reference, data.locals)
        counter == 0 && continue
        val = something(val)
        if val isa Core.Box && !isdefined(val, :contents)
            continue
        end
        var = Variable(val, sym)
        idx = get(varlookup, sym, 0)
        if idx > 0
            if counter > var_counter[idx]
                vars[idx] = var
                var_counter[idx] = counter
            end
        else
            varlookup[sym] = length(vars)+1
            push!(vars, var)
            push!(var_counter, counter)
        end
    end
    scope = code.scope
    if scope isa Method
        syms = sparam_syms(scope)
        for i in 1:length(syms)
            if isassigned(data.sparams, i)
                push!(vars, Variable(data.sparams[i], syms[i], true))
            end
        end
    end
    for var in vars
        if var.name === Symbol("#self#")
            for field in fieldnames(typeof(var.value))
                field = field::Symbol
                if isdefined(var.value, field)
                    push!(vars, Variable(getfield(var.value, field), field, false, true))
                end
            end
        end
    end
    return vars
end

function print_vars(io::IO, vars::Vector{Variable})
    for v in vars
        v.name === Symbol("#self#") && (isa(v.value, Type) || sizeof(v.value) == 0) && continue
        print(io, '\n', v)
    end
end

"""
    eval_code(frame::Frame, code::Union{String, Expr})

Evaluate `code` in the context of `frame`, updating any local variables
(including type parameters) that are reassigned in `code`, however, new local variables
cannot be introduced.

```jldoctest
julia> foo(x, y) = x + y;

julia> frame = JuliaInterpreter.enter_call(foo, 1, 3);

julia> JuliaInterpreter.eval_code(frame, "x + y")
4

julia> JuliaInterpreter.eval_code(frame, "x = 5");

julia> JuliaInterpreter.finish_and_return!(frame)
8
```

When variables are captured in closures (and thus gets wrapped in a `Core.Box`)
they will be automatically unwrapped and rewrapped upon evaluating them:

```jldoctest
julia> function capture()
           x = 1
           f = ()->(x = 2) # x captured in closure and is thus a Core.Box
           f()
           x
       end;

julia> frame = JuliaInterpreter.enter_call(capture);

julia> JuliaInterpreter.step_expr!(frame);

julia> JuliaInterpreter.step_expr!(frame);

julia> JuliaInterpreter.locals(frame)
2-element Vector{JuliaInterpreter.Variable}:
 #self# = capture
 x = Core.Box(1)

julia> JuliaInterpreter.eval_code(frame, "x")
1

julia> JuliaInterpreter.eval_code(frame, "x = 2")
2

julia> JuliaInterpreter.locals(frame)
2-element Vector{JuliaInterpreter.Variable}:
 #self# = capture
 x = Core.Box(2)
```

"Special" values like SSA values and slots (shown in lowered code as e.g. `%3` and `@_4`
respectively) can be evaluated using the syntax `var"%3"` and `var"@_4"` respectively.
"""
function eval_code end

function extract_usage!(s::Set{Symbol}, @nospecialize expr)
    if expr isa Expr
        for arg in expr.args
            if arg isa Symbol
                push!(s, arg)
            elseif arg isa Expr
                extract_usage!(s, arg)
            end
        end
    elseif expr isa Symbol
        push!(s, expr)
    end
    return s
end

function eval_code(frame::Frame, command::AbstractString)
    expr = Base.parse_input_line(command)
    expr === nothing && return nothing
    return eval_code(frame, expr)
end
function eval_code(frame::Frame, expr::Expr)
    code = frame.framecode
    data = frame.framedata
    isexpr(expr, :toplevel) && (expr = expr.args[end])

    if isexpr(expr, :toplevel)
        expr = Expr(:block, expr.args...)
    end

    used_symbols = Set{Symbol}((Symbol("#self#"),))
    extract_usage!(used_symbols, expr)
    # see https://github.com/JuliaLang/julia/issues/31255 for the Symbol("") check
    vars = filter(v -> v.name != Symbol("") && v.name in used_symbols, locals(frame))
    defined_ssa    = findall(i -> isassigned(data.ssavalues, i) && Symbol("%$i")  in used_symbols, 1:length(data.ssavalues))
    defined_locals = findall(i-> data.locals[i] isa Some        && Symbol("@_$i") in used_symbols, 1:length(data.locals))
    res = gensym()
    eval_expr = Expr(:let,
                     Expr(:block, map(x->Expr(:(=), x...), [(v.name, QuoteNode(v.value isa Core.Box ? v.value.contents : v.value)) for v in vars])...,
                                  map(x->Expr(:(=), x...), [(Symbol("%$i"), QuoteNode(data.ssavalues[i]))                          for i in defined_ssa])...,
                                  map(x->Expr(:(=), x...), [(Symbol("@_$i"), QuoteNode(data.locals[i].value))                      for i in defined_locals])...,
                     ),
        Expr(:block,
            Expr(:(=), res, expr),
            Expr(:tuple, res, Expr(:tuple, [v.name for v in vars]...))
        ))
    eval_res, res = Core.eval(moduleof(frame), eval_expr)
    j = 1
    for (i, v) in enumerate(vars)
        if v.isparam
            data.sparams[j] = res[i]
            j += 1
        elseif v.is_captured_closure
            selfidx = findfirst(v -> v.name === Symbol("#self#"), vars)
            @assert selfidx !== nothing
            self = vars[selfidx].value
            closed_over_var = getfield(self, v.name)
            if closed_over_var isa Core.Box
                setfield!(closed_over_var, :contents, res[i])
            end
            # We cannot rebind closed over variables that the frontend identified as constant
        else
            slot_indices = code.slotnamelists[v.name]
            idx = argmax(data.last_reference[slot_indices])
            slot_idx = slot_indices[idx]
            data.last_reference[slot_idx] = (frame.assignment_counter += 1)
            data.locals[slot_idx] = Some{Any}(v.value isa Core.Box ? Core.Box(res[i]) : res[i])
        end
    end
    eval_res
end

function show_stackloc(io::IO, frame::Frame)
    indent = ""
    fr = root(frame)
    shown = false
    while fr !== nothing
        print(io, indent, scopeof(fr))
        if fr === frame
            println(io, ", pc = ", frame.pc)
            shown = true
        else
            print(io, '\n')
        end
        indent *= "  "
        fr = fr.callee
    end
    if !shown
        println(io, indent, scopeof(frame), ", pc = ", frame.pc)
    end
end
show_stackloc(frame::Frame) = show_stackloc(stdout, frame)

# Printing of stacktraces and errors with Frame
function Base.StackTraces.StackFrame(frame::Frame)
    scope = scopeof(frame)
    if scope isa Method
        method = scope
        method_args = Any[something(frame.framedata.locals[i]) for i in 1:method.nargs]
        argt = Tuple{mapany(_Typeof, method_args)...}
        sig = method.sig
        atype, sparams = ccall(:jl_type_intersection_with_env, Any, (Any, Any), argt, sig)::SimpleVector
        mi = Core.Compiler.specialize_method(method, atype, sparams::SimpleVector)
        fname = method.name
    else
        mi = frame.framecode.src
        fname = gensym()
    end
    Base.StackFrame(
        fname,
        Symbol(getfile(frame)),
        @something(linenumber(frame), getfirstline(frame)),
        mi,
        false,
        false,
        C_NULL)
end

function Base.show_backtrace(io::IO, frame::Frame)
    stackframes = Tuple{Base.StackTraces.StackFrame, Int}[]
    while frame !== nothing
        push!(stackframes, (Base.StackTraces.StackFrame(frame), 1))
        frame = JuliaInterpreter.caller(frame)
    end
    print(io, "\nStacktrace:")
    try invokelatest(Base.update_stackframes_callback[], stackframes) catch end
    frame_counter = 0
    nd = ndigits(length(stackframes))
    for (i, (last_frame, n)) in enumerate(stackframes)
        frame_counter += 1
        println(io)
        Base.print_stackframe(io, i, last_frame, n, nd, Base.info_color())
    end
end

function Base.display_error(io::IO, er, frame::Frame)
    printstyled(io, "ERROR: "; bold=true, color=Base.error_color())
    showerror(IOContext(io, :limit => true), er, frame)
    println(io)
end
