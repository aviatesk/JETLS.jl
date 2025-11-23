"""
    pc = finish!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = finish!(frame::Frame, istoplevel::Bool=false)

Run `frame` until execution terminates. `pc` is either `nothing` (if execution terminates
when it hits a `return` statement) or a reference to a breakpoint.
In the latter case, `leaf(frame)` returns the frame in which it hit the breakpoint.

`interp` controls call evaluation; `interp = NonRecursiveInterpreter()` evaluates :call expressions
by normal dispatch, whereas the default `interp = RecursiveInterpreter()` uses recursive interpretation.
"""
function finish!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    while true
        pc = step_expr!(interp, frame, istoplevel)
        pc === nothing && return pc
        isa(pc, BreakpointRef) && return pc
        shouldbreak(frame, pc) && return BreakpointRef(frame.framecode, pc)
    end
end
finish!(frame::Frame, istoplevel::Bool=false) = finish!(RecursiveInterpreter(), frame, istoplevel)

"""
    ret = finish_and_return!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    ret = finish_and_return!(frame::Frame, istoplevel::Bool=false)

Call [`JuliaInterpreter.finish!`](@ref) and pass back the return value `ret`. If execution
pauses at a breakpoint, `ret` is the reference to the breakpoint.
"""
function finish_and_return!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = finish!(interp, frame, istoplevel)
    isa(pc, BreakpointRef) && return pc
    return get_return(interp, frame)
end
finish_and_return!(frame::Frame, istoplevel::Bool=false) = finish_and_return!(RecursiveInterpreter(), frame, istoplevel)

"""
    BreakOnCall <: Interpreter

    bpref = @invoke evaluate_call!(BreakOnCall()::Interpreter, frame::Frame, istoplevel::Bool)

An [`Interpreter`](@ref) returning a fake breakpoint. This can be useful as the `interp` argument to
`evaluate_call!` (or any of the higher-order commands) to ensure that you return immediately
after stepping into a call.
"""
struct BreakOnCall <: Interpreter end
function finish_and_return!(::BreakOnCall, frame::Frame, ::Bool=false)
    return BreakpointRef(frame.framecode, 0)
end

"""
    ret = finish_stack!(interp::Interpreter, frame::Frame, rootistoplevel::Bool=false)
    ret = finish_stack!(frame::Frame, rootistoplevel::Bool=false)

Unwind the callees of `frame`, finishing each before returning to the caller.
`frame` itself is also finished. `rootistoplevel` should be true if the root frame is top-level.

`ret` is typically the returned value. If execution hits a breakpoint, `ret` will be a
reference to the breakpoint.
"""
function finish_stack!(interp::Interpreter, frame::Frame, rootistoplevel::Bool=false)
    frame0 = frame
    frame = leaf(frame)
    while true
        istoplevel = rootistoplevel && frame.caller === nothing
        ret = finish_and_return!(interp, frame, istoplevel)
        isa(ret, BreakpointRef) && return ret
        frame === frame0 && return ret
        frame = return_from(frame)
        frame === nothing && return ret
        pc = frame.pc
        if isassign(frame, pc)
            lhs = SSAValue(pc)
            do_assignment!(frame, lhs, ret)
        else
            stmt = pc_expr(frame, pc)
            if isexpr(stmt, :(=))
                lhs = stmt.args[1]
                do_assignment!(frame, lhs, ret)
            end
        end
        pc += 1
        @assert is_leaf(frame)
        frame.pc = pc
        shouldbreak(frame, pc) && return BreakpointRef(frame.framecode, pc)
    end
end
finish_stack!(frame::Frame, istoplevel::Bool=false) = finish_stack!(RecursiveInterpreter(), frame, istoplevel)

"""
    pc = next_until!(predicate, interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = next_until!(predicate, frame::Frame, istoplevel::Bool=false)

Execute the current statement. Then step through statements of `frame` until the next
statement satisfies `predicate(frame)`. `pc` will be the index of the statement at which
evaluation terminates, `nothing` (if the frame reached a `return`), or a `BreakpointRef`.
"""
function next_until!(@nospecialize(predicate), interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = step_expr!(interp, frame, istoplevel)
    while pc !== nothing && !isa(pc, BreakpointRef)
        shouldbreak(frame, pc) && return BreakpointRef(frame.framecode, pc)
        predicate(frame) && return pc
        pc = step_expr!(interp, frame, istoplevel)
    end
    return pc
end
next_until!(@nospecialize(predicate), frame::Frame, istoplevel::Bool=false) =
    next_until!(predicate, RecursiveInterpreter(), frame, istoplevel)

"""
    pc = maybe_next_until!(predicate, interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = maybe_next_until!(predicate, frame::Frame, istoplevel::Bool=false)

Like [`next_until!`](@ref) except checks `predicate` before executing the current statment.

"""
function maybe_next_until!(@nospecialize(predicate), interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    predicate(frame) && return frame.pc
    return next_until!(predicate, interp, frame, istoplevel)
end
maybe_next_until!(@nospecialize(predicate), frame::Frame, istoplevel::Bool=false) =
    maybe_next_until!(predicate, RecursiveInterpreter(), frame, istoplevel)

"""
    pc = next_call!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = next_call!(frame::Frame, istoplevel::Bool=false)

Execute the current statement. Continue stepping through `frame` until the next
`ReturnNode` or `:call` expression.
"""
next_call!(interp::Interpreter, frame::Frame, istoplevel::Bool=false) =
    next_until!(frame::Frame -> is_call_or_return(pc_expr(frame)), interp, frame, istoplevel)
next_call!(frame::Frame, istoplevel::Bool=false) = next_call!(RecursiveInterpreter(), frame, istoplevel)

"""
    pc = maybe_next_call!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = maybe_next_call!(frame::Frame, istoplevel::Bool=false)

Return the current program counter of `frame` if it is a `ReturnNode` or `:call` expression.
Otherwise, step through the statements of `frame` until the next `ReturnNode` or `:call` expression.
"""
maybe_next_call!(interp::Interpreter, frame::Frame, istoplevel::Bool=false) =
    maybe_next_until!(frame::Frame -> is_call_or_return(pc_expr(frame)), interp, frame, istoplevel)
maybe_next_call!(frame::Frame, istoplevel::Bool=false) = maybe_next_call!(RecursiveInterpreter(), frame, istoplevel)

"""
    pc = through_methoddef_or_done!(interp::Interpreter, frame::Frame)
    pc = through_methoddef_or_done!(frame::Frame)

Runs `frame` at top level until it either finishes (e.g., hits a `return` statement)
or defines a new method.
"""
function through_methoddef_or_done!(interp::Interpreter, frame::Frame)
    pc = next_until!(interp, frame, true) do frame::Frame
        stmt = pc_expr(frame)
        return isexpr(stmt, :method, 3) || isexpr(stmt, :thunk)
    end
    (pc === nothing || isa(pc, BreakpointRef)) && return pc
    return step_expr!(interp, frame, true)  # define the method and return
end
through_methoddef_or_done!(interp::Interpreter, t::Tuple{Module,Expr,Frame}) =
    through_methoddef_or_done!(interp, t[end])
through_methoddef_or_done!(::Interpreter, modex::Tuple{Module,Expr,Expr}) = Core.eval(modex[1], modex[3])
through_methoddef_or_done!(::Interpreter, ::Nothing) = nothing
through_methoddef_or_done!(@nospecialize arg) = through_methoddef_or_done!(RecursiveInterpreter(), arg)

# Sentinel to see if the call was a wrapper call
struct Wrapper end

"""
    pc = next_line!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = next_line!(frame::Frame, istoplevel::Bool=false)

Execute until reaching the first call of the next line of the source code.
Upon return, `pc` is either the new program counter, `nothing` if a `return` is reached,
or a `BreakpointRef` if it encountered a wrapper call. In the latter case, call `leaf(frame)`
to obtain the new execution frame.
"""
function next_line!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    pc = frame.pc
    initialline, initialfile = linenumber(frame, pc), getfile(frame, pc)
    if initialline === nothing || initialfile === nothing
        return step_expr!(interp, frame, istoplevel)
    end
    return _next_line!(interp, frame, istoplevel, initialline, initialfile) # avoid boxing
end
function _next_line!(interp::Interpreter, frame::Frame, istoplevel, initialline::Int, initialfile::String)
    pc = next_until!(interp, frame, istoplevel) do frame::Frame
        return is_return(pc_expr(frame)) || (linenumber(frame) != initialline || getfile(frame) != initialfile)
    end
    (pc === nothing || isa(pc, BreakpointRef)) && return pc
    maybe_step_through_kwprep!(interp, frame, istoplevel)
    maybe_next_call!(interp, frame, istoplevel)
end
next_line!(frame::Frame, istoplevel::Bool=false) = next_line!(RecursiveInterpreter(), frame, istoplevel)

"""
    pc = until_line!(interp::Interpreter, frame, line=nothing istoplevel=false)
    pc = until_line!(frame, line=nothing, istoplevel=false)

Execute until the current frame reaches a line greater than `line`. If `line == nothing`
execute until the current frame reaches any line greater than the current line.
"""
function until_line!(interp::Interpreter, frame::Frame, line::Union{Nothing, Integer}=nothing, istoplevel::Bool=false)
    pc = frame.pc
    initialline, initialfile = linenumber(frame, pc), getfile(frame, pc)
    line === nothing && (line = initialline + 1)
    pc = next_until!(interp, frame, istoplevel) do frame::Frame
        return is_return(pc_expr(frame)) || (linenumber(frame) >= line && getfile(frame) == initialfile)
    end
    (pc === nothing || isa(pc, BreakpointRef)) && return pc
    maybe_step_through_kwprep!(interp, frame, istoplevel)
    maybe_next_call!(interp, frame, istoplevel)
end
until_line!(frame::Frame, line::Union{Nothing, Integer}=nothing, istoplevel::Bool=false) = until_line!(RecursiveInterpreter(), frame, line, istoplevel)

"""
    cframe = maybe_step_through_wrapper!(interp::Interpreter, frame::Frame)
    cframe = maybe_step_through_wrapper!(frame::Frame)

Return the new frame of execution, potentially stepping through "wrapper" methods like those
that supply default positional arguments or handle keywords. `cframe` is the leaf frame from
which execution should start.
"""
function maybe_step_through_wrapper!(interp::Interpreter, frame::Frame)
    code = frame.framecode
    src = code.src
    stmts, scope = src.code, code.scope::Method
    length(stmts) < 2 && return frame
    last = stmts[end-1]
    isexpr(last, :(=)) && (last = last.args[2])

    is_kw = false
    if isa(scope, Method)
        unwrap1 = Base.unwrap_unionall(scope.sig)
        if unwrap1 isa DataType
            param1 = Base.unwrap_unionall(unwrap1.parameters[1])
            if param1 isa DataType
                is_kw = param1.name.name === Symbol("#kwcall")
            end
        end
    end

    has_selfarg = isexpr(last, :call) && any(@nospecialize(x) -> isa(x, SlotNumber) && x.id == 1, last.args) # isequal(SlotNumber(1)) vulnerable to invalidation
    issplatcall, _callee = unpack_splatcall(last, src)
    if is_kw || has_selfarg || (issplatcall && is_bodyfunc(_callee))
        # If the last expr calls #self# or passes it to an implementation method,
        # this is a wrapper function that we might want to step through
        while frame.pc != length(stmts)-1
            pc = next_call!(interp, frame, false)  # since we're in a Method we're not at toplevel
            if pc === nothing || isa(pc, BreakpointRef)
                return frame
            end
        end
        ret = @invoke evaluate_call!(BreakOnCall()::Interpreter, frame::Frame, last::Expr)
        if !isa(ret, BreakpointRef) # Happens if next call is compiled
            return frame
        end
        frame.framedata.ssavalues[frame.pc] = Wrapper()
        return maybe_step_through_wrapper!(interp, callee(frame))
    end
    maybe_step_through_nkw_meta!(frame)
    return frame
end
maybe_step_through_wrapper!(frame::Frame) = maybe_step_through_wrapper!(RecursiveInterpreter(), frame)

const kwhandler = Core.kwcall
const kwextrastep = 0
const kw_has_f_first = VERSION.major == 1 && VERSION.minor == 11

"""
    frame = maybe_step_through_kwprep!(interp::Interpreter, frame::Frame)
    frame = maybe_step_through_kwprep!(frame::Frame)

If `frame.pc` points to the beginning of preparatory work for calling a keyword-argument
function, advance forward until the actual call.
"""
function maybe_step_through_kwprep!(interp::Interpreter, frame::Frame, istoplevel::Bool=false)
    # XXX This code just does pattern-matching based on the current state of the compiler
    # internals, which means this is very fragile against any future changes to those
    # internals. We really need a more general and robust solution, but achieving that
    # would mean simplifying and unifying how "keyword function" is represented and
    # implemented. For the time being, our best bet is to keep tweaking it as best as we can.
    pc, src = frame.pc, frame.framecode.src
    n = length(src.code)
    stmt = pc_expr(frame, pc)
    if isbindingresolved_deprecated && !isa(stmt, Tuple{Symbol,Vararg{Symbol}}) && !is_empty_namedtuple(stmt) && n >= pc+1
        pc += 1
        stmt = pc_expr(frame, pc)
    elseif kw_has_f_first && pc < n && is_empty_namedtuple(pc_expr(frame, pc+1)) && isa(stmt, QuoteNode)
        pc = step_expr!(interp, frame, istoplevel)
        stmt = pc_expr(frame, pc)
    end
    if isa(stmt, Tuple{Symbol,Vararg{Symbol}})
        # Check to see if we're creating a NamedTuple followed by kwfunc call
        pccall = pc + 4 + kwextrastep + isbindingresolved_deprecated
        if pccall <= n
            stmt1 = src.code[pc+1]
            # We deliberately check isexpr(stmt, :call) rather than is_call(stmt): if it's
            # assigned to a local, it's *not* kwarg preparation.
            if isexpr(stmt1, :call) && ((is_quotenode_egal(stmt1.args[1], Core.apply_type) && is_quoted_type(stmt1.args[2], :NamedTuple)) ||
                                        (is_global_ref(stmt1.args[1], Core, :apply_type) && is_global_ref(stmt1.args[2], Core, :NamedTuple)))
                stmt4, stmt5 = src.code[pc+4+isbindingresolved_deprecated], src.code[pc+5+isbindingresolved_deprecated]
                if isexpr(stmt4, :call) && (is_quotenode_egal(stmt4.args[1], kwhandler) || is_global_ref(stmt4.args[1], Core, :kwcall))
                    while pc < pccall
                        pc = step_expr!(interp, frame, istoplevel)
                    end
                    return frame
                elseif isexpr(stmt5, :call) && (is_quotenode_egal(stmt5.args[1], kwhandler) || is_global_ref(stmt5.args[1], Core, :kwcall)) && pccall+1 <= n
                    # This happens when the call is scoped by a module
                    pccall += 1
                    while pc < pccall
                        pc = step_expr!(interp, frame, istoplevel)
                    end
                    maybe_next_call!(interp, frame, istoplevel)
                    return frame
                end
            end
        end
    elseif is_empty_namedtuple(stmt)
        # Creating an empty NamedTuple, now split by type (no supplied kwargs vs kwargs...)
        if pc + 1 <= n
            stmt1 = src.code[pc+1]
            if isexpr(stmt1, :call)
                f = stmt1.args[1]
                if is_quotenode_egal(f, Base.pairs) || is_global_ref(f, Base, :pairs)
                    # No supplied kwargs
                    pcsplat = pc + 3
                    if pcsplat <= n
                        issplatcall, callee = unpack_splatcall(src.code[pcsplat], src)
                        if issplatcall && is_bodyfunc(callee)
                            while pc < pcsplat
                                pc = step_expr!(interp, frame, istoplevel)
                            end
                            return frame
                        end
                    end
                    pccall = pc + 2
                    if pccall <= n
                        stmt2 = src.code[pccall]
                        if isa(stmt2, Expr)
                            if stmt2.head === :call && length(stmt2.args) >= 3 && stmt2.args[2] === SSAValue(pc+1) && stmt2.args[3] === SlotNumber(1)
                                while pc < pccall
                                    pc = step_expr!(interp, frame, istoplevel)
                                end
                            end
                        end
                    end
                elseif (is_quotenode_egal(f, Base.merge) || is_global_ref(f, Base, :merge)) && ((pccall = pc + 7 + 2*isbindingresolved_deprecated) <= n)
                    stmtk = src.code[pccall-1]
                    if isexpr(stmtk, :call) && (is_quotenode_egal(stmtk.args[1], kwhandler) || is_global_ref(stmtk.args[1], Core, :kwcall))
                        for i = 1:4 + isbindingresolved_deprecated
                            pc = step_expr!(interp, frame, istoplevel)
                        end
                        stmti = src.code[pc]
                        if isexpr(stmti, :call) && (is_quotenode_egal(stmti.args[1], #= deliberately not kwhandler =# Core.kwfunc) || is_global_ref(stmti.args[1], Core, :kwfunc))
                            pc = step_expr!(interp, frame, istoplevel)
                        end
                    end
                end
            end
        end
    end
    return frame
end
maybe_step_through_kwprep!(frame::Frame, istoplevel::Bool=false) =
    maybe_step_through_kwprep!(RecursiveInterpreter(), frame, istoplevel)

@static if isbindingresolved_deprecated
    function is_empty_namedtuple(stmt)
        isexpr(stmt, :call) && length(stmt.args) == 1 || return false
        arg1 = stmt.args[1]
        isa(arg1, GlobalRef) || return false
        return arg1.name === :NamedTuple
    end
else
    is_empty_namedtuple(stmt) = isexpr(stmt, :call) && is_quoted_type(stmt.args[1], :NamedTuple) && length(stmt.args) == 1
end

"""
    ret = maybe_reset_frame!(interp::Interpreter, frame::Frame, pc, rootistoplevel::Bool)

Perform a return to the caller, or descend to the level of a breakpoint.
`pc` is the return state from the previous command (e.g., `next_call!` or similar).
`rootistoplevel` should be true if the root frame is top-level.

`ret` will be `nothing` if we have just completed a top-level frame. Otherwise,

    cframe, cpc = ret

where `cframe` is the frame from which execution should continue and `cpc` is the state
of `cframe` (the program counter, a `BreakpointRef`, or `nothing`).
"""
function maybe_reset_frame!(interp::Interpreter, frame::Frame, @nospecialize(pc), rootistoplevel::Bool)
    isa(pc, BreakpointRef) && return leaf(frame), pc
    if pc === nothing
        val = get_return(interp, frame)
        frame = return_from(frame)
        frame === nothing && return nothing
        ssavals = frame.framedata.ssavalues
        is_wrapper = isassigned(ssavals, frame.pc) && ssavals[frame.pc] === Wrapper()
        maybe_assign!(frame, val)
        frame.pc >= nstatements(frame.framecode) && return maybe_reset_frame!(interp, frame, nothing, rootistoplevel)
        frame.pc += 1
        if is_wrapper
            return maybe_reset_frame!(interp, frame, finish!(interp, frame), rootistoplevel)
        end
        pc = maybe_next_call!(interp, frame, rootistoplevel && frame.caller===nothing)
        return maybe_reset_frame!(interp, frame, pc, rootistoplevel)
    end
    return frame, pc
end
maybe_reset_frame!(frame::Frame, @nospecialize(pc), rootistoplevel::Bool) =
    maybe_reset_frame!(RecursiveInterpreter(), frame, pc, rootistoplevel)

# Unwind the stack until an exc is eventually caught, thereby
# returning the frame that caught the exception at the pc of the catch
# or rethrow the error
function unwind_exception(frame::Frame, @nospecialize(exc))
    while frame !== nothing
        if !isempty(frame.framedata.exception_frames)
            # Exception caught
            @assert is_leaf(frame)
            frame.pc = frame.framedata.exception_frames[end]
            frame.framedata.last_exception[] = exc
            return frame
        end
        frame = return_from(frame)
    end
    rethrow(exc)
end

function maybe_step_through_nkw_meta!(frame::Frame)
    stmt = pc_expr(frame)
    if stmt === nothing || (isexpr(stmt, :meta) && (stmt::Expr).args[1] === :nkw)
        @assert frame.pc == 1
        frame.pc += 1
    end
end

function more_calls_on_current_line(frame::Frame)
    _, curr_line = whereis(frame)
    curr_pc = frame.pc + 1
    while curr_pc <= length(frame.framecode.src.code)
        _, new_line = whereis(frame, curr_pc)
        new_line == curr_line || return false
        is_call(pc_expr(frame, curr_pc)) && return true
        curr_pc += 1
    end
    return false
end

"""
    ret = debug_command(interp::Interpreter, frame::Frame, cmd::Symbol, rootistoplevel::Bool=false;
                        line::Union{Nothing,Integer}=nothing)
    ret = debug_command(frame::Frame, cmd::Symbol, rootistoplevel::Bool=false; line=nothing)

Perform one "debugger" command. The keyword arguments are not used for all debug commands.
`cmd` should be one of:

- `:n`: advance to the next line
- `:s`: step into the next call
- `:sl` step into the last call on the current line (e.g. steps into `f` if the line is `f(g(h(x)))`).
- `:sr` step until the current function will return
- `:until`: advance the frame to line `line` if given, otherwise advance to the line after the current line
- `:c`: continue execution until termination or reaching a breakpoint
- `:finish`: finish the current frame and return to the parent

or one of the 'advanced' commands

- `:nc`: step forward to the next call
- `:se`: execute a single statement
- `:si`: execute a single statement, stepping in if it's a call
- `:sg`: step into the generator of a generated function

`rootistoplevel` and `ret` are as described for [`JuliaInterpreter.maybe_reset_frame!`](@ref).
"""
function debug_command(interp::Interpreter, frame::Frame, cmd::Symbol, rootistoplevel::Bool=false;
                       line::Union{Nothing,Integer}=nothing)
    function nicereturn!(interp::Interpreter, frame::Frame, @nospecialize(pc), rootistoplevel::Bool)
        if pc === nothing || isa(pc, BreakpointRef)
            return maybe_reset_frame!(interp, frame, pc, rootistoplevel)
        end
        maybe_step_through_kwprep!(interp, frame, rootistoplevel && frame.caller === nothing)
        return frame, frame.pc
    end

    istoplevel = rootistoplevel && frame.caller === nothing
    cmd0 = cmd
    is_si = false
    if cmd === :si
        stmt = pc_expr(frame)
        cmd = is_call(stmt) ? :s : :se
        is_si = true
    end
    try
        cmd === :nc && return nicereturn!(interp, frame, next_call!(interp, frame, istoplevel), rootistoplevel)
        cmd === :n && return maybe_reset_frame!(interp, frame, next_line!(interp, frame, istoplevel), rootistoplevel)
        cmd === :se && return maybe_reset_frame!(interp, frame, step_expr!(interp, frame, istoplevel), rootistoplevel)
        cmd === :until && return maybe_reset_frame!(interp, frame, until_line!(interp, frame, line, istoplevel), rootistoplevel)
        if cmd === :sl
            while more_calls_on_current_line(frame)
                next_call!(interp, frame, istoplevel)
            end
            return debug_command(interp, frame, :s, rootistoplevel; line)
        end
        if cmd === :sr
            maybe_next_until!(frame::Frame -> is_return(pc_expr(frame)), interp, frame, istoplevel)
            return frame, frame.pc
        end
        enter_generated = false
        if cmd === :sg
            enter_generated = true
            cmd = :s
        end
        if cmd === :s
            pc = maybe_next_call!(interp, frame, istoplevel)
            (isa(pc, BreakpointRef) || pc === nothing) && return maybe_reset_frame!(interp, frame, pc, rootistoplevel)
            is_si || maybe_step_through_kwprep!(interp, frame, istoplevel)
            pc = frame.pc
            stmt0 = stmt = pc_expr(frame, pc)
            is_return(stmt0) && return maybe_reset_frame!(interp, frame, nothing, rootistoplevel)
            if isexpr(stmt, :(=))
                stmt = stmt.args[2]
            end
            local ret
            try
                ret = @invoke evaluate_call!(BreakOnCall()::Interpreter, frame::Frame, stmt::Expr, enter_generated::Bool)
            catch err
                ret = handle_err(interp, frame, err)
                return isa(ret, BreakpointRef) ? (leaf(frame), ret) : ret
            end
            if isa(ret, BreakpointRef)
                newframe = leaf(frame)
                cmd0 === :si && return newframe, ret
                is_si || (newframe = maybe_step_through_wrapper!(interp, newframe))
                is_si || maybe_step_through_kwprep!(interp, newframe, istoplevel)
                return newframe, BreakpointRef(newframe.framecode, 0)
            end
            # if we got here, the call returned a value
            maybe_assign!(frame, stmt0, ret)
            frame.pc += 1
            return frame, frame.pc
        end
        if cmd === :c
            r = root(frame)
            ret = finish_stack!(interp, r, rootistoplevel)
            return isa(ret, BreakpointRef) ? (leaf(r), ret) : nothing
        end
        cmd === :finish && return maybe_reset_frame!(interp, frame, finish!(interp, frame, istoplevel), rootistoplevel)
    catch err
        frame = unwind_exception(frame, err)
        if cmd === :c
            return debug_command(interp, frame, :c, istoplevel)
        else
            return debug_command(interp, frame, :nc, istoplevel)
        end
    end
    throw(ArgumentError("command $cmd not recognized"))
end
debug_command(frame::Frame, cmd::Symbol, rootistoplevel::Bool=false; kwargs...) =
    debug_command(RecursiveInterpreter(), frame, cmd, rootistoplevel; kwargs...)
