isassign(frame::Frame) = isassign(frame, frame.pc)
isassign(frame::Frame, pc::Int) = (pc in frame.framecode.used)

lookup_var(frame::Frame, val::SSAValue) = frame.framedata.ssavalues[val.id]
lookup_var(frame::Frame, ref::GlobalRef) = @invokelatest getglobal(ref.mod, ref.name)
function lookup_var(frame::Frame, slot::SlotNumber)
    val = frame.framedata.locals[slot.id]
    val !== nothing && return val.value
    throw(UndefVarError(frame.framecode.src.slotnames[slot.id]))
end

"""
    lookup([interp::Interpreter=RecursiveInterpreter()], frame::Frame, node)

Looks up previously-computed values referenced as `SSAValue`, `SlotNumber`,
`GlobalRef`, sparam or exception reference expression.
It will also lookup `Symbol`s as global reference in the context of `moduleof(frame)::Module`.
If none of the above apply, the value of `node` will be returned.
"""
function lookup(interp::Interpreter, frame::Frame, @nospecialize(node))
    if isa(node, Symbol)
        node = GlobalRef(moduleof(frame), node)
    end
    if isa(node, SSAValue)
        return lookup_var(frame, node)
    elseif isa(node, SlotNumber)
        return lookup_var(frame, node)
    elseif isa(node, GlobalRef)
        return lookup_var(frame, node)
    elseif isa(node, Expr)
        return lookup_expr(interp, frame, node)
    else # fallback
        if isa(node, QuoteNode)
            return node.value
        end
        return node
    end
end
lookup(frame::Frame, @nospecialize(node)) = lookup(RecursiveInterpreter(), frame, node)

macro lookup(frame, node)
    f, l = __source__.file, __source__.line
    @warn "`@lookup` at $f:$l is deprecated, use `lookup(frame, node)` instead."
    return :(lookup($(esc(frame)), $(esc(node))))
end
macro lookup(_, frame, node)
    f, l = __source__.file, __source__.line
    @warn "`@lookup(mod, frame, node)` at $f:$l is deprecated, use `lookup(frame, node)` instead."
    return :(lookup($(esc(frame)), $(esc(node))))
end

function lookup_expr(interp::Interpreter, frame::Frame, e::Expr)
    head = e.head
    head === :the_exception && return frame.framedata.last_exception[]
    if head === :static_parameter
        arg = e.args[1]::Int
        if isassigned(frame.framedata.sparams, arg)
            return frame.framedata.sparams[arg]
        else
            syms = sparam_syms(frame.framecode.scope::Method)
            throw(UndefVarError(syms[arg]))
        end
    end
    head === :boundscheck && length(e.args) == 0 && return true
    if head === :call
        f = lookup(interp, frame, e.args[1])
        if (@static VERSION < v"1.11.0-DEV.1180" && true) && f === Core.svec
            # work around for a linearization bug in Julia (https://github.com/JuliaLang/julia/pull/52497)
            return Core.svec(Any[lookup(interp, frame, e.args[i]) for i in 2:length(e.args)]...)
        elseif f === Core.tuple
            # handling for ccall literal syntax
            return Core.tuple(Any[lookup(interp, frame, e.args[i]) for i in 2:length(e.args)]...)
        end
    end
    error("invalid lookup expr ", e)
end

# This is used only for new struct/abstract/primitive nodes.
# The most important issue is that in these expressions, :call Exprs can be nested,
# and hence our re-use of the `callargs` field of Frame would introduce
# bugs. Since these nodes use a very limited repertoire of calls, we can special-case
# this quite easily.
function lookup_nested(interp::Interpreter, frame::Frame, @nospecialize(node))
    if isa(node, Expr)
        ex = Expr(node.head)
        for arg in node.args
            push!(ex.args, lookup_nested(interp, frame, arg))
        end
        if ex.head === :call
            f = ex.args[1]
            if f === Core.svec
                popfirst!(ex.args)
                return Core.svec(ex.args...)
            elseif f === Core.apply_type
                popfirst!(ex.args)
                return Core.apply_type(ex.args...)
            elseif f === typeof && length(ex.args) == 2
                return typeof(ex.args[2])
            elseif f === typeassert && length(ex.args) == 3
                return typeassert(ex.args[2], ex.args[3])
            elseif f === Base.getproperty && length(ex.args) == 3
                return invokelatest(Base.getproperty, ex.args[2], ex.args[3])
            elseif f === Base.getindex && length(ex.args) >= 3
                popfirst!(ex.args)
                return Base.getindex(ex.args...)
            elseif f === Core.Compiler.Val && length(ex.args) == 2
                return Core.Compiler.Val(ex.args[2])
            elseif f === Val && length(ex.args) == 2
                return Val(ex.args[2])
            else
                @invokelatest error("unknown call f introduced by ccall lowering ", f)
            end
        else
            return lookup_expr(interp, frame, ex)
        end
    end
    return lookup(interp, frame, node)
end

function resolvefc(frame::Frame, @nospecialize(expr))
    if isa(expr, SlotNumber)
        expr = lookup_var(frame, expr)
    elseif isa(expr, SSAValue)
        expr = lookup_var(frame, expr)
        isa(expr, Symbol) && return QuoteNode(expr)
    end
    (isa(expr, Symbol) || isa(expr, String) || isa(expr, Ptr) || isa(expr, QuoteNode)) && return expr
    isa(expr, Tuple{Symbol,Symbol}) && return expr
    isa(expr, Tuple{String,String}) && return expr
    isa(expr, Tuple{Symbol,String}) && return expr
    isa(expr, Tuple{String,Symbol}) && return expr
    if isexpr(expr, :call)
        a = (expr::Expr).args[1]
        (isa(a, QuoteNode) && a.value === Core.tuple) || error("unexpected ccall to ", expr)
        return Expr(:call, GlobalRef(Core, :tuple), (expr::Expr).args[2:end]...)
    end
    @invokelatest error("unexpected ccall to ", expr)
end

function collect_args(interp::Interpreter, frame::Frame, call_expr::Expr; isfc::Bool=false)
    args = frame.framedata.callargs
    resize!(args, length(call_expr.args))
    args[1] = isfc ? resolvefc(frame, call_expr.args[1]) : lookup(interp, frame, call_expr.args[1])
    for i = 2:length(args)
        if isexpr(call_expr.args[i], :call)
            args[i] = lookup_nested(interp, frame, call_expr.args[i]::Expr)
        else
            args[i] = lookup(interp, frame, call_expr.args[i])
        end
    end
    return args
end

"""
    ret = evaluate_foreigncall(interp, frame::Frame, call_expr)

Evaluate a `:foreigncall` (from a `ccall`) statement `callexpr` in the context of `frame`.
"""
function evaluate_foreigncall(interp::Interpreter, frame::Frame, call_expr::Expr)
    head = call_expr.head
    args = collect_args(interp, frame, call_expr; isfc = head === :foreigncall)
    for i = 2:length(args)
        arg = args[i]
        args[i] = isa(arg, Symbol) ? QuoteNode(arg) : arg
    end
    head === :cfunction && (args[2] = QuoteNode(args[2]))
    if head === :foreigncall && !isa(args[5], QuoteNode)
        args[5] = QuoteNode(args[5])
    end
    scope = frame.framecode.scope
    data = frame.framedata
    if !isempty(data.sparams) && scope isa Method
        sig = scope.sig
        args[2] = instantiate_type_in_env(args[2], sig, data.sparams)
        arg3 = args[3]
        if head === :foreigncall
            args[3] = Core.svec(map(arg3) do arg
                instantiate_type_in_env(arg, sig, data.sparams)
            end...)
        else
            args[3] = instantiate_type_in_env(arg3, sig, data.sparams)
            args[4] = Core.svec(map(args[4]::Core.SimpleVector) do arg
                instantiate_type_in_env(arg, sig, data.sparams)
            end...)
        end
    end
    return Core.eval(moduleof(frame), Expr(head, args...))
end

# We have to intercept ccalls / llvmcalls before we try it as a builtin
function bypass_builtins(interp::Interpreter, frame::Frame, call_expr::Expr, pc::Int)
    if isassigned(frame.framecode.methodtables, pc)
        tme = frame.framecode.methodtables[pc]
        if isa(tme, Compiled)
            fargs = collect_args(interp, frame, call_expr)
            f = to_function(fargs[1])
            fmod = parentmodule(f)::Module
            if fmod === JuliaInterpreter.CompiledCalls || fmod === Core.Compiler
                # Fixing https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/432.
                return Some{Any}(Base.invoke_in_world(get_world_counter(), f, fargs[2:end]...))
            else
                return Some{Any}(f(fargs[2:end]...))
            end
        end
    end
    return nothing
end

function native_call(fargs::Vector{Any}, frame::Frame)
    f = popfirst!(fargs)
    @something maybe_eval_with_scope(f, fargs, frame) return @invokelatest f(fargs...)
end

function maybe_eval_with_scope(@nospecialize(f), fargs::Vector{Any}, frame::Frame)
    @static isdefinedglobal(Core.IR, :EnterNode) || return nothing
    newscope = Core.current_scope()
    if newscope !== nothing || !isempty(frame.framedata.current_scopes)
        for scope in frame.framedata.current_scopes
            newscope = Scope(newscope, scope.values...)
        end
        ex = Expr(:tryfinally, :($f($fargs...)), nothing, newscope)
        return Some{Any}(Core.eval(moduleof(frame), ex))
    end
    return nothing
end

function evaluate_call!(interp::NonRecursiveInterpreter, frame::Frame, call_expr::Expr, enter_generated::Bool=false)
    # @assert !enter_generated
    pc = frame.pc
    ret = bypass_builtins(interp, frame, call_expr, pc)
    isa(ret, Some{Any}) && return ret.value
    ret = maybe_evaluate_builtin(interp, frame, call_expr, false)
    isa(ret, Some{Any}) && return ret.value
    fargs = collect_args(interp, frame, call_expr)
    return evaluate_call!(interp, frame, fargs, enter_generated)
end
function evaluate_call!(::NonRecursiveInterpreter, frame::Frame, fargs::Vector{Any}, ::Bool)
    return native_call(fargs, frame)
end

function evaluate_call!(interp::Interpreter, frame::Frame, call_expr::Expr, enter_generated::Bool=false)
    pc = frame.pc
    ret = bypass_builtins(interp, frame, call_expr, pc)
    isa(ret, Some{Any}) && return ret.value
    ret = maybe_evaluate_builtin(interp, frame, call_expr, true)
    isa(ret, Some{Any}) && return ret.value
    call_expr = ret
    fargs = collect_args(interp, frame, call_expr)
    return evaluate_call!(interp, frame, fargs, enter_generated)
end
function evaluate_call!(interp::Interpreter, frame::Frame, fargs::Vector{Any}, enter_generated::Bool)
    if fargs[1] === Core.eval
        return Core.eval(fargs[2], fargs[3])  # not a builtin, but worth treating specially
    elseif fargs[1] === Base.rethrow
        err = length(fargs) > 1 ? fargs[2] : frame.framedata.last_exception[]
        throw(err)
    end
    if fargs[1] === Core.invoke # invoke needs special handling
        f_invoked = which(fargs[2], fargs[3])::Method
        fargs_pruned = [fargs[2]; fargs[4:end]]
        sig = Tuple{mapany(_Typeof, fargs_pruned)...}
        ret = prepare_framecode(f_invoked, sig; enter_generated=enter_generated)
        isa(ret, Compiled) && return invoke(fargs[2:end]...)
        @assert ret !== nothing
        framecode, lenv = ret
        lenv === nothing && return framecode  # this was a Builtin
        fargs = fargs_pruned
    else
        method_table = JuliaInterpreter.method_table(interp)
        framecode, lenv = get_call_framecode(fargs, frame.framecode, frame.pc;
                                             enter_generated, method_table)
        if lenv === nothing
            if isa(framecode, Compiled)
                return native_call(fargs, frame)
            end
            return framecode  # this was a Builtin
        end
    end
    newframe = prepare_frame_caller(frame, framecode, fargs, lenv)
    npc = newframe.pc
    shouldbreak(newframe, npc) && return BreakpointRef(newframe.framecode, npc)
    # if the following errors, handle_err will pop the stack and recycle newframe
    ret = finish_and_return!(interp, newframe, false)
    isa(ret, BreakpointRef) && return ret
    frame.callee = nothing
    return_from(newframe)
    return ret
end

"""
    ret = evaluate_call!(interp::Interpreter, frame::Frame, call_expr::Expr, enter_generated::Bool=false)
    ret = evaluate_call!(frame::Frame, call_expr::Expr, enter_generated::Bool=false)

Evaluate a `:call` expression `call_expr` in the context of `frame`.
The first causes it to be executed using Julia's normal dispatch (compiled code),
whereas the second recurses in via the interpreter.
`interp` has a default value of [`RecursiveInterpreter`](@ref).
"""
evaluate_call!(frame::Frame, call_expr::Expr, enter_generated::Bool=false) =
    evaluate_call!(RecursiveInterpreter(), frame, call_expr, enter_generated)

# The following come up only when evaluating toplevel code
function evaluate_methoddef(interp::Interpreter, frame::Frame, node::Expr)
    mt = extract_method_table(frame, node)
    mt !== nothing && return evaluate_overlayed_methoddef(interp, frame, node, mt)
    f = node.args[1]
    if f isa Symbol || f isa GlobalRef
        mod = f isa Symbol ? moduleof(frame) : f.mod
        name = f isa Symbol ? f : f.name
        if isbindingresolved_deprecated
            f = Core.eval(mod, Expr(:function, name))
        else
            # TODO: This logic isn't fully correct, but it's been used for a long
            # time, so let's leave it for now.
            if Base.isbindingresolved(mod, name) && @invokelatest isdefinedglobal(mod, name)  # `isdefinedglobal` accesses the binding, making it impossible to create a new one
                f = @invokelatest getfield(mod, name)
            else
                f = Core.eval(mod, Expr(:function, name))  # create a new function
            end
        end
    end
    length(node.args) == 1 && return f
    sig = lookup(interp, frame, node.args[2])::SimpleVector
    body = lookup(interp, frame, node.args[3])::Union{CodeInfo, Expr}
    method = ccall(:jl_method_def, Any, (Any, Ptr{Cvoid}, Any, Any), sig, C_NULL, body, moduleof(frame)::Module)::Method
    return method
end

function evaluate_overlayed_methoddef(interp::Interpreter, frame::Frame, node::Expr, mt::MethodTable)
    # Overlaying an empty function such as `function f end` is not legal, and `f` must
    # already be defined so we don't need to do as much work as in `evaluate_methoddef`.
    sig = lookup(interp, frame, node.args[2])::SimpleVector
    body = lookup(interp, frame, node.args[3])::Union{CodeInfo, Expr}
    method = ccall(:jl_method_def, Any, (Any, Any, Any, Any), sig, mt, body, moduleof(frame)::Module)::Method
    return method
end

function extract_method_table(frame::Frame, node::Expr; eval = true)
    isexpr(node, :method, 3) || return nothing
    arg = node.args[1]
    isa(arg, MethodTable) && return arg
    if !isa(arg, Symbol) && !isa(arg, GlobalRef)
        eval || return nothing
        value = try Core.eval(moduleof(frame), arg) catch _ nothing end
        isa(value, MethodTable) && return value
        return nothing
    end
    mod, name = isa(arg, Symbol) ? (moduleof(frame), arg) : (arg.mod, arg.name)
    @invokelatest(isdefinedglobal(mod, name)) || return nothing
    value = @invokelatest getglobal(mod, name)
    isa(value, MethodTable) && return value
    return nothing
end

function do_assignment!(frame::Frame, @nospecialize(lhs), @nospecialize(rhs))
    code, data = frame.framecode, frame.framedata
    if isa(lhs, SSAValue)
        data.ssavalues[lhs.id] = rhs
    elseif isa(lhs, SlotNumber)
        counter = (frame.assignment_counter += 1)
        data.locals[lhs.id] = Some{Any}(rhs)
        data.last_reference[lhs.id] = counter
    elseif isa(lhs, Symbol) || isa(lhs, GlobalRef)
        mod = lhs isa Symbol ? moduleof(frame) : lhs.mod
        name = lhs isa Symbol ? lhs : lhs.name
        Core.eval(mod, Expr(:global, name))
        setglobal!(mod, name, rhs)
    end
end

function maybe_assign!(frame::Frame, @nospecialize(stmt), @nospecialize(val))
    pc = frame.pc
    if isexpr(stmt, :(=))
        lhs = stmt.args[1]
        do_assignment!(frame, lhs, val)
    elseif isassign(frame, pc)
        lhs = SSAValue(pc)
        do_assignment!(frame, lhs, val)
    end
    return nothing
end
maybe_assign!(frame::Frame, @nospecialize(val)) = maybe_assign!(frame, pc_expr(frame), val)

function eval_rhs(interp::Interpreter, frame::Frame, node::Expr)
    head = node.head
    if head === :new
        args = Any[lookup(interp, frame, arg) for arg in node.args]
        T = popfirst!(args)::DataType
        rhs = ccall(:jl_new_structv, Any, (Any, Ptr{Any}, UInt32), T, args, length(args))
        return rhs
    elseif head === :splatnew  # Julia 1.2+
        T = lookup(interp, frame, node.args[1])::DataType
        args = lookup(interp, frame, node.args[2])::Tuple
        rhs = ccall(:jl_new_structt, Any, (Any, Any), T, args)
        return rhs
    elseif head === :isdefined
        return check_isdefined(frame, node.args[1])
    elseif head === :call
        return evaluate_call!(interp, frame, node)
    elseif head === :foreigncall || head === :cfunction
        return evaluate_foreigncall(interp, frame, node)
    elseif head === :copyast
        val = (node.args[1]::QuoteNode).value
        return isa(val, Expr) ? copy(val) : val
    elseif head === :boundscheck
        return true
    elseif head === :meta || head === :inbounds || head === :loopinfo ||
           head === :gc_preserve_begin || head === :gc_preserve_end ||
           head === :aliasscope || head === :popaliasscope
        return nothing
    elseif head === :method && length(node.args) == 1
        return @invokelatest evaluate_methoddef(interp, frame, node)
    end
    return lookup_expr(interp, frame, node)
end

function check_isdefined(frame::Frame, @nospecialize(node))
    data = frame.framedata
    if isa(node, SlotNumber)
        return data.locals[node.id] !== nothing
    elseif isa(node, Core.Compiler.Argument) # just to be safe, since base handles this
        return data.locals[node.n] !== nothing
    elseif isexpr(node, :static_parameter)
        return isassigned(data.sparams, node.args[1]::Int)
    elseif isa(node, GlobalRef)
        return isdefinedglobal(node.mod, node.name)
    elseif isa(node, Symbol)
        return isdefinedglobal(moduleof(frame), node)
    else # QuoteNode or other implicitly quoted object
        return true
    end
end

function coverage_visit_line!(frame::Frame)
    pc, code = frame.pc, frame.framecode
    code.report_coverage || return
    src = code.src
    @static if VERSION ≥ v"1.12.0-DEV.173"
        lineinfo = linetable(src, pc)
        if lineinfo !== nothing
            file, line = lineinfo.file, lineinfo.line
            if line != frame.last_codeloc
                file isa Symbol || (file = Symbol(file)::Symbol)
                @ccall jl_coverage_visit_line(file::Cstring, sizeof(file)::Csize_t, line::Cint)::Cvoid
                frame.last_codeloc = line
            end
        end
    else # VERSION < v"1.12.0-DEV.173"
        codeloc = src.codelocs[pc]
        if codeloc != frame.last_codeloc && codeloc != 0
            linetable = src.linetable::Vector{Any}
            lineinfo = linetable[codeloc]::Core.LineInfoNode
            file, line = lineinfo.file, lineinfo.line
            file isa Symbol || (file = Symbol(file)::Symbol)
            @ccall jl_coverage_visit_line(file::Cstring, sizeof(file)::Csize_t, line::Cint)::Cvoid
            frame.last_codeloc = codeloc
        end
    end # @static if
end

# For "profiling" where JuliaInterpreter spends its time. See the commented-out block
# in `step_expr!`
const _location = Dict{Tuple{Method,Int},Int}()

function step_expr!(interp::Interpreter, frame::Frame, @nospecialize(node), istoplevel::Bool)
    pc, code, data = frame.pc, frame.framecode, frame.framedata
    # if !is_leaf(frame)
    #     show_stackloc(frame)
    #     @show node
    # end
    @assert is_leaf(frame)
    coverage_visit_line!(frame)
    local rhs
    # For debugging:
    # show_stackloc(frame)
    # @show node
    # For profiling:
    # location_key = (scopeof(frame), pc)
    # _location[location_key] = get(_location, location_key, 0) + 1
    try
        if isa(node, Expr)
            if node.head === :(=)
                lhs, rhs = node.args
                if isa(rhs, Expr)
                    rhs = eval_rhs(interp, frame, rhs)
                else
                    rhs = lookup(interp, frame, rhs)
                end
                isa(rhs, BreakpointRef) && return rhs
                do_assignment!(frame, lhs, rhs)
            elseif node.head === :enter
                rhs = node.args[1]::Int
                push!(data.exception_frames, rhs)
            elseif node.head === :leave
                if length(node.args) == 1 && isa(node.args[1], Int)
                    arg = node.args[1]::Int
                    for _ = 1:arg
                        pop!(data.exception_frames)
                    end
                else
                    for i = 1:length(node.args)
                        targ = node.args[i]
                        targ === nothing && continue
                        enterstmt = frame.framecode.src.code[(targ::SSAValue).id]
                        enterstmt === nothing && continue
                        pop!(data.exception_frames)
                        if isdefined(enterstmt, :scope)
                            pop!(data.current_scopes)
                        end
                    end
                end
            elseif node.head === :pop_exception
                # TODO: This needs to handle the exception stack properly
                # (https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/591)
            elseif istoplevel
                if node.head === :method && length(node.args) > 1
                    rhs = @invokelatest evaluate_methoddef(interp, frame, node)
                elseif node.head === :module
                    error("this should have been handled by split_expressions")
                elseif node.head === :using || node.head === :import || node.head === :export
                    Core.eval(moduleof(frame), node)
                elseif node.head === :const || node.head === :globaldecl
                    g = node.args[1]
                    if length(node.args) == 2
                        Core.eval(moduleof(frame), Expr(:block, Expr(node.head, g, QuoteNode(lookup(interp, frame, node.args[2]))), nothing))
                    else
                        Core.eval(moduleof(frame), Expr(:block, Expr(node.head, g), nothing))
                    end
                elseif node.head === :thunk
                    newframe = Frame(moduleof(frame), node.args[1]::CodeInfo)
                    finish!(interp, newframe, true)
                    return_from(newframe)
                elseif node.head === :global
                    Core.eval(moduleof(frame), node)
                elseif node.head === :toplevel
                    mod = moduleof(frame)
                    iter = ExprSplitter(mod, node)
                    rhs = Core.eval(mod, Expr(:toplevel,
                        :(for (mod, ex) in $iter
                              if ex.head === :toplevel
                                  Core.eval(mod, ex)
                                  continue
                              end
                              newframe = ($Frame)(mod, ex)
                              while true
                                  ($through_methoddef_or_done!)($interp, newframe) === nothing && break
                              end
                              $return_from(newframe)
                          end)))
                elseif node.head === :error
                    error("unexpected error statement ", node)
                elseif node.head === :incomplete
                    error("incomplete statement ", node)
                elseif node.head === :latestworld
                    frame.world = Base.get_world_counter()
                else
                    rhs = eval_rhs(interp, frame, node)
                end
            elseif node.head === :thunk || node.head === :toplevel
                error("this frame needs to be run at top level")
            else
                rhs = eval_rhs(interp, frame, node)
            end
        elseif isa(node, GotoNode)
            @assert is_leaf(frame)
            return (frame.pc = node.label)
        elseif isa(node, GotoIfNot)
            arg = lookup(interp, frame, node.cond)
            if !isa(arg, Bool)
                throw(TypeError(nameof(frame), "if", Bool, arg))
            end
            if !arg
                @assert is_leaf(frame)
                return (frame.pc = node.dest)
            end
        elseif isa(node, ReturnNode)
            return nothing
        elseif isa(node, NewvarNode)
            # FIXME: undefine the slot?
        elseif istoplevel && isa(node, LineNumberNode)
        elseif istoplevel && isa(node, Symbol)
            rhs = invokelatest(getfield, moduleof(frame), node)
        elseif @static (isdefinedglobal(Core.IR, :EnterNode) && true) && isa(node, Core.IR.EnterNode)
            rhs = node.catch_dest
            push!(data.exception_frames, rhs)
            if isdefined(node, :scope)
                push!(data.current_scopes, lookup(interp, frame, node.scope))
            end
        else
            rhs = lookup(interp, frame, node)
        end
    catch err
        return handle_err(interp, frame, err)
    end
    @isdefined(rhs) && isa(rhs, BreakpointRef) && return rhs
    if isassign(frame, pc)
        # if !@isdefined(rhs)
        #     @show frame node
        # end
        lhs = SSAValue(pc)
        do_assignment!(frame, lhs, rhs)
    end
    @assert is_leaf(frame)
    return (frame.pc = pc + 1)
end

"""
    pc = step_expr!(interp::Interpreter, frame, istoplevel=false)
    pc = step_expr!(frame, istoplevel=false)

Execute the next statement in `frame`. `pc` is the new program counter, or `nothing`
if execution terminates, or a [`BreakpointRef`](@ref) if execution hits a breakpoint.

`interp` controls call evaluation; `interp = NonRecursiveInterpreter()` evaluates :call
expressions by normal dispatch.
The default value `interp = RecursiveInterpreter()` will use recursive interpretation.

If you are evaluating `frame` at module scope you should pass `istoplevel=true`.
"""
step_expr!(interp::Interpreter, frame::Frame, istoplevel::Bool=false) =
    step_expr!(interp, frame, pc_expr(frame), istoplevel)
step_expr!(frame::Frame, istoplevel::Bool=false) = step_expr!(RecursiveInterpreter(), frame, istoplevel)

"""
    loc = handle_err(interp, frame, err)

Deal with an error `err` that arose while evaluating `frame`. There are one of three
behaviors:

- if `frame` catches the error, `loc` is the program counter at which to resume
  evaluation of `frame`;
- if `frame` doesn't catch the error, but `break_on_error[]` is `true`,
  `loc` is a `BreakpointRef`;
- otherwise, `err` gets rethrown.
"""
function handle_err(::Interpreter, frame::Frame, @nospecialize(err))
    data = frame.framedata
    err_will_be_thrown_to_top_level = isempty(data.exception_frames) && !data.caller_will_catch_err
    if break_on_throw[] || (break_on_error[] && err_will_be_thrown_to_top_level)
        return BreakpointRef(frame.framecode, frame.pc, err)
    end
    if isempty(data.exception_frames)
        if !err_will_be_thrown_to_top_level
            return_from(frame)
        end
        # Check for world age errors, which generally indicate a failure to go back to toplevel
        if isa(err, MethodError)
            is_arg_types = isa(err.args, DataType)
            arg_types = is_arg_types ? err.args : Base.typesof(err.args...)
            if (err.world != typemax(UInt) &&
                hasmethod(err.f, arg_types) &&
                !hasmethod(err.f, arg_types, world = err.world))
                @warn "likely failure to return to toplevel, try `ExprSplitter`"
            end
        end
        rethrow(err)
    end
    data.last_exception[] = err
    pc = @static VERSION >= v"1.11-" ? pop!(data.exception_frames) : data.exception_frames[end] # implicit :leave after https://github.com/JuliaLang/julia/pull/52245
    @assert is_leaf(frame)
    frame.pc = pc
    return pc
end

lookup_return(interp::Interpreter, frame::Frame, node::ReturnNode) = lookup(interp, frame, node.val)

"""
    ret = get_return(interp, frame)

Get the return value of `frame`. Throws an error if `frame.pc` does not point to a `return` expression.
`frame` must have already been executed so that the return value has been computed (see,
e.g., [`JuliaInterpreter.finish!`](@ref)).
"""
function get_return(interp::Interpreter, frame::Frame)
    node = pc_expr(frame)
    is_return(node) || @invokelatest error("expected return statement, got ", node)
    return lookup_return(interp, frame, node)
end
get_return(frame::Frame) = get_return(RecursiveInterpreter(), frame)
get_return(t::Tuple{Module,Expr,Frame}) = get_return(t[end])
