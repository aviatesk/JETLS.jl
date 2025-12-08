"""
`framedict[method]` returns the `FrameCode` for `method`. For `@generated` methods,
see [`genframedict`](@ref).
"""
const framedict = Dict{Method,FrameCode}()                # essentially a method table for lowered code

"""
`genframedict[(method,argtypes)]` returns the `FrameCode` for a `@generated` method `method`,
for the particular argument types `argtypes`.

The framecodes stored in `genframedict` are for the code returned by the generator
(i.e, what will run when you call the method on particular argument types);
for the generator itself, its framecode would be stored in [`framedict`](@ref).
"""
const genframedict = Dict{Tuple{Method,Type},FrameCode}() # the same for @generated functions

"""
`meth ∈ compiled_methods` indicates that `meth` should be run using [`NonRecursiveInterpreter`](@ref)
rather than recursed into via the interpreter.
"""
const compiled_methods = Set{Method}()

"""
`meth ∈ interpreted_methods` indicates that `meth` should *not* be run using [`NonRecursiveInterpreter`](@ref)
and recursed into via the interpreter. This takes precedence over [`compiled_methods`](@ref) and
[`compiled_modules`](@ref).
"""
const interpreted_methods = Set{Method}()

"""
`mod ∈ compiled_modules` indicates that any method in `mod` should be run using [`NonRecursiveInterpreter`](@ref)
rather than recursed into via the interpreter.
"""
const compiled_modules = Set{Module}()

const junk_framedata = FrameData[] # to allow re-use of allocated memory (this is otherwise a bottleneck)
const junk_frames = Frame[]
debug_mode() = false
@noinline function _check_frame_not_in_junk(frame)
    @assert frame.framedata ∉ junk_framedata
    @assert frame ∉ junk_frames
end

@inline function recycle(frame)
    debug_mode() && _check_frame_not_in_junk(frame)
    push!(junk_framedata, frame.framedata)
    push!(junk_frames, frame)
end

function return_from(frame::Frame)
    oldframe = frame
    frame = caller(frame)
    recycle(oldframe)
    frame === nothing || (frame.callee = nothing)
    return frame
end

function clear_caches()
    empty!(junk_framedata)
    empty!(framedict)
    empty!(genframedict)
    empty!(junk_frames)
    for bp in breakpoints()
        empty!(bp.instances)
    end
end

const empty_svec = Core.svec()

function namedtuple(kwargs)
    names, types, vals = Symbol[], [], []
    for pr in kwargs
        if isa(pr, Expr)
            push!(names, pr.args[1])
            val = pr.args[2]
            push!(types, typeof(val))
            push!(vals, val)
        elseif isa(pr, Pair)
            push!(names, pr.first)
            val = pr.second
            push!(types, typeof(val))
            push!(vals, val)
        else
            error("unhandled entry type ", typeof(pr))
        end
    end
    return NamedTuple{(names...,), Tuple{types...}}(vals)
end

get_source(meth::Method) = Base.uncompressed_ast(meth)

function get_source(g::GeneratedFunctionStub, source::Method, env)
    b = @static if VERSION < v"1.12.0-DEV.1968"   # julia #57230
        g(Base.get_world_counter(), LineNumberNode(Int(source.line), source.file), env..., g.argnames...)
    else
        g(Base.get_world_counter(), source, env..., g.argnames...)
    end
    b isa CodeInfo && return b
    return eval(b)
end

"""
    frun, allargs = prepare_args(fcall, fargs, kwargs)

Prepare the complete argument sequence for a call to `fcall`. `fargs = [fcall, args...]` is a list
containing both `fcall` (the `#self#` slot in lowered code) and the positional
arguments supplied to `fcall`. `kwargs` is a list of keyword arguments, supplied either as
list of expressions `:(kwname=kwval)` or pairs `:kwname=>kwval`.

For non-keyword methods, `frun === fcall`, but for methods with keywords `frun` will be the
keyword-sorter function for `fcall`.

# Example

```jldoctest
julia> mymethod(x) = 1;

julia> mymethod(x, y; verbose=false) = nothing;

julia> JuliaInterpreter.prepare_args(mymethod, [mymethod, 15], ())
(mymethod, Any[mymethod, 15])

julia> JuliaInterpreter.prepare_args(mymethod, [mymethod, 1, 2], [:verbose=>true])
(Core.kwcall, Any[Core.kwcall, (verbose = true,), mymethod, 1, 2])
```
"""
function prepare_args(@nospecialize(f), allargs, kwargs)
    if !isempty(kwargs)
        f = Core.kwfunc(f)
        allargs = Any[f, namedtuple(kwargs), allargs...]
    end
    return f, allargs
end

function prepare_framecode(method::Method, @nospecialize(argtypes); enter_generated=false)
    sig = method.sig
    if (method.module ∈ compiled_modules || method ∈ compiled_methods) && !(method ∈ interpreted_methods)
        return Compiled()
    end
    # Get static parameters
    (ti, lenv::SimpleVector) = ccall(:jl_type_intersection_with_env, Any, (Any, Any),
                        argtypes, sig)::SimpleVector
    enter_generated &= is_generated(method)
    if is_generated(method) && !enter_generated
        framecode = get(genframedict, (method, argtypes::Type), nothing)
    else
        framecode = get(framedict, method, nothing)
    end
    if framecode === nothing
        if is_generated(method) && !enter_generated
            # If we're stepping into a staged function, we need to use
            # the specialization, rather than stepping through the
            # unspecialized method.
            code = get_staged(Core.Compiler.specialize_method(method, argtypes, lenv))
            code === nothing && return nothing
            generator = false
        else
            if is_generated(method)
                code = get_source(method.generator, method, lenv)
                generator = true
            else
                code = get_source(method)
                generator = false
            end
        end
        code = code::CodeInfo
        # Currenly, our strategy to deal with llvmcall can't handle parametric functions
        # (the "mini interpreter" runs in module scope, not method scope)
        if (!isempty(lenv) && (hasarg(isidentical(:llvmcall), code.code) ||
                               hasarg(isidentical(Core.Intrinsics.llvmcall), code.code) ||
                               hasarg(a->is_global_ref_egal(a, :llvmcall, Core.Intrinsics.llvmcall), code.code))) ||
                               hasarg(isidentical(:iolock_begin), code.code)
            return Compiled()
        end
        framecode = FrameCode(method, code; generator=generator)
        if is_generated(method) && !enter_generated
            genframedict[(method, argtypes)] = framecode
        else
            framedict[method] = framecode
        end
    end
    return framecode, lenv
end

function get_framecode(method)
    framecode = get(framedict, method, nothing)
    if framecode === nothing
        @assert !is_generated(method)
        code = get_source(method)
        framecode = FrameCode(method, code; generator=false)
        framedict[method] = framecode
    end
    return framecode
end

"""
    framecode, frameargs, lenv, argtypes = prepare_call(f, allargs; enter_generated=false)

Prepare all the information needed to execute lowered code for `f` given arguments `allargs`.
`f` and `allargs` are the outputs of [`prepare_args`](@ref).
For `@generated` methods, set `enter_generated=true` if you want to extract the lowered code
of the generator itself.

On return `framecode` is the [`FrameCode`](@ref) of the method.
`frameargs` contains the actual arguments needed for executing this frame (for generators,
this will be the types of `allargs`);
`lenv` is the "environment", i.e., the static parameters for `f` given `allargs`.
`argtypes` is the `Tuple`-type for this specific call (equivalent to the signature of the `MethodInstance`).

# Example

```jldoctest
julia> mymethod(x::Vector{T}) where T = 1;

julia> framecode, frameargs, lenv, argtypes = JuliaInterpreter.prepare_call(mymethod, [mymethod, [1.0,2.0]]);

julia> framecode
  1  1  1 ─     return 1

julia> frameargs
2-element Vector{Any}:
 mymethod (generic function with 1 method)
 [1.0, 2.0]

julia> lenv
svec(Float64)

julia> argtypes
Tuple{typeof(mymethod), Vector{Float64}}
```
"""
function prepare_call(@nospecialize(f), allargs;
                      enter_generated::Bool=false,
                      method_table::Union{Nothing,MethodTable}=nothing)
    # Can happen for thunks created by generated functions
    if isa(f, Core.Builtin) || isa(f, Core.IntrinsicFunction)
        return nothing
    elseif any(is_vararg_type, allargs)
        return nothing  # https://github.com/JuliaLang/julia/issues/30995
    end
    argtypesv = Any[_Typeof(a) for a in allargs]
    argtypes = Tuple{argtypesv...}
    if f isa Core.OpaqueClosure
        method = f.source
        # don't try to interpret optimized ir
        src = Base.uncompressed_ir(method)
        if hasfield(CodeInfo, :inferred) && src.inferred   # xref https://github.com/JuliaLang/julia/pull/53219
            @debug "not interpreting opaque closure $f since it contains inferred code"
            return nothing
        end
    else
        method = whichtt(argtypes, method_table)
    end
    if method === nothing
        # Call it to generate the exact error
        return f(allargs[2:end]...)
    end
    ret = prepare_framecode(method, argtypes; enter_generated)
    # Exceptional returns
    if ret === nothing
        # The generator threw an error. Let's generate the same error by calling it.
        return f(allargs[2:end]...)
    end
    isa(ret, Compiled) && return ret, argtypes
    # Typical return
    framecode, lenv = ret
    if is_generated(method) && enter_generated
        allargs = Any[_Typeof(a) for a in allargs]
    end
    return framecode, allargs, lenv, argtypes
end

function prepare_framedata(framecode, argvals::Vector{Any}, lenv::SimpleVector=empty_svec, caller_will_catch_err::Bool=false)
    src = framecode.src
    slotnames = src.slotnames
    ssavt = src.ssavaluetypes
    ng, ns = isa(ssavt, Int) ? ssavt : length(ssavt::Vector{Any}), length(src.slotflags)
    if length(junk_framedata) > 0
        olddata = pop!(junk_framedata)
        locals, ssavalues, sparams = olddata.locals, olddata.ssavalues, olddata.sparams
        exception_frames, current_scopes, last_reference = olddata.exception_frames, olddata.current_scopes, olddata.last_reference
        last_exception = olddata.last_exception
        callargs = olddata.callargs
        resize!(locals, ns)
        fill!(locals, nothing)
        resize!(ssavalues, 0)
        resize!(ssavalues, ng)
        # for check_isdefined to work properly, we need sparams to start out unassigned
        resize!(sparams, 0)
        empty!(exception_frames)
        empty!(current_scopes)
        resize!(last_reference, ns)
        last_exception[] = _INACTIVE_EXCEPTION.instance
    else
        locals = Vector{Union{Nothing,Some{Any}}}(nothing, ns)
        ssavalues = Vector{Any}(undef, ng)
        sparams = Vector{Any}(undef, 0)
        exception_frames = Int[]
        current_scopes = Scope[]
        last_reference = Vector{Int}(undef, ns)
        callargs = Any[]
        last_exception = Ref{Any}(_INACTIVE_EXCEPTION.instance)
    end
    fill!(last_reference, 0)
    if isa(framecode.scope, Method)
        meth = framecode.scope::Method
        nargs, meth_nargs = length(argvals), Int(meth.nargs)
        islastva = meth.isva && nargs >= meth_nargs
        for i = 1:meth_nargs-islastva
            # for OCs #self# actually refers to the captures instead
            if i == 1 && (oc = argvals[1]) isa Core.OpaqueClosure
                locals[i], last_reference[i] = Some{Any}(oc.captures), 1
            elseif i <= nargs
                locals[i], last_reference[i] = Some{Any}(argvals[i]), 1
            else
                locals[i] = Some{Any}(())
            end
        end
        if islastva
            locals[meth_nargs] =  (let i=meth_nargs; Some{Any}(ntupleany(k->argvals[i+k-1], nargs-i+1)); end)
            last_reference[meth_nargs] = 1
        end
    end
    resize!(sparams, length(lenv))
    # Add static parameters to environment
    for i = 1:length(lenv)
        T = lenv[i]
        isa(T, TypeVar) && continue  # only fill concrete types
        sparams[i] = T
    end
    return FrameData(locals, ssavalues, sparams, exception_frames, current_scopes,
                     last_exception, caller_will_catch_err, last_reference, callargs)
end

"""
    frame = prepare_frame(framecode::FrameCode, frameargs, lenv)

Construct a new `Frame` for `framecode`, given lowered-code arguments `frameargs` and
static parameters `lenv`. See [`JuliaInterpreter.prepare_call`](@ref) for information about how to prepare the inputs.
"""
function prepare_frame(framecode::FrameCode, args::Vector{Any}, lenv::SimpleVector, caller_will_catch_err::Bool=false)
    framedata = prepare_framedata(framecode, args, lenv, caller_will_catch_err)
    return Frame(framecode, framedata)
end

function prepare_frame_caller(caller::Frame, framecode::FrameCode, args::Vector{Any}, lenv::SimpleVector)
    caller_will_catch_err = !isempty(caller.framedata.exception_frames) || caller.framedata.caller_will_catch_err
    caller.callee = frame = prepare_frame(framecode, args, lenv, caller_will_catch_err)
    copy!(frame.framedata.current_scopes, caller.framedata.current_scopes)
    frame.caller = caller
    return frame
end

"""
    ExprSplitter(mod::Module, ex::Expr; lnn=nothing)

Given a module `mod` and a top-level expression `ex` in `mod`, create an iterable that returns
individual expressions together with their module of evaluation.
Optionally supply an initial `LineNumberNode` `lnn`.

# Example

In a fresh session,

```julia-repl
julia> expr = quote
           public_fn(x::Integer) = true
           module Private
           private(y::String) = false
           end
           const threshold = 0.1
       end;

julia> for (mod, ex) in ExprSplitter(Main, expr)
           @show mod ex
       end
mod = Main
ex = quote
    #= REPL[7]:2 =#
    public_fn(x::Integer) = begin
            #= REPL[7]:2 =#
            true
        end
end
mod = Main.Private
ex = quote
    #= REPL[7]:4 =#
    private(y::String) = begin
            #= REPL[7]:4 =#
            false
        end
end
mod = Main
ex = :($(Expr(:toplevel, :(#= REPL[7]:6 =#), :(const threshold = 0.1))))
```

`ExprSplitter` created `Main.Private` was created for you so that its internal expressions could be evaluated.
`ExprSplitter` will check to see whether the module already exists and if so return it rather than
try to create a new module with the same name.

In general each returned expression is a block with two parts: a `LineNumberNode` followed by a single expression.
In some cases the returned expression may be `:toplevel`, as shown in the `const` declaration,
but otherwise it will preserve its parent's `head` (e.g., `expr.head`).

# World age, frame creation, and evaluation

The primary purpose of `ExprSplitter` is to allow sequential return to top-level (e.g., the REPL)
after evaluation of each expression. Returning to top-level allows the world age to update, and hence allows one to call
methods and use types defined in earlier expressions in a block.

For evaluation by JuliaInterpreter, the returned module/expression pairs can be passed directly to
the `Frame` constructor. However, some expressions cannot be converted into `Frame`s and may need
special handling:

```julia-repl
julia> for (mod, ex) in ExprSplitter(Main, expr)
           if ex.head === :global
               # global declarations can't be lowered to a CodeInfo.
               # In this demo we choose to evaluate them, but you can do something else.
               Core.eval(mod, ex)
               continue
           end
           frame = Frame(mod, ex)
           debug_command(frame, :c, true)
       end

julia> threshold
0.1

julia> public_fn(3)
true
```

If you're parsing package code, `ex` might be a docstring-expression; you may wish
to check for such expressions and take distinct actions.

See [`Frame(mod::Module, ex::Expr)`](@ref) for more information about frame creation.
"""
mutable struct ExprSplitter
    # Non-mutating fields
    const stack::Vector{Tuple{Module,Expr}}   # mod[i] is module of evaluation for
    const index::Vector{Int}    # next-to-handle argument index for :block or :toplevel exprs
    # Mutating fields
    lnn::Union{LineNumberNode,Nothing}
end
function ExprSplitter(mod::Module, ex::Expr; lnn=nothing)
    iter = ExprSplitter(Tuple{Module,Expr}[], Int[], lnn)
    push_modex!(iter, mod, ex)
    queuenext!(iter)
    return iter
end

Base.IteratorSize(::Type{ExprSplitter}) = Base.SizeUnknown()
Base.eltype(::Type{ExprSplitter}) = Tuple{Module,Expr}

function push_modex!(iter::ExprSplitter, mod::Module, ex::Expr)
    push!(iter.stack, (mod, ex))
    if ex.head === :toplevel || ex.head === :block
        # Issue #427
        modifies_scope = false
        if ex.head === :block
            for a in ex.args
                if isa(a, Expr) && a.head === :local
                    modifies_scope = true
                    break
                end
            end
        end
        push!(iter.index, modifies_scope ? 0 : 1)
    end
    return iter
end

function pop_modex!(iter)
    mod, ex = pop!(iter.stack)
    if ex.head === :toplevel || ex.head === :block
        pop!(iter.index)
    end
    return mod, ex
end

# Load the next-to-evaluate expression into `iter.stack[end]`.
function queuenext!(iter::ExprSplitter)
    isempty(iter.stack) && return nothing
    mod, ex = iter.stack[end]
    head = ex.head
    if head === :module
        # Find or create the module
        newname = ex.args[2]::Symbol
        if invokelatest(isdefinedglobal, mod, newname)
            newmod = invokelatest(getglobal, mod, newname)
            newmod isa Module || throw(ErrorException("invalid redefinition of constant $(newname)"))
            mod = newmod
        else
            newnamestr = String(newname)
            id = Base.identify_package(mod, newnamestr)
            # If we're in a test environment and Julia's internal stdlibs are not a declared dependency of the package,
            # we might fail to find it. Try really hard to find it.
            if id === nothing && mod === Base.__toplevel__
                for loaded_id in keys(Base.loaded_modules)
                    if loaded_id.name == newnamestr
                        id = loaded_id
                        break
                    end
                end
            end
            if id !== nothing && haskey(Base.loaded_modules, id)
                mod = Base.root_module(id)::Module
            else
                loc = firstline(ex)
                mod = Core.eval(mod, Expr(:module, ex.args[1], newname, Expr(:block, loc)))::Module
            end
        end
        # We've handled the module declaration, remove it and queue the body
        pop!(iter.stack)
        ex = ex.args[3]::Expr
        push_modex!(iter, mod, ex)
        return queuenext!(iter)
    elseif head === :macrocall
        iter.lnn = ex.args[2]::LineNumberNode
    elseif head === :block || head === :toplevel
        # Container expression
        idx = iter.index[end]
        if idx == 0
            # return the whole block (issue #427)
            return nothing
        end
        while idx <= length(ex.args)
            a = ex.args[idx]
            if isa(a, LineNumberNode)
                iter.lnn = a
            elseif isa(a, Expr)
                iter.index[end] = idx + 1
                push_modex!(iter, mod, a)
                return queuenext!(iter)
            end
            idx += 1
        end
        # We exhausted the expression without returning anything to evaluate
        pop!(iter.stack)
        pop!(iter.index)
        return queuenext!(iter)
    end
    return nothing  # mod, ex will be returned by iterate
end

function Base.iterate(iter::ExprSplitter, state=nothing)
    isempty(iter.stack) && return nothing
    mod, ex = pop_modex!(iter)
    lnn = iter.lnn
    if is_doc_expr(ex)
        body = ex.args[4]
        if isa(body, Expr) && body.head === :module
            # Just document the module itself and push the module def onto the stack
            excopy = Expr(ex.head, ex.args[1], ex.args[2], ex.args[3])
            push!(excopy.args, body.args[2])
            append!(excopy.args, ex.args[5:end])   # there should only be at most a 5th, but just for robustness
            ex = excopy
            push_modex!(iter, mod, body)
        end
    end
    if ex.head === :block || ex.head === :toplevel
        # This was a block that we couldn't safely descend into (issue #427)
        if !isempty(iter.index) && iter.index[end] > length(iter.stack[end][2].args)
            pop!(iter.stack)
            pop!(iter.index)
            queuenext!(iter)
        end
        return (mod, ex), nothing
    end
    queuenext!(iter)
    # :global expressions can't be lowered. For debugging it might be nice
    # to still return the lnn, but then we have to work harder on detecting them.
    ex.head === :global && return (mod, ex), nothing
    return (mod, Expr(:block, lnn, ex)), nothing
end

"""
    framecode, frameargs, lenv, argtypes = determine_method_for_expr(expr; enter_generated = false)

Prepare all the information needed to execute a particular `:call` expression `expr`.
For example, try `JuliaInterpreter.determine_method_for_expr(:(\$sum([1,2])))`.
See [`JuliaInterpreter.prepare_call`](@ref) for information about the outputs.
"""
function determine_method_for_expr(expr::Expr;
                                   enter_generated::Bool=false,
                                   method_table::Union{Nothing,MethodTable}=nothing)
    f = to_function(expr.args[1])
    allargs = expr.args
    # Extract keyword args
    kwargs = Expr(:parameters)
    if length(allargs) > 1 && isexpr(allargs[2], :parameters)
        kwargs = splice!(allargs, 2)::Expr
    end
    f, allargs = prepare_args(f, allargs, kwargs.args)
    return prepare_call(f, allargs; enter_generated, method_table)
end

"""
    frame = enter_call_expr(expr; enter_generated=false)

Build a `Frame` ready to execute the expression `expr`. Set `enter_generated=true`
if you want to execute the generator of a `@generated` function, rather than the code that
would be created by the generator.

# Example

```jldoctest
julia> mymethod(x) = x+1;

julia> JuliaInterpreter.enter_call_expr(:(\$mymethod(1)))
Frame for mymethod(x) @ Main none:1
  1* 1  1 ─ %1 = x + 1
  2  1  └──      return %1
x = 1

julia> mymethod(x::Vector{T}) where T = 1;

julia> a = [1.0, 2.0]
2-element Vector{Float64}:
 1.0
 2.0

julia> JuliaInterpreter.enter_call_expr(:(\$mymethod(\$a)))
Frame for mymethod(x::Vector{T}) where T @ Main none:1
  1* 1  1 ─     return 1
x = [1.0, 2.0]
T = Float64
```

See [`enter_call`](@ref) for a similar approach not based on expressions.
"""
function enter_call_expr(expr::Expr;
                         enter_generated::Bool=false,
                         method_table::Union{Nothing,MethodTable}=nothing)
    clear_caches()
    r = determine_method_for_expr(expr; enter_generated, method_table)
    if r !== nothing && !isa(r[1], Compiled)
        return prepare_frame(Base.front(r)...)
    end
    nothing
end

"""
    frame = enter_call(f, args...; kwargs...)

Build a `Frame` ready to execute `f` with the specified positional and keyword arguments.

# Example

```jldoctest
julia> mymethod(x) = x+1;

julia> JuliaInterpreter.enter_call(mymethod, 1)
Frame for mymethod(x) @ Main none:1
  1* 1  1 ─ %1 = x + 1
  2  1  └──      return %1
x = 1

julia> mymethod(x::Vector{T}) where T = 1;

julia> JuliaInterpreter.enter_call(mymethod, [1.0, 2.0])
Frame for mymethod(x::Vector{T}) where T @ Main none:1
  1* 1  1 ─     return 1
x = [1.0, 2.0]
T = Float64
```

For a `@generated` function you can use `enter_call((f, true), args...; kwargs...)`
to execute the generator of a `@generated` function, rather than the code that
would be created by the generator.

See [`enter_call_expr`](@ref) for a similar approach based on expressions.
"""
function enter_call(@nospecialize(finfo), @nospecialize(args...);
                    method_table::Union{Nothing,MethodTable}=nothing,
                    kwargs...)
    clear_caches()
    if isa(finfo, Tuple)
        f = finfo[1]
        enter_generated = finfo[2]::Bool
    else
        f = finfo
        enter_generated = false
    end
    f, allargs = prepare_args(f, Any[f, args...], kwargs)
    # Can happen for thunks created by generated functions
    if isa(f, Core.Builtin) || isa(f, Core.IntrinsicFunction)
        error(f, " is a builtin or intrinsic")
    end
    r = prepare_call(f, allargs; enter_generated, method_table)
    if r !== nothing && !isa(r[1], Compiled)
        return prepare_frame(Base.front(r)...)
    end
    return nothing
end

# This is a version of InteractiveUtils.gen_call_with_extracted_types, except that is passes back the
# call expression for further processing.
function extract_args(__module__, ex0)
    if isa(ex0, Expr)
        if isexpr(ex0, :macrocall) # Make @edit @time 1+2 edit the macro by using the types of the *expressions*
            return error("Macros are not supported in @interpret")
        elseif any(@nospecialize(a)->(isexpr(a, :kw) || isexpr(a, :parameters)), ex0.args)
            arg1, args, kwargs = gensym("arg1"), gensym("args"), gensym("kwargs")
            return quote
                $arg1 = $(ex0.args[1])
                $args, $kwargs = $separate_kwargs($(ex0.args[2:end]...))
                tuple(Core.kwfunc($arg1), $kwargs, $arg1, $args...)
            end
        elseif ex0.head === :.
            return Expr(:tuple, :getproperty, ex0.args...)
        elseif ex0.head === :(<:)
            return Expr(:tuple, :(<:), ex0.args...)
        else
            return Expr(:tuple,
                mapany(x->isexpr(x,:parameters) ? QuoteNode(x) : x, ex0.args)...)
        end
    end
    ex = Meta.lower(__module__, ex0)
    if !isa(ex, Expr)
        return error("expression is not a function call or symbol")
    elseif ex.head === :call
        return Expr(:tuple,
            mapany(x->isexpr(x, :parameters) ? QuoteNode(x) : x, ex.args)...)
    elseif ex.head === :body
        a1 = ex.args[1]
        if isexpr(a1, :call)
            a11 = a1.args[1]
            if a11 === :setindex!
                return Expr(:tuple,
                    mapany(x->isexpr(x, :parameters) ? QuoteNode(x) : x, arg.args)...)
            end
        end
    end
    return error("expression is not a function call, "
               * "or is too complex for @interpret to analyze; "
               * "break it down to simpler parts if possible")
end

function interpret(mod::Module, @nospecialize(ex0); interp=RecursiveInterpreter())
    args = try
        extract_args(mod, ex0)
    catch e
        return :(throw($e))
    end
    quote
        local theargs = $(esc(args))
        local frame = JuliaInterpreter.enter_call_expr(Expr(:call, theargs...))
        if frame === nothing
            eval(Expr(:call, map(QuoteNode, theargs)...))
        elseif shouldbreak(frame, 1)
            frame, BreakpointRef(frame.framecode, 1)
        else
            local ret = finish_and_return!($interp, frame)
            # We deliberately return the top frame here; future debugging commands
            # via debug_command may alter the leaves, we want the top frame so we can
            # ultimately do `get_return`.
            isa(ret, BreakpointRef) ? (frame, ret) : ret
        end
    end
end

function interpret(mod::Module, opt, xs...; kwargs...)
    if isexpr(opt, :(=))
        optname, optval = opt.args
        optname isa Symbol || error("Invalid @interpret call: $optname is not a symbol")
        if optname === :interp
            return interpret(mod, xs...; interp=esc(optval), kwargs...)
        else
            error("Invalid @interpret call: $optname is not a recognized option")
        end
    else
        error("Invalid @interpret call: $opt is not a keyword")
    end
end

"""
    @interpret [interp] f(args; kwargs...)

Evaluate `f` on the specified arguments using the interpreter.

# Example

```jldoctest
julia> a = [1, 7];

julia> sum(a)
8

julia> @interpret sum(a)
8
```
"""
macro interpret(ex0, exs...)
    return interpret(__module__, ex0, exs...)
end
