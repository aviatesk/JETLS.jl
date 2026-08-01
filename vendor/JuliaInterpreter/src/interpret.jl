isassign(frame::Frame) = isassign(frame, frame.pc)
isassign(frame::Frame, pc::Int) = (pc in frame.framecode.used)

lookup_var(frame::Frame, val::SSAValue) = frame.framedata.ssavalues[val.id]
lookup_var(frame::Frame, ref::GlobalRef) = invoke_in_world(frame.world, getglobal, ref.mod, ref.name)
function lookup_var(frame::Frame, slot::SlotNumber)
    val = frame.framedata.locals[slot.id]
    val !== nothing && return val.value
    throw(undef_var_error(frame.framecode.src.slotnames[slot.id], :local))
end
function lookup_var(frame::Frame, arg::Core.Argument)
    val = frame.framedata.locals[arg.n]
    val !== nothing && return val.value
    throw(undef_var_error(frame.framecode.src.slotnames[arg.n], :local))
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
    elseif isa(node, Core.Compiler.Argument)
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
    head === :new_opaque_closure && return eval_new_opaque_closure(interp, frame, e)
    if head === :static_parameter
        arg = e.args[1]::Int
        if isassigned(frame.framedata.sparams, arg)
            return frame.framedata.sparams[arg]
        else
            syms = sparam_syms(frame.framecode.scope::Method)
            throw(undef_sparam_error(syms[arg]))
        end
    end
    head === :boundscheck && length(e.args) == 0 && return true
    if head === :foreignglobal
        # On Julia ≥ 1.14, `cglobal` lowers to `Expr(:foreignglobal, spec)`
        # (JuliaLang/julia#61709). Mirror the runtime interpreter's syntactic
        # dispatch (`eval_expr` in src/interpreter.c): a (possibly quoted) symbol,
        # string, or `(name, lib)` tuple resolves through the foreign-symbol
        # lookup; any other argument must evaluate to a pointer, which is
        # returned as a raw `Ptr{Cvoid}` (issue #734).
        fptr = e.args[1]
        if isa(fptr, QuoteNode) && (isa(fptr.value, String) || isa(fptr.value, Tuple))
            fptr = fptr.value
        end
        if isexpr(fptr, :tuple)
            # The `(name, lib)` elements may themselves be `getproperty` chains
            # (e.g. `Base.Math.libm`), which `lookup_nested` resolves.
            spec = Core.tuple(Any[lookup_nested(interp, frame, arg) for arg in (fptr::Expr).args]...)
            return ccall(:jl_cglobal_auto, Any, (Any,), spec)
        elseif isa(fptr, Tuple) || isa(fptr, String)
            return ccall(:jl_cglobal_auto, Any, (Any,), fptr)
        elseif isa(fptr, QuoteNode) && isa(fptr.value, Symbol)
            return ccall(:jl_cglobal_auto, Any, (Any,), fptr.value)
        end
        v = lookup(interp, frame, fptr)
        isa(v, Ptr) || throw(TypeError(:cglobal, Ptr, v))
        return convert(Ptr{Cvoid}, v)
    end
    if head === :call
        f = lookup(interp, frame, e.args[1])
        if (@static VERSION < v"1.11.0-DEV.1180" && true) && f === Core.svec
            # work around for a linearization bug in Julia (https://github.com/JuliaLang/julia/pull/52497)
            return Core.svec(Any[lookup(interp, frame, e.args[i]) for i in 2:length(e.args)]...)
        elseif f === Core.tuple
            # Handling for `ccall`/`cglobal` literal syntax, e.g. the `(:sin, lib)`
            # first argument of `cglobal((:sin, lib), Ptr{Cvoid})`. The library may be
            # spelled as a `getproperty` chain (e.g. `Base.Math.libm` on Julia ≥ 1.11),
            # so resolve each element with `lookup_nested`, which understands
            # `getproperty`/`getindex`/`apply_type`. (Issue #455)
            return Core.tuple(Any[lookup_nested(interp, frame, e.args[i]) for i in 2:length(e.args)]...)
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
                return invoke_in_world(frame.world, Base.getproperty, ex.args[2], ex.args[3])
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
    # Julia 1.13 (`:syntacticccall`) keeps the foreigncall target as a literal `(name, lib)`
    # tuple expression; the eval'd `:foreigncall` expects that form unchanged.
    isexpr(expr, :tuple) && return expr
    if isexpr(expr, :call)
        a = (expr::Expr).args[1]
        # the tuple constructor may appear as a QuoteNode, a GlobalRef, or the function itself
        istuple = a === Core.tuple ||
                  (isa(a, QuoteNode) && a.value === Core.tuple) ||
                  (isa(a, GlobalRef) && a.mod === Core && a.name === :tuple)
        istuple || @invokelatest error("unexpected ccall to ", expr)
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

function instantiate_sparam_types(argtypes::SimpleVector, spsig::UnionAll, sparams::Vector{Any})
    n = length(argtypes)
    inst = Vector{Any}(undef, n)
    for i = 1:n
        inst[i] = instantiate_type_in_env(argtypes[i], spsig, sparams)
    end
    return Core.svec(inst...)
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
        if head === :foreigncall && i >= 6
            # args[2:5] are metadata (return type, argument types, nreq, calling convention);
            # args[6:end] are the evaluated argument values (plus GC roots). The rebuilt
            # expression is passed to `Core.eval`, which re-evaluates raw `Expr`/`Symbol`/
            # `QuoteNode`/`GlobalRef` values as code, so quote every value unconditionally.
            args[i] = QuoteNode(arg)
        else
            args[i] = isa(arg, Symbol) ? QuoteNode(arg) : arg
        end
    end
    head === :cfunction && (args[2] = QuoteNode(args[2]))
    if head === :foreigncall && !isa(args[5], QuoteNode)
        args[5] = QuoteNode(args[5])
    end
    scope = frame.framecode.scope
    data = frame.framedata
    if !isempty(data.sparams) && scope isa Method
        # a method with static parameters always has a `UnionAll` signature
        sig = scope.sig::UnionAll
        args[2] = instantiate_type_in_env(args[2], sig, data.sparams)
        arg3 = args[3]
        if head === :foreigncall
            args[3] = instantiate_sparam_types(arg3::SimpleVector, sig, data.sparams)
        else
            args[3] = instantiate_type_in_env(arg3, sig, data.sparams)
            args[4] = instantiate_sparam_types(args[4]::SimpleVector, sig, data.sparams)
        end
    end
    # A `:foreigncall`/`:cfunction` is a C call with no Julia method dispatch of its own:
    # any `cconvert`/`unsafe_convert` are separate IR statements already run in `frame.world`.
    # It evaluates at top level in the latest world; wrapping `Core.eval` in `invoke_in_world`
    # would only set the world for dispatching `Core.eval` itself, not the expression body.
    return Core.eval(moduleof(frame), Expr(head, args...))
end

# We have to intercept ccalls / llvmcalls before we try it as a builtin
function bypass_builtins(interp::Interpreter, frame::Frame, call_expr::Expr, pc::Int)
    if isassigned(frame.framecode.methodtables, pc)
        tme = frame.framecode.methodtables[pc]
        if isa(tme, Compiled)
            fargs = collect_args(interp, frame, call_expr)
            f = to_function(fargs[1], frame.world)
            fmod = invoke_in_world(frame.world, parentmodule, f)::Module
            if fmod === CompiledCalls || fmod === Core.Compiler
                # These wrappers are generated by JuliaInterpreter itself (for llvmcall/foreigncall),
                # so they must be called in the latest world rather than the frame's world.
                # Fixing https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/432.
                return Some{Any}(invokelatest(f, fargs[2:end]...))
            else
                return Some{Any}(invoke_in_world(frame.world, f, fargs[2:end]...))
            end
        end
    end
    return nothing
end

# Set by the `rethrow` interception just before re-raising, so handler entry can
# distinguish a re-raise (which must not push a duplicate active-exception entry)
# from a fresh `throw` of the same object.
const _rethrow_inflight = Ref{Any}(nothing)

function native_call(fargs::Vector{Any}, frame::Frame)
    f = popfirst!(fargs)
    @something maybe_eval_with_scope(f, fargs, frame) return invoke_in_world(frame.world, f, fargs...)
end

function maybe_eval_with_scope(@nospecialize(f), fargs::Vector{Any}, frame::Frame)
    @static isdefinedglobal(Core.IR, :EnterNode) || return nothing
    newscope = Core.current_scope()
    if newscope !== nothing || !isempty(frame.framedata.current_scopes)
        for scope in frame.framedata.current_scopes
            newscope = Scope(newscope, scope.values...)
        end
        # `Core.eval` only installs the dynamic scope (a lowering construct) and so runs in
        # the latest world; pin the call itself to the frame's world inside the expression.
        # Quote every spliced value: AST-significant arguments (e.g. the `Symbol` property name
        # in `getproperty(mod, :name)`) must enter the expression as literals, not be re-evaluated
        # as variable references.
        call = Expr(:call, invoke_in_world, frame.world, QuoteNode(f))
        for a in fargs
            push!(call.args, QuoteNode(a))
        end
        ex = Expr(:tryfinally, call, nothing, newscope)
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
        if length(fargs) > 1
            exc = fargs[2]
            # `rethrow(exc)` replaces the exception currently being handled; find it in
            # the frame chain (native `jl_rethrow_other` replaces the stack top).
            fr = frame
            while fr !== nothing
                exs = fr.framedata.exceptions
                if !isempty(exs)
                    exs[end] = exc
                    fr.framedata.last_exception[] = exc
                    _rethrow_inflight[] = exc
                    throw(exc)
                end
                fr = fr.caller
            end
            throw(exc)
        end
        # `rethrow()` rethrows the task's innermost exception being handled, which may live
        # in a caller's frame when it is reached from a function called inside a `catch`
        # block. Each frame tracks its own active-exception stack, so walk the caller chain
        # for the innermost frame with a nonempty stack.
        fr = frame
        while fr !== nothing
            exs = fr.framedata.exceptions
            if !isempty(exs)
                _rethrow_inflight[] = exs[end]
                throw(exs[end])
            end
            fr = fr.caller
        end
        # No interpreted frame is handling an exception; fall back to the native rethrow
        # (interpreted code may be running inside a native `catch` block).
        rethrow()
    elseif fargs[1] === Base.current_exceptions && length(fargs) == 1
        # Exceptions caught by interpreted handlers never reach the task's native
        # exception stack; they live in the frames' modeled stacks. Merge the native
        # stack (outermost) with the caller chain's entries. The interpreter does not
        # record per-exception backtraces, so those entries carry an empty backtrace.
        stack = Any[entry for entry in invoke_in_world(frame.world, Base.current_exceptions)]
        blocks = Vector{Any}[]
        fr = frame
        while fr !== nothing
            exs = fr.framedata.exceptions
            isempty(exs) || pushfirst!(blocks, exs)
            fr = fr.caller
        end
        bt = Union{Ptr{Nothing},Base.InterpreterIP}[]
        for exs in blocks, exc in exs
            push!(stack, (exception = exc, backtrace = bt))
        end
        return Base.ExceptionStack(stack)
    end
    if fargs[1] === Core.invoke # invoke needs special handling
        argtypes = fargs[3]
        fargs_pruned = [fargs[2]; fargs[4:end]]
        sig = Tuple{mapany(_Typeof, fargs_pruned)...}
        if isa(argtypes, Method)
            # `invoke(f, method::Method, args...)` (Julia 1.12+)
            f_invoked = argtypes
            # An inapplicable method is an error; defer to the native `invoke` to raise it.
            sig <: f_invoked.sig || return invoke(fargs[2:end]...)
        elseif isa(argtypes, Core.CodeInstance)
            # `invoke(f, ci::CodeInstance, args...)` requests that specific compiled code:
            # run it natively.
            return invoke(fargs[2:end]...)
        else
            # Select the method in the frame's world; plain `which` would use the task's
            # (possibly newer) world.
            f_invoked = whichtt(Base.signature_type(fargs[2], argtypes); world=frame.world)
            f_invoked === nothing && throw(MethodError(fargs[2], argtypes, frame.world))
        end
        ret = prepare_framecode(f_invoked, sig; enter_generated, world=frame.world)
        isa(ret, Compiled) && return invoke_in_world(frame.world, invoke, fargs[2:end]...)
        @assert ret !== nothing
        framecode, lenv = ret
        lenv === nothing && return framecode  # this was a Builtin
        fargs = fargs_pruned
    else
        mt = method_table(interp)
        framecode, lenv = get_call_framecode(fargs, frame.framecode, frame.pc;
                                             enter_generated, world=frame.world, method_table=mt)
        if lenv === nothing
            if isa(framecode, Compiled)
                return native_call(fargs, frame)
            end
            return framecode  # this was a Builtin
        end
    end
    if enter_generated && isa(framecode, FrameCode) && framecode.generator
        # The generator runs on argument *types*. `prepare_call` performs this conversion
        # but `get_call_framecode` discards the converted arguments, so redo it here
        # (issue #161).
        fargs = Any[_Typeof(a) for a in fargs]
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
How the call is executed depends on `interp`: with `NonRecursiveInterpreter()` the call
runs natively via Julia's normal dispatch (compiled code), whereas the default
[`RecursiveInterpreter`](@ref) constructs a child frame and interprets the callee's
lowered code recursively.
"""
evaluate_call!(frame::Frame, call_expr::Expr, enter_generated::Bool=false) =
    evaluate_call!(RecursiveInterpreter(), frame, call_expr, enter_generated)

# The following come up only when evaluating toplevel code
function evaluate_methoddef(interp::Interpreter, frame::Frame, node::Expr)
    if is_define_method_call(node)
        mod = lookup(interp, frame, node.args[2])::Module
        targetarg = node.args[3]
        target = targetarg isa Expr ? Core.eval(moduleof(frame), targetarg) :
                                      lookup(interp, frame, targetarg)
        @static if isdefinedglobal(Core, :define_method)
            length(node.args) == 3 &&
                return invoke_in_world(frame.world, Core.define_method, mod, target)
            length(node.args) == 5 || error("invalid define_method call")
            sig = lookup(interp, frame, node.args[4])::SimpleVector
            body = lookup(interp, frame, node.args[5])::Union{CodeInfo, Expr}
            return invoke_in_world(frame.world, Core.define_method, mod, target, sig, body)
        end
    end
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
    is_methoddef3(node) || return nothing
    arg = is_define_method_call(node) ? node.args[3] : node.args[1]
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
    if frame.framecode.is_toplevel_surface
        # Driver frames record each statement's value (see `step_toplevel!`). The statement's
        # side effects, including any global assignment, were performed by the child frame, so
        # a surface `:(=)` must not be re-executed here.
        frame.framedata.ssavalues[pc] = val
    elseif isexpr(stmt, :(=))
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
    elseif head === :new_opaque_closure
        return eval_new_opaque_closure(interp, frame, node)
    end
    return lookup_expr(interp, frame, node)
end

# `(argt, rt_lb, rt_ub, [allow_partial::Bool,] method, captures...)`; mirror the runtime
# interpreter (src/interpreter.c) via the exported jlcall wrapper, which consumes the
# argument list in the same layout.
function eval_new_opaque_closure(interp::Interpreter, frame::Frame, node::Expr)
    if any(a -> isexpr(a, :opaque_closure_method), node.args)
        # The method is an unevaluated `:opaque_closure_method` (its constructor is not
        # exported); rebuild the construction with every other operand as a literal and
        # let lowering evaluate it, exactly like a hand-written `@eval` of this form.
        resolved = Any[isexpr(a, :opaque_closure_method) ? a :
                       QuoteNode(lookup(interp, frame, a)) for a in node.args]
        fex = Expr(:->, Expr(:tuple), Expr(:block, Expr(:new_opaque_closure, resolved...)))
        f = Core.eval(moduleof(frame), fex)
        return Base.invokelatest(f)
    end
    args = Any[lookup(interp, frame, arg) for arg in node.args]
    return GC.@preserve args ccall(:jl_new_opaque_closure_jlcall, Any,
                                   (Any, Ptr{Any}, UInt32), nothing, args, length(args))
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
        return invoke_in_world(frame.world, isdefinedglobal, node.mod, node.name)
    elseif isa(node, Symbol)
        return invoke_in_world(frame.world, isdefinedglobal, moduleof(frame), node)
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

"""
    JuliaInterpreter.finish_latestworld!(interp, frame)

Run `frame` to completion with the task's world age raised to the latest committed world,
so that methods and bindings defined by earlier top-level statements are visible. This is
used internally by toplevel/module driver frames to execute each child frame.
"""
function finish_latestworld!(interp::Interpreter, frame::Frame)
    return invoke_in_world(Base.get_world_counter(), finish!, interp, frame, true)
end

# Interpret a single surface statement `node` of a toplevel/module driver frame (see
# `is_toplevel_surface`). `:module`/`:toplevel`/`:using`/... are handled directly; every other
# statement is lowered and run as a child frame so that method/struct/const definitions, scoping
# blocks (issue #427), and macro expansions are handled by the ordinary lowered-code machinery.
function step_toplevel!(interp::Interpreter, frame::Frame, @nospecialize(node))
    pc = frame.pc
    data = frame.framedata
    mod = moduleof(frame)
    frame.world = Base.get_world_counter()
    local rhs
    try
        if isa(node, LineNumberNode) || isa(node, Nothing)
            # nothing to do; just advance
        elseif isa(node, Core.ReturnNode)
            return nothing
        elseif isa(node, Expr) && node.head === :module
            newmod, modbody = find_or_create_module(mod, node)
            newframe = toplevel_frame(newmod, modbody.args; world=frame.world)
            link_caller_callee!(frame, newframe)
            ret = finish_latestworld!(interp, newframe)
            isa(ret, BreakpointRef) && return ret
            return_from(newframe)
            rhs = newmod
        elseif isa(node, Expr) && node.head === :toplevel
            newframe = toplevel_frame(mod, node.args; world=frame.world)
            link_caller_callee!(frame, newframe)
            ret = finish_latestworld!(interp, newframe)
            isa(ret, BreakpointRef) && return ret
            rhs = get_return(newframe)
            return_from(newframe)
        elseif isa(node, Expr) && (node.head === :using || node.head === :import ||
                                   node.head === :export || node.head === :public)
            invoke_in_world(Base.get_world_counter(), Core.eval, mod, node)
        else
            rhs = interpret_toplevel_stmt!(interp, frame, node)
            isa(rhs, BreakpointRef) && return rhs
        end
        data.ssavalues[pc] = @isdefined(rhs) ? rhs : nothing
    catch err
        return handle_err(interp, frame, err)
    end
    return (frame.pc = pc + 1)
end

# Lower an ordinary toplevel statement and interpret it as a child frame.
function interpret_toplevel_stmt!(interp::Interpreter, frame::Frame, @nospecialize(stmt))
    mod = moduleof(frame)
    lwr = isa(stmt, Expr) ? Meta.lower(mod, stmt) : stmt
    if isexpr(lwr, :thunk, 1)
        newframe = Frame(mod, (lwr.args[1])::CodeInfo; world=frame.world)
        link_caller_callee!(frame, newframe)
        ret = finish_latestworld!(interp, newframe)
        isa(ret, BreakpointRef) && return ret
        rhs = get_return(newframe)
        return_from(newframe)
        return rhs
    elseif isexpr(lwr, :error)
        throw(ArgumentError("lowering returned an error, $lwr"))
    elseif isexpr(lwr, (:toplevel, :module))
        # macro expansion surfaced a nested toplevel/module; interpret it directly
        newframe = Frame(mod, lwr::Expr; world=frame.world)
        link_caller_callee!(frame, newframe)
        ret = finish_latestworld!(interp, newframe)
        isa(ret, BreakpointRef) && return ret
        rhs = get_return(newframe)
        return_from(newframe)
        return rhs
    else
        # not lowerable to a thunk (e.g. a bare `:global` declaration or a literal value)
        return invoke_in_world(Base.get_world_counter(), Core.eval, mod, isa(lwr, Expr) ? lwr : stmt)
    end
end

function step_expr!(interp::Interpreter, frame::Frame, @nospecialize(node), istoplevel::Bool)
    pc, code, data = frame.pc, frame.framecode, frame.framedata
    # if !is_leaf(frame)
    #     show_stackloc(frame)
    #     @show node
    # end
    @assert is_leaf(frame)
    # Toplevel code always runs in the latest world: each statement must see the
    # bindings, methods, and types defined by earlier statements in the same frame.
    # Method frames, by contrast, execute in the fixed world captured at frame creation.
    istoplevel && (frame.world = Base.get_world_counter())
    if frame.framecode.is_toplevel_surface
        return step_toplevel!(interp, frame, node)
    end
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
                push!(data.exception_frames, node.args[1]::Int)
                push!(data.exception_scopes, length(data.current_scopes))
                # The enter's SSA value is the token consumed by `:pop_exception`: the
                # active-exception stack depth to restore.
                rhs = length(data.exceptions)
            elseif node.head === :leave
                if length(node.args) == 1 && isa(node.args[1], Int)
                    arg = node.args[1]::Int
                    for _ = 1:arg
                        pop!(data.exception_frames)
                        pop!(data.exception_scopes)
                    end
                else
                    for i = 1:length(node.args)
                        targ = node.args[i]
                        targ === nothing && continue
                        enterstmt = frame.framecode.src.code[(targ::SSAValue).id]
                        enterstmt === nothing && continue
                        pop!(data.exception_frames)
                        pop!(data.exception_scopes)
                        if isdefined(enterstmt, :scope)
                            pop!(data.current_scopes)
                        end
                    end
                end
            elseif node.head === :pop_exception
                # Restore the active-exception stack to its depth at the corresponding
                # `:enter` (recorded as that statement's SSA value); this runs at the
                # normal exit of a `catch` block (issue #591).
                depth = lookup(interp, frame, node.args[1])::Int
                if depth < length(data.exceptions)
                    resize!(data.exceptions, depth)
                    data.last_exception[] = isempty(data.exceptions) ?
                        _INACTIVE_EXCEPTION.instance : data.exceptions[end]
                end
            elseif istoplevel
                # This branch handles `:module`/`:toplevel` reached from a *lowered* `:thunk`.
                # `step_toplevel!` handles the same heads reached from *unlowered* surface
                # statements; keep the two in sync.
                if node.head === :method && length(node.args) > 1
                    rhs = @invokelatest evaluate_methoddef(interp, frame, node)
                elseif node.head === :module
                    newmod, modbody = find_or_create_module(moduleof(frame), node)
                    newframe = toplevel_frame(newmod, modbody.args; world=frame.world)
                    link_caller_callee!(frame, newframe)
                    ret = finish_latestworld!(interp, newframe)
                    isa(ret, BreakpointRef) && return ret
                    return_from(newframe)
                    rhs = newmod
                elseif node.head === :using || node.head === :import || node.head === :export || node.head === :public
                    Core.eval(moduleof(frame), node)
                elseif node.head === :const || node.head === :globaldecl
                    g = node.args[1]
                    if length(node.args) == 2
                        Core.eval(moduleof(frame), Expr(:block, Expr(node.head, g, QuoteNode(lookup(interp, frame, node.args[2]))), nothing))
                    else
                        Core.eval(moduleof(frame), Expr(:block, Expr(node.head, g), nothing))
                    end
                elseif node.head === :thunk
                    newframe = Frame(moduleof(frame), node.args[1]::CodeInfo; world=frame.world)
                    finish!(interp, newframe, true)
                    return_from(newframe)
                elseif node.head === :global
                    Core.eval(moduleof(frame), node)
                elseif node.head === :toplevel
                    newframe = toplevel_frame(moduleof(frame), node.args; world=frame.world)
                    link_caller_callee!(frame, newframe)
                    ret = finish_latestworld!(interp, newframe)
                    isa(ret, BreakpointRef) && return ret
                    rhs = get_return(newframe)
                    return_from(newframe)
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
            # A `NewvarNode` marks the (re-)entry of a variable's scope: the slot must be
            # reset to undefined, e.g. so a value from a previous loop iteration does not
            # remain visible (native code would throw `UndefVarError`).
            id = node.slot.id
            data.locals[id] = nothing
            data.last_reference[id] = 0
        elseif istoplevel && isa(node, LineNumberNode)
        elseif istoplevel && isa(node, Symbol)
            rhs = invoke_in_world(frame.world, getfield, moduleof(frame), node)
        elseif @static (isdefinedglobal(Core.IR, :EnterNode) && true) && isa(node, Core.IR.EnterNode)
            push!(data.exception_frames, node.catch_dest)
            # Record the scope depth at handler entry (before any scope introduced by this
            # `EnterNode`), so exception unwinding can restore `current_scopes`.
            push!(data.exception_scopes, length(data.current_scopes))
            # The enter's SSA value is the token consumed by `:pop_exception`: the
            # active-exception stack depth to restore.
            rhs = length(data.exceptions)
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
    pc = enter_exception_handler!(data, err)
    @assert is_leaf(frame)
    frame.pc = pc
    return pc
end

# Land a frame in its innermost active exception handler for `err`: restore the
# dynamic-scope stack to its depth at handler entry (native `jl_eh_restore_state`),
# pop the handler (on Julia 1.11+, where lowering no longer emits an explicit `:leave`
# at the catch entry), record `err` on the frame's active-exception stack, and return
# the catch-destination pc. Shared by `handle_err` and the debugger's
# `unwind_exception` so both unwind paths have identical semantics.
function enter_exception_handler!(data::FrameData, @nospecialize(err))
    scope_depth = data.exception_scopes[end]
    scope_depth < length(data.current_scopes) && resize!(data.current_scopes, scope_depth)
    data.last_exception[] = err
    if _rethrow_inflight[] === err && !isempty(data.exceptions) && data.exceptions[end] === err
        # A `rethrow()` re-raise of this frame's in-flight exception (e.g. a `finally`
        # block re-raising during unwinding): native `jl_rethrow` does not push a new
        # entry onto the task's exception stack, so neither do we.
        _rethrow_inflight[] = nothing
    else
        push!(data.exceptions, err)
    end
    pc = @static VERSION >= v"1.11-" ? pop!(data.exception_frames) : data.exception_frames[end] # implicit :leave after https://github.com/JuliaLang/julia/pull/52245
    @static VERSION >= v"1.11-" && pop!(data.exception_scopes)
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
