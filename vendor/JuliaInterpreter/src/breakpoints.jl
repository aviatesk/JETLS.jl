using Base: Callable

const _breakpoints = AbstractBreakpoint[]

"""
    breakpoints()::Vector{AbstractBreakpoint}

Return an array with all breakpoints.
"""
breakpoints() = _breakpoints


const breakpoint_update_hooks = []
"""
    on_breakpoints_updated(f)

Register a two-argument function to be called after any update to the set of all
breakpoints. This includes their creation, deletion, enabling and disabling.

The function `f` should take two inputs:
 - First argument is the function doing to update, this is provided to allow to dispatch
   on its type. It will be one:
   -  `::typeof(breakpoint)` for the creation,
   -  `::typeof(remove)` for the deletion.
   -  `::typeof(update_states)` for disable/enable/toggleing
 - Second argument is the breakpoint object that was changed.

If only desiring to handle some kinds of update, `f` should have fallback methods
to do nothing in the general case.

!!! warning
    This feature is experimental, and may be modified or removed in a minor release.
"""
on_breakpoints_updated(f) = push!(breakpoint_update_hooks, f)


"""
    firehooks(hooked_fun, bp::AbstractBreakpoint)

Trigger all hooks that were registered with [`on_breakpoints_updated`](@ref),
passing them the `hooked_fun` and the `bp`.
This should be called whenever the set of breakpoints is updated.
`hooked_fun` is the function doing the update, and `bp` is the relevent breakpoint being
updated _after_ the update is applied.

!!! warning
    This feature is experimental, and may be modified or removed in a minor release.
"""
function firehooks(hooked_fun, bp::AbstractBreakpoint)
    for hook in breakpoint_update_hooks
        try
            hook(hooked_fun, bp)
        catch err
            @warn "Hook function errored" hook hooked_fun bp exception=err
        end
    end
end

function add_to_existing_framecodes(bp::AbstractBreakpoint)
    for framecode in values(framedict)
        add_breakpoint_if_match!(framecode, bp)
    end
end

function add_breakpoint_if_match!(framecode::FrameCode, bp::BreakpointSignature)
    if framecode_matches_breakpoint(framecode, bp)
        scope = framecode.scope
        matching_file = if scope isa Method
            scope.file
        else
            # TODO: make more precise?
            first(framecode.src.linetable).file
        end
        stmtidxs = bp.line === 0 ? [1] : statementnumbers(framecode, bp.line, matching_file::Symbol)
        stmtidxs === nothing && return
        breakpoint!(framecode, stmtidxs, bp.condition, bp.enabled[])
        foreach(stmtidx -> push!(bp.instances, BreakpointRef(framecode, stmtidx)), stmtidxs)
        return
    end
end

function framecode_matches_breakpoint(framecode::FrameCode, bp::BreakpointSignature)
    function extract_function_from_method(m::Method)
        sig = Base.unwrap_unionall(m.sig)
        ft0 = sig.parameters[1]
        ft = Base.unwrap_unionall(ft0)
        if ft <: Function && isa(ft, DataType) && isdefined(ft, :instance)
            return ft.instance
        elseif isa(ft, DataType) && ft.name === Type.body.name
            return ft.parameters[1]
        else
            return ft
        end
    end

    meth = framecode.scope
    meth isa Method || return false
    bp.f isa Method && return meth === bp.f
    f = extract_function_from_method(meth)
    if !(bp.f === f || (f === Core.kwcall && let ftype = Base.unwrap_unionall(meth.sig).parameters[3]
                !Base.has_free_typevars(ftype) && bp.f isa ftype
            end))
        return false
    end
    bp.sig === nothing && return true
    return bp.sig <: meth.sig
end

"""
    breakpoint(f, [sig], [line], [condition])

Add a breakpoint to `f` with the specified argument types `sig`.¨
If `sig` is not given, the breakpoint will apply to all methods of `f`.
If `f` is a method, the breakpoint will only apply to that method.
Optionally specify an absolute line number `line` in the source file; the default
is to break upon entry at the first line of the body.
Without `condition`, the breakpoint will be triggered every time it is encountered;
the second only if `condition` evaluates to `true`.
`condition` should be written in terms of the arguments and local variables of `f`.

# Example
```julia
function radius2(x, y)
    return x^2 + y^2
end

breakpoint(radius2, Tuple{Int,Int}, :(y > x))
```
"""
function breakpoint(f::Union{Method, Callable}, sig=nothing, line::Integer=0, condition::Condition=nothing)
    if sig !== nothing && f isa Callable
        sig = Base.to_tuple_type(sig)
        sig = Tuple{_Typeof(f), sig.parameters...}
    end
    bp = BreakpointSignature(f, sig, line, condition, Ref(true), BreakpointRef[])
    add_to_existing_framecodes(bp)
    idx = findfirst(bp2 -> same_location(bp, bp2), _breakpoints)
    if idx === nothing  # creating new
        push!(_breakpoints, bp)
    else  #Replace existing breakpoint
        old_bp = _breakpoints[idx]
        _breakpoints[idx] = bp
        firehooks(remove, old_bp)
    end
    firehooks(breakpoint, bp)
    return bp
end
breakpoint(f::Union{Method, Callable}, sig, condition::Condition) = breakpoint(f, sig, 0, condition)
breakpoint(f::Union{Method, Callable}, line::Integer, condition::Condition=nothing) = breakpoint(f, nothing, line, condition)
breakpoint(f::Union{Method, Callable}, condition::Condition) = breakpoint(f, nothing, 0, condition)


"""
    breakpoint(file, line, [condition])

Set a breakpoint in `file` at `line`. The argument `file` can be a filename, a partial path or absolute path.
For example, `file = foo.jl` will match against all files with the name `foo.jl`,
`file = src/foo.jl` will match against all paths containing `src/foo.jl`, e.g. both `Foo/src/foo.jl` and `Bar/src/foo.jl`.
Absolute paths only matches against the file with that exact absolute path.
"""
function breakpoint(file::AbstractString, line::Integer, condition::Condition=nothing)
    file = normpath(file)
    apath = CodeTracking.maybe_fix_path(abspath(file))
    ispath(apath) && (apath = realpath(apath))
    bp = BreakpointFileLocation(file, apath, line, condition, Ref(true), BreakpointRef[])
    add_to_existing_framecodes(bp)
    idx = findfirst(bp2 -> same_location(bp, bp2), _breakpoints)
    idx === nothing ? push!(_breakpoints, bp) : (_breakpoints[idx] = bp)
    firehooks(breakpoint, bp)
    return bp
end

function add_breakpoint_if_match!(framecode::FrameCode, bp::BreakpointFileLocation)
    framecode_contains_file = false
    matching_file = nothing
    for file in framecode.unique_files
        filepath = CodeTracking.maybe_fix_path(String(file))
        if Base.samefile(bp.abspath, filepath) || endswith(filepath, bp.path)
            framecode_contains_file = true
            matching_file = file
            break
        end
    end
    framecode_contains_file || return nothing

    stmtidxs = bp.line === 0 ? [1] : statementnumbers(framecode, bp.line, matching_file::Symbol)
    stmtidxs === nothing && return
    breakpoint!(framecode, stmtidxs, bp.condition, bp.enabled[])
    foreach(stmtidx -> push!(bp.instances, BreakpointRef(framecode, stmtidx)), stmtidxs)
    return
end

function shouldbreak(frame::Frame, pc::Int)
    bps = frame.framecode.breakpoints
    isassigned(bps, pc) || return false
    bp = bps[pc]
    bp.isactive || return false
    return invokelatest(bp.condition, frame)::Bool
end

function prepare_slotfunction(framecode::FrameCode, body::Union{Symbol,Expr})
    framename, dataname = gensym("frame"), gensym("data")
    assignments = Expr[:($dataname = $framename.framedata)]
    default = Unassigned()
    for slotname in unique(framecode.src.slotnames)
        list = framecode.slotnamelists[slotname]
        if length(list) == 1
            maxexpr = :($dataname.last_reference[$(list[1])] > 0 ? $(list[1]) : 0)
        else
            maxcounter, maxidx = gensym("maxcounter"), gensym("maxidx")
            maxexpr = quote
                begin
                    $maxcounter, $maxidx = 0, 0
                    for l in $list
                        counter = $dataname.last_reference[l]
                        if counter > $maxcounter
                            $maxcounter, $maxidx = counter, l
                        end
                    end
                    $maxidx
                end
            end
        end
        maxexsym = gensym("slotid")
        push!(assignments, :($maxexsym = $maxexpr))
        push!(assignments, :($slotname = $maxexsym > 0 ? something($dataname.locals[$maxexsym]) : $default))
    end
    scope = framecode.scope
    if isa(scope, Method)
        syms = sparam_syms(scope)
        for i = 1:length(syms)
            push!(assignments, Expr(:(=), syms[i], :($dataname.sparams[$i])))
        end
    end
    funcname = isa(scope, Method) ? gensym("slotfunction") : gensym(Symbol(scope, "_slotfunction"))
    return Expr(:function, Expr(:call, funcname, framename), Expr(:block, assignments..., body))
end

_unpack(condition) = isa(condition, Expr) ? (Main, condition) : condition

## The fundamental implementations of breakpoint-setting
function breakpoint!(framecode::FrameCode, pc, condition::Condition=nothing, enabled=true)
    stmtidx = pc
    if condition === nothing
        framecode.breakpoints[stmtidx] = BreakpointState(enabled)
    else
        mod, cond = _unpack(condition)
        fex = prepare_slotfunction(framecode, cond)
        framecode.breakpoints[stmtidx] = BreakpointState(enabled, Core.eval(mod, fex))
    end
end
breakpoint!(framecode::FrameCode, pcs::AbstractArray, condition::Condition=nothing, enabled=true) =
    foreach(pc -> breakpoint!(framecode, pc, condition, enabled), pcs)
breakpoint!(frame::Frame, pc=frame.pc, condition::Condition=nothing) =
    breakpoint!(frame.framecode, pc, condition)

function update_states!(bp::AbstractBreakpoint)
    foreach(bpref -> update_state!(bpref, bp.enabled[]), bp.instances)
    firehooks(update_states!, bp)
end
update_state!(bp::BreakpointRef, v::Bool) = bp[] = v

"""
    enable(bp::AbstractBreakpoint)

Enable breakpoint `bp`.
"""
enable(bp::AbstractBreakpoint) = (bp.enabled[] = true; update_states!(bp))
enable(bp::BreakpointRef) = update_state!(bp, true)


"""
    disable(bp::AbstractBreakpoint)

Disable breakpoint `bp`. Disabled breakpoints can be re-enabled with [`enable`](@ref).
"""
disable(bp::AbstractBreakpoint) = (bp.enabled[] = false; update_states!(bp))
disable(bp::BreakpointRef) = update_state!(bp, false)

"""
    remove(bp::AbstractBreakpoint)

Remove (delete) breakpoint `bp`. Removed breakpoints cannot be re-enabled.
"""
function remove(bp::AbstractBreakpoint)
    idx = findfirst(isequal(bp), _breakpoints)
    if idx !== nothing
        bp = _breakpoints[idx]
        deleteat!(_breakpoints, idx)
        firehooks(remove, bp)
    end
    foreach(remove, bp.instances)
end
function remove(bp::BreakpointRef)
    bp.framecode.breakpoints[bp.stmtidx] = BreakpointState(false, falsecondition)
    return nothing
end

"""
    toggle(bp::AbstractBreakpoint)

Toggle breakpoint `bp`.
"""
toggle(bp::AbstractBreakpoint) = (bp.enabled[] = !bp.enabled[]; update_states!(bp))
toggle(bp::BreakpointRef) = update_state!(bp, !bp[].isactive)

"""
    enable()

Enable all breakpoints.
"""
enable() = foreach(enable, _breakpoints)

"""
    disable()

Disable all breakpoints.
"""
disable() = foreach(disable, _breakpoints)

"""
    remove()

Remove all breakpoints.
"""
function remove()
    for bp in _breakpoints
        foreach(remove, bp.instances)
    end
    empty!(_breakpoints)
end

"""
    break_on(states...)

Turn on automatic breakpoints when any of the conditions described in `states` occurs.
The supported states are:

- `:error`: trigger a breakpoint any time an uncaught exception is thrown
- `:throw` : trigger a breakpoint any time a throw is executed (even if it will eventually be caught)
"""
function break_on(states::Vararg{Symbol})
    for state in states
        if state === :error
            break_on_error[] = true
        elseif state === :throw
            break_on_throw[] = true
        else
            throw(ArgumentError(string("unsupported state :", state)))
        end
    end
end

"""
    break_off(states...)

Turn off automatic breakpoints when any of the conditions described in `states` occurs.
See [`break_on`](@ref) for a description of valid states.
"""
function break_off(states::Vararg{Symbol})
    for state in states
        if state === :error
            break_on_error[] = false
        elseif state === :throw
            break_on_throw[] = false
        else
            throw(ArgumentError(string("unsupported state :", state)))
        end
    end
end


"""
    @breakpoint f(args...) condition=nothing
    @breakpoint f(args...) line condition=nothing

Break upon entry, or at the specified line number, in the method called by `f(args...)`.
Optionally supply a condition expressed in terms of the arguments and internal variables
of the method.
If `line` is supplied, it must be a literal integer.

# Example

Suppose a method `mysum` is defined as follows, where the numbers to the left are the line
number in the file:

```
12 function mysum(A)
13     s = zero(eltype(A))
14     for a in A
15         s += a
16     end
17     return s
18 end
```

Then

```
@breakpoint mysum(A) 15 s>10
```

would cause execution of the loop to break whenever `s>10`.
"""
macro breakpoint(call_expr, args...)
    whichexpr = InteractiveUtils.gen_call_with_extracted_types(__module__, :which, call_expr)
    haveline, line, condition = false, 0, nothing
    while !isempty(args)
        arg = first(args)
        if isa(arg, Integer)
            haveline, line = true, arg
        else
            condition = arg
        end
        args = Base.tail(args)
    end
    condexpr = condition === nothing ? nothing : esc(Expr(:quote, condition))
    if haveline
        return quote
            local method = $whichexpr
            $breakpoint(method, $line, $condexpr)
        end
    else
        return quote
            local method = $whichexpr
            $breakpoint(method, $condexpr)
        end
    end
end

struct BreakPointMarker end
const __BREAK_POINT_MARKER__ = BreakPointMarker()

"""
    @bp

Insert a breakpoint at a location in the source code.
"""
macro bp()
    return :(__BREAK_POINT_MARKER__)
end
