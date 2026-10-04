# The compiled wrapper methods built for `ccall`s, `llvmcall`s and `@cfunction`s, keyed by tuples
# of what each wrapper bakes in. Keys are compared with `===`, which compares the symbols,
# strings, types, `SimpleVector`s and modules of a signature by content, but the callable baked
# into a `@cfunction` wrapper by identity: a mutable callable that is `isequal` to another by
# value may still behave differently once mutated, so the two must not share a wrapper.
const compiled_calls = IdDict{Any,Any}()

# Record the binding partition of `gr` in `world_deps` (a `FrameCode.world_deps` vector under
# construction). Call this whenever a binding's *value* is resolved at framecode-build time and
# baked into the framecode (e.g. into a compiled `ccall` wrapper): the partition lets
# `framecode_valid_world` reject the framecode for worlds in which the binding was redefined.
# Pass `world_deps=nothing` at resolution sites that bake nothing (the value is only inspected,
# as in llvmcall detection or breakpoint-marker checks). Pre-1.12 a binding cannot be replaced
# in a way the world age tracks, so there is nothing to record.
function record_world_dep!(world_deps::Union{Nothing,Vector{BindingPartition}}, world::UInt, gr::GlobalRef)
    @static if isbindingresolved_deprecated
        world_deps === nothing && return nothing
        # KNOWN HOLE: only the named binding's partition is recorded. For an explicitly
        # imported binding (`import M: x` / `using M: x`) that partition delegates to the
        # source binding and survives a rebinding of the source const — only the source
        # partition (where the value lives) gets split. `lookup_global_ref` therefore never
        # folds such bindings, but the compiled `ccall`/`llvmcall` wrapper paths still bake
        # values reached through them and would miss the rebinding (see the
        # "imported const invalidation" `@test_broken`). Whether importer partitions should
        # be split upstream, or the delegation chain recorded here, is under discussion.
        record_world_dep!(world_deps, Base.lookup_binding_partition(world, gr))
    end
    return nothing
end

@static if isbindingresolved_deprecated
function record_world_dep!(world_deps::Union{Nothing,Vector{BindingPartition}}, bpart::BindingPartition)
    world_deps === nothing && return nothing
    # The same binding is typically referenced many times within one method; store each
    # partition once so `framecode_valid_world` stays cheap.
    any(p -> p === bpart, world_deps) || push!(world_deps, bpart)
    return nothing
end
end

# Record every `GlobalRef` reachable in `arg` (recursing through `Expr`s, but not chasing
# `SSAValue`s). Used when a whole expression's value is baked at framecode-build time, e.g. a
# `(name, lib)` tuple evaluated for a compiled `ccall` wrapper or the feeder statements of an
# `llvmcall`. Over-recording is safe: a spurious entry only forces a rebuild, never staleness.
function record_globalref_deps!(world_deps::Union{Nothing,Vector{BindingPartition}}, world::UInt, @nospecialize(arg))
    if isa(arg, GlobalRef)
        record_world_dep!(world_deps, world, arg)
    elseif isa(arg, Expr)
        for a in arg.args
            record_globalref_deps!(world_deps, world, a)
        end
    end
    return nothing
end

# Pre-frame-construction lookup. When the result is baked into the framecode, pass `world_deps`
# so the resolved bindings are recorded (see `record_world_dep!`).
function lookup_stmt(stmts::Vector{Any}, @nospecialize(arg), world::UInt,
                     world_deps::Union{Nothing,Vector{BindingPartition}}=nothing)
    # this converts a statement into something else, without the slightest interest in correctness:
    if isa(arg, SSAValue)
        arg = stmts[arg.id]
    end
    if isa(arg, QuoteNode)
        return arg.value
    elseif isexpr(arg, :call, 3) && is_global_ref(arg.args[1], Base, :getproperty)
        # Starting with Julia 1.12, llvmcall looks like this:
        # julia> src.code[1:3]
        # 3-element Vector{Any}:
        #  :(TheModule.Core)                          # GlobalRef
        #  :(Base.getproperty(%1, :Intrinsics))
        #  :(Base.getproperty(%2, :llvmcall))
        q = arg.args[3]
        if isa(q, QuoteNode) && (qval = q.value; qval isa Symbol)
            mod = lookup_stmt(stmts, arg.args[2], world, world_deps)
            if isa(mod, GlobalRef)
                if invoke_in_world(world, isdefinedglobal, mod.mod, mod.name)
                    record_world_dep!(world_deps, world, mod)
                    mod = invoke_in_world(world, getglobal, mod.mod, mod.name)
                end
            end
            if isa(mod, Module)
                if invoke_in_world(world, isdefinedglobal, mod, qval)
                    record_world_dep!(world_deps, world, GlobalRef(mod, qval))
                    return invoke_in_world(world, getglobal, mod, qval)
                end
            end
        end
    end
    return arg
end

function smallest_ref(stmts, arg, idmin)
    if isa(arg, SSAValue)
        idmin = min(idmin, arg.id)
        return smallest_ref(stmts, stmts[arg.id], idmin)
    elseif isa(arg, Expr)
        for a in arg.args
            idmin = smallest_ref(stmts, a, idmin)
        end
    end
    return idmin
end

function lookup_global_ref(a::GlobalRef, world::UInt,
                           world_deps::Union{Nothing,Vector{BindingPartition}}=nothing)
    @static if isbindingresolved_deprecated
        # On 1.12+ a `const` can be rebound, making the folded value world-dependent. Folding
        # is therefore allowed only when the caller supplies `world_deps`: the binding
        # partition recorded there lets `framecode_valid_world` reject the cached framecode
        # for worlds in which the binding was redefined.
        world_deps === nothing && return a
        bpart = Base.lookup_binding_partition(world, a)
        # Fold only when the partition itself holds the constant value (a directly defined
        # or implicit-`using` const): then this partition must be split for the value to
        # change, so recording it makes the invalidation exact. Explicitly imported bindings
        # (`import M: x` / `using M: x`) delegate to the source binding and their partition
        # survives a rebinding of the source const, so a folded value could go stale
        # undetected — leave those as `GlobalRef`s (resolved per execution in the frame's
        # world, which is always correct).
        if Base.is_defined_const_binding(Base.binding_kind(bpart))
            record_world_dep!(world_deps, bpart)
            return QuoteNode(invoke_in_world(world, getglobal, a.mod, a.name))
        end
        return a
    else
        if Base.isbindingresolved(a.mod, a.name) &&
            (invoke_in_world(world, isdefinedglobal, a.mod, a.name)) &&
            (invoke_in_world(world, isconst, a.mod, a.name))
            return QuoteNode(invoke_in_world(world, getglobal, a.mod, a.name))
        end
        return a
    end
end

function lookup_global_refs!(ex::Expr, world::UInt,
                             world_deps::Union{Nothing,Vector{BindingPartition}}=nothing)
    if isexpr(ex, (:isdefined, :thunk, :toplevel, :method, :global, :const, :globaldecl))
        return nothing
    end
    for (i, a) in enumerate(ex.args)
        ex.head === :(=) && i == 1 && continue # Don't look up globalrefs on the LHS of an assignment (issue #98)
        if isa(a, GlobalRef)
            ex.args[i] = lookup_global_ref(a, world, world_deps)
        elseif isa(a, Expr)
            lookup_global_refs!(a, world, world_deps)
        end
    end
    return nothing
end

function lookup_getproperties(code::Vector{Any}, @nospecialize(a), world::UInt,
                              world_deps::Union{Nothing,Vector{BindingPartition}}=nothing)
    isexpr(a, :call) || return a
    length(a.args) == 3 || return a
    arg1 = lookup_stmt(code, a.args[1], world)
    arg1 === Base.getproperty || return a
    arg2 = lookup_stmt(code, a.args[2], world)
    arg2 isa Module || return a
    arg3 = lookup_stmt(code, a.args[3], world)
    arg3 isa Symbol || return a
    return lookup_global_ref(GlobalRef(arg2, arg3), world, world_deps)
end

# `FrameCode` transforms the lowered code in two steps: `compile_llvmcalls!` and
# `expose_eval_call!` determine what gets interpreted, whereas `optimize!` only speeds up its
# interpretation and is skipped for `optimize=false`. All of them rewrite statements in place, so
# statement indices are preserved.
# On Julia 1.12+ a redefinable `const` makes a value resolved at build time world-dependent, so
# every such value — folded `const` globals as well as library names and llvmcall ingredients
# baked into compiled wrappers — records its binding in `world_deps`, and `framecode_valid_world`
# rejects the cached framecode once any of them is redefined.

# Replace each `llvmcall` in `code` with a call to a compiled wrapper method, marked `Compiled()`
# in `methodtables`. An `llvmcall` cannot be called dynamically ("`llvmcall` requires the
# compiler"), so unlike `optimize!` this is required to interpret `code` at all, and `FrameCode`
# applies it regardless of its `optimize` keyword.
#
# Only methods without static parameters are handled: `prepare_framecode` executes a method with
# static parameters that contains an `llvmcall` natively instead, and a top-level `llvmcall` is not
# supported. The binding partitions of globals whose values get baked into a wrapper are recorded
# in `world_deps` (see `record_world_dep!`).
function compile_llvmcalls!(code::CodeInfo, methodtables::Vector{Union{Compiled,DispatchableMethod}},
                            world_deps::Vector{BindingPartition}, scope, world::UInt)
    # `build_compiled_llvmcall!` evaluates the ingredients of an `llvmcall` with a mini-interpreter
    # that runs in module scope, so it cannot resolve static parameters
    (scope isa Method && isempty(sparam_syms(scope))) || return nothing
    evalmod = moduleof(scope) == Core.Compiler ? Core.Compiler : CompiledCalls
    for idx = 1:length(code.code)
        stmt = code.code[idx]
        if isexpr(stmt, :(=))
            stmt = stmt.args[2]
        end
        isexpr(stmt, :call) || continue
        arg1 = stmt.args[1]
        larg1 = lookup_stmt(code.code, arg1, world)
        if arg1 === :llvmcall || larg1 === Base.llvmcall || is_global_ref_egal(larg1, :llvmcall, Core.Intrinsics.llvmcall, world)
            # Call via `invokelatest` to avoid compiling it until we need it
            @invokelatest build_compiled_llvmcall!(stmt, code, idx, evalmod, world, world_deps)
            methodtables[idx] = Compiled()
        end
    end
    return nothing
end

# In the method of `Core.eval`, replace the `ccall` that evaluates the expression with a call to
# `eval_in_frame`. As an ordinary call, it gets interpreted by `RecursiveInterpreter` (see
# `evaluate_eval!`), and debugger commands can step into or over it, including when `Core.eval`
# is the entry frame or invoked directly. Left as a `:foreigncall`, the expression would be
# evaluated natively, so unlike `optimize!` this is applied regardless of `optimize`.
function expose_eval_call!(code::CodeInfo, scope)
    is_core_eval(scope) || return nothing
    for stmt in code.code
        if isexpr(stmt, :(=))
            stmt = stmt.args[2]
        end
        if isexpr(stmt, :foreigncall)
            stmt.head = :call
            stmt.args = Any[eval_in_frame, stmt.args[6], stmt.args[7]]
        end
    end
    return nothing
end

"""
    optimize!(code::CodeInfo, methodtables, world_deps, scope, world::UInt)

Perform optimizations on the lowered code `code` that reduce the execution time of the
interpreter. None of them is needed to interpret `code` (see `compile_llvmcalls!` for
the transformation that is), and `FrameCode` skips them when passed `optimize=false`:

- `const` globals, including ones accessed as `getproperty(mod, :name)`, are replaced by
  `QuoteNode`s of their values. On Julia 1.12+ this is done for method scope only.
- `ccall`s and `@cfunction`s are replaced with calls to compiled wrapper methods, marked
  `Compiled()` in `methodtables`. A statement left as is gets evaluated by
  `evaluate_foreigncall` with `Core.eval`, which compiles it anew each time it runs.

`scope` is the `Method` or `Module` in which `code` runs. The binding partitions of globals whose
values get baked into `code` are recorded in `world_deps` (see `record_world_dep!`).
"""
function optimize!(code::CodeInfo, methodtables::Vector{Union{Compiled,DispatchableMethod}},
                   world_deps::Vector{BindingPartition}, scope, world::UInt)
    mod = moduleof(scope)
    evalmod = mod == Core.Compiler ? Core.Compiler : CompiledCalls
    sparams = scope isa Method ? sparam_syms(scope) : Symbol[]

    # On 1.12+, fold `const` globals only for method scope: the framecode cache is guarded by
    # `framecode_valid_world`, and a method frame's world is fixed at construction. Toplevel
    # frames advance `frame.world` mid-execution (see `step_toplevel!`), so a value folded in
    # the build world could go stale within the frame; leave their `GlobalRef`s unresolved.
    fold_deps = scope isa Method ? world_deps : nothing
    # TODO: because of builtins.jl, for CodeInfos like
    #   %1 = Core.apply_type
    #   %2 = (%1)(args...)
    # it would be best to *not* resolve the GlobalRef at %1
    ## Replace GlobalRefs with QuoteNodes
    for (i, stmt) in enumerate(code.code)
        if isa(stmt, GlobalRef)
            code.code[i] = lookup_global_ref(stmt, world, fold_deps)
        elseif isa(stmt, Expr)
            if stmt.head === :call && stmt.args[1] === :cglobal  # cglobal requires literals
                continue
            else
                lookup_global_refs!(stmt, world, fold_deps)
                code.code[i] = lookup_getproperties(code.code, stmt, world, fold_deps)
            end
        end
    end

    # Replace :foreigncall and :cfunction with compiled variants. See
    # https://github.com/JuliaDebug/JuliaInterpreter.jl/issues/13#issuecomment-464880123
    scopemod = scope isa Module ? scope : nothing
    for (idx, stmt) in enumerate(code.code)
        # Foregincalls can be rhs of assignments
        if isexpr(stmt, :(=))
            stmt = (stmt::Expr).args[2]
        end
        if isa(stmt, Expr)
            if stmt.head === :foreigncall
                # Call via `invokelatest` to avoid compiling it until we need it
                if @invokelatest build_compiled_foreigncall!(stmt, code, sparams, evalmod, world, world_deps, scopemod)
                    methodtables[idx] = Compiled()
                end
            elseif stmt.head === :cfunction
                if @invokelatest build_compiled_cfunction!(stmt, mod, evalmod)
                    methodtables[idx] = Compiled()
                end
            end
        end
    end

    return nothing
end

# Convert the type `t` into an expression that reproduces it when evaluated in a scope where
# each free `TypeVar` of `t` is bound under its name, e.g. as a static parameter of a compiled
# wrapper method (see `build_compiled_foreigncall!`). A `t` without free `TypeVar`s is returned
# as it is, so that it gets embedded into the wrapper as a value.
#
# The expression applies `t`, wrapped into a `UnionAll` over its free `TypeVar`s, to the names
# of those `TypeVar`s, i.e. `(t where {T1, T2, ...}){T1, T2, ...}`. This substitutes the
# `TypeVar`s by identity and so is oblivious to the structure of `t`: nested `UnionAll`s such as
# `Array{T}` (i.e. `Array{T,N} where N`), `Union`s and `Vararg`s need no special treatment.
# In particular no `where` expression is needed, which the type positions of a `:foreigncall`
# could not hold anyway since they are not lowered to SSA form.
function parametric_type_to_expr(@nospecialize(t))
    Base.has_free_typevars(t) || return t
    tvs = free_typevars!(TypeVar[], t)
    wrapped = t
    for tv in Iterators.reverse(tvs)
        wrapped = UnionAll(tv, wrapped)
    end
    return Expr(:curly, wrapped, Symbol[tv.name for tv in tvs]...)
end

# Collect the free `TypeVar`s of `t` into `tvs`, in order of first occurrence.
function free_typevars!(tvs::Vector{TypeVar}, @nospecialize(t), bound::Vector{TypeVar}=TypeVar[])
    Base.has_free_typevars(t) || return tvs
    if t isa TypeVar
        (t in bound || t in tvs) || push!(tvs, t)
    elseif t isa UnionAll
        free_typevars!(tvs, t.var.lb, bound)
        free_typevars!(tvs, t.var.ub, bound)
        push!(bound, t.var)
        free_typevars!(tvs, t.body, bound)
        pop!(bound)
    elseif t isa Union
        free_typevars!(tvs, t.a, bound)
        free_typevars!(tvs, t.b, bound)
    elseif t isa Core.TypeofVararg
        isdefined(t, :T) && free_typevars!(tvs, t.T, bound)
        isdefined(t, :N) && free_typevars!(tvs, t.N, bound)
    elseif t isa DataType
        for p in t.parameters
            free_typevars!(tvs, p, bound)
        end
    end
    return tvs
end

function build_compiled_llvmcall!(stmt::Expr, code::CodeInfo, idx::Int, evalmod::Module, world::UInt,
                                  world_deps::Union{Nothing,Vector{BindingPartition}}=nothing)
    # Run a mini-interpreter to extract the types
    framecode = FrameCode(CompiledCalls, code; optimize=false, world)
    frame = Frame(framecode, prepare_framedata(framecode, []), 1, nothing, world)
    idxstart = idx
    for i = 2:4
        idxstart = smallest_ref(code.code, stmt.args[i], idxstart)
    end
    # The mini-interpreter resolves any globals among the feeder statements, and their values are
    # baked into the compiled wrapper below; record them so the framecode can be invalidated.
    for i = idxstart:idx-1
        record_globalref_deps!(world_deps, world, code.code[i])
    end
    for i = 2:4
        record_globalref_deps!(world_deps, world, stmt.args[i])
    end
    frame.pc = idxstart
    if idxstart < idx
        while true
            pc = step_expr!(NonRecursiveInterpreter(), frame)
            pc === idx && break
            pc === nothing && error("this should never happen")
        end
    end
    llvmir, RetType, ArgType = lookup(frame, stmt.args[2]), lookup(frame, stmt.args[3]), lookup(frame, stmt.args[4])::DataType
    args = stmt.args[5:end]
    argnames = Any[Symbol(:arg, i) for i = 1:length(args)]
    cc_key = (llvmir, RetType, ArgType, evalmod)  # compiled call key
    f = get(compiled_calls, cc_key, nothing)
    if f === nothing
        methname = gensym("compiled_llvmcall")
        def = :(
            function $methname($(argnames...))
                return $(Base.llvmcall)($llvmir, $RetType, $ArgType, $(argnames...))
            end)
        f = Core.eval(evalmod, def)
        compiled_calls[cc_key] = f
    end

    stmt.args[1] = QuoteNode(f)
    stmt.head = :call
    deleteat!(stmt.args, 2:length(stmt.args))
    append!(stmt.args, args)
end

# Resolve a type position of a `:foreigncall`/`:cfunction` statement. In method scope lowering
# has already evaluated it; toplevel lowering leaves it as an expression over globals, which is
# evaluated in the statement's module `scopemod`, as `resolve_globals` (method.c) does right
# before Julia runs such a thunk. Returns `nothing` if it cannot be evaluated (e.g. an earlier
# statement of the same thunk has yet to define a binding it refers to).
function resolve_ccall_type(@nospecialize(t), scopemod::Union{Nothing,Module})
    (isa(t, Type) || isa(t, SimpleVector)) && return t
    isa(t, QuoteNode) && return t.value
    scopemod === nothing && return nothing
    (isa(t, Symbol) || isa(t, GlobalRef) || isa(t, Expr)) || return nothing
    return try Core.eval(scopemod, t) catch; nothing end
end

# The `name`, `(name,)` and `(name, lib)` values a compiled wrapper can embed as a constant
# `ccall` target
is_ccall_target(@nospecialize(x)) =
    isa(x, Union{Symbol,String}) || isa(x, Tuple{Union{Symbol,String}}) ||
    isa(x, Tuple{Union{Symbol,String},Union{Symbol,String}})

# The value of a toplevel statement's `(name, lib)` target expression if the expression is
# constant, i.e. built from literals and `const` globals only, which native code resolves
# statically as well; `nothing` otherwise. A library named by a non-`const` global is looked up
# by native code when the call runs, and an earlier statement of the same thunk may still assign
# it, which no shared wrapper can reproduce (a compiled call site caches the library it first
# resolved), so such a target is left to `evaluate_foreigncall`.
function constant_target_value(ex::Expr, mod::Module)
    is_constant_target(ex, mod) || return nothing
    v = try Core.eval(mod, ex) catch _; nothing; end
    return is_ccall_target(v) ? v : nothing
end

function is_constant_target(@nospecialize(x), mod::Module)
    if isa(x, QuoteNode) || isa(x, String)
        return true
    elseif isa(x, Symbol)
        return is_const_global(mod, x)
    elseif isa(x, GlobalRef)
        return is_const_global(x.mod, x.name)
    elseif (isexpr(x, :., 2) || is_getproperty_call(x)) && isa(x.args[end], QuoteNode)
        # a qualified name such as `Base.Math.libm`, which Julia < 1.13 spells as `getproperty` calls
        modex = x.args[end-1]
        is_constant_target(modex, mod) || return false
        m = try Core.eval(mod, modex) catch _; return false; end
        return isa(m, Module) && is_const_global(m, (x.args[end]::QuoteNode).value)
    elseif isexpr(x, :tuple)
        return all(@nospecialize(a) -> is_constant_target(a, mod), x.args)
    elseif is_core_tuple_call(x)
        return all(@nospecialize(a) -> is_constant_target(a, mod), @view x.args[2:end])
    end
    return false
end

is_const_global(mod::Module, @nospecialize name) =
    isa(name, Symbol) && isdefinedglobal(mod, name) && isconst(mod, name)

# Handle :llvmcall & :foreigncall (issue #28)
# Replace `stmt` in place with a `:call` to a compiled wrapper method and return `true`, or leave
# it untouched and return `false` if no wrapper can be built for it. `scopemod` is the module of a
# toplevel statement, whose target and types are still unresolved; it is `nothing` in method scope.
function build_compiled_foreigncall!(stmt::Expr, code::CodeInfo, sparams::Vector{Symbol}, evalmod::Module, world::UInt,
                                     world_deps::Union{Nothing,Vector{BindingPartition}}=nothing,
                                     scopemod::Union{Nothing,Module}=nothing)
    TVal = evalmod == Core.Compiler ? Core.Compiler.Val : Val
    RetType = resolve_ccall_type(stmt.args[2], scopemod)
    ArgType = resolve_ccall_type(stmt.args[3], scopemod)
    (RetType === nothing || !isa(ArgType, SimpleVector)) && return false

    dynamic_ccall = false
    argcfunc = cfunc = stmt.args[1]
    cfunc_resolved = nothing
    if @isdefined(__has_internal_change) && __has_internal_change(v"1.13.0", :syntacticccall)
        if isa(cfunc, String) || (isa(cfunc, QuoteNode) && is_ccall_target(cfunc.value))
            # a literal `"name"` or quoted `:name` target, as toplevel lowering spells `ccall(:name, ...)`
            cfunc_resolved = isa(cfunc, String) ? cfunc : (cfunc::QuoteNode).value
        elseif !isexpr(cfunc, :tuple)
            dynamic_ccall = true
            cfunc = gensym("ptr")
        elseif scopemod !== nothing
            # A toplevel statement's `(name, lib)` tuple is embedded by value if it is constant
            # (see `constant_target_value`). The framecode is built right before it runs and is
            # not cached, so there is no invalidation to record.
            cfunc_resolved = @something constant_target_value(cfunc, scopemod) return false
            cfunc = QuoteNode(cfunc_resolved)
        else
            # The `(name, lib)` tuple expression is baked into the compiled wrapper, so the
            # library binding it references is resolved at framecode-build time: record it.
            # The wrapper body keeps the symbolic tuple, but its resolved value is folded into
            # the cache key (below) so that rebinding the library const builds a fresh wrapper
            # that rebakes the current value rather than reusing the stale one.
            record_globalref_deps!(world_deps, world, cfunc)
            cfunc_resolved = try Core.eval(evalmod, cfunc) catch _; nothing; end
        end
    else
        while isa(cfunc, SSAValue)
            cfunc = lookup_stmt(code.code, cfunc, world, world_deps)
            cfunc isa Symbol && (cfunc = QuoteNode(cfunc))
        end
        # n.b. Base.memhash is deprecated (continued use would cause serious faults) in the same version as the syntax is deprecated
        # so this is only needed as a legacy hack
        if scopemod !== nothing && isa(cfunc, Expr)
            # A toplevel statement's `(name, lib)` tuple is embedded by value if it is constant,
            # as in the `:syntacticccall` branch above; any other expression is a runtime pointer.
            if is_core_tuple_call(cfunc)
                cfunc_resolved = @something constant_target_value(cfunc, scopemod) return false
                cfunc = QuoteNode(cfunc_resolved)
            end
        elseif isa(cfunc, Expr) || (cfunc isa GlobalRef && cfunc == GlobalRef(Base, :memhash))
            evaluated = try QuoteNode(Core.eval(evalmod, cfunc)) catch _; nothing; end
            if evaluated !== nothing
                # The expression's value (e.g. a `(name, lib)` tuple) is baked into the compiled
                # wrapper; record the bindings it resolved.
                record_globalref_deps!(world_deps, world, cfunc)
                cfunc = evaluated
            end
        end
        if !(isa(cfunc, Union{String, Tuple}) || (isa(cfunc, QuoteNode) && isa(cfunc.value, Union{String, Tuple, Symbol})))
            dynamic_ccall = true
            cfunc = gensym("ptr")
        end
    end

    if isa(RetType, SimpleVector)
        @assert length(RetType) == 1
        RetType = RetType[1]
    end
    args = stmt.args[6:end]
    # When the ccall is dynamic we pass the pointer as an argument so can reuse the function
    # `stmt.args[4]` (nreq) and `stmt.args[5]` (calling convention, including e.g. the
    # `gc_safe` flag) are baked into the wrapper body, so they must be part of the key:
    # otherwise two ccalls to the same function differing only in those would share
    # whichever wrapper was built first.
    cc_key = ((dynamic_ccall ? :ptr : @something(cfunc_resolved, cfunc)), RetType, ArgType,
              evalmod, length(sparams), length(args), stmt.args[4], stmt.args[5])  # compiled call key
    f = get(compiled_calls, cc_key, nothing)
    if f === nothing
        argtypes = Any[parametric_type_to_expr(t) for t in ArgType::SimpleVector]
        # `wrap_params` binds free parameters with `where`, which requires a type body,
        # not a tuple of type values.
        ArgType = Expr(:curly, Tuple, argtypes...)
        RetType = parametric_type_to_expr(RetType)
        # #285: test whether we can evaluate an type constraints on parametric expressions
        # this essentially comes down to having the names be available in CompiledCalls,
        # if they are not then executing the method will fail
        try
            isa(RetType, Expr) && Core.eval(CompiledCalls, wrap_params(RetType, sparams))
            isa(ArgType, Expr) && Core.eval(CompiledCalls, wrap_params(ArgType, sparams))
        catch
            return false
        end
        argnames = Any[Symbol(:arg, i) for i = 1:length(args)]
        wrapargs = copy(argnames)
        for sparam in sparams
            push!(wrapargs, :(::$TVal{$sparam}))
        end
        if dynamic_ccall
            pushfirst!(wrapargs, cfunc)
        end
        methname = gensym("compiled_ccall")
        # Spell the argument types as an expression, like `ccall` lowering's `Core.svec(...)`,
        # so that free type parameters resolve to the wrapper's own static parameters.
        # Embedding the original `SimpleVector` would carry the original method's `TypeVar`s,
        # which codegen rejects for `Ref{T}` arguments because it validates them against the
        # enclosing method's signature (issue #536).
        argtypes = Expr(:call, Core.svec, argtypes...)
        def = :(function $methname($(wrapargs...)) where {$(sparams...)}
            return $(Expr(:foreigncall, cfunc, RetType, argtypes, stmt.args[4], stmt.args[5], argnames...))
        end)
        f = Core.eval(evalmod, def)
        compiled_calls[cc_key] = f
    end
    stmt.args[1] = QuoteNode(f)
    stmt.head = :call
    deleteat!(stmt.args, 2:length(stmt.args))
    if dynamic_ccall
        push!(stmt.args, argcfunc)
    end
    append!(stmt.args, args)
    for i in 1:length(sparams)
        push!(stmt.args, :($TVal($(Expr(:static_parameter, i)))))
    end
    return true
end

# Handle :cfunction (issue #318)
# Replace a `@cfunction` statement in place with a `:call` to a compiled wrapper method that
# evaluates it and return `true`, or leave it untouched (to `evaluate_foreigncall`) and return
# `false`. `@cfunction(f, rt, (at...))` lowers to `Expr(:cfunction, Ptr{Cvoid}, QuoteNode(f), rt,
# at, cc)` with `f` the callback as written (a name or any expression); method lowering has
# already replaced it by its value and evaluated the types. At toplevel, only callback references
# that can be resolved without invoking user code are evaluated here in the statement's module
# `mod`, in the latest world as with `Core.eval` (this helper is called via `@invokelatest`, not
# in the frame's world). Other expressions are left to the fallback without a speculative
# evaluation. The wrapper bakes the callback value in, like the body of a natively compiled
# `@cfunction`, and is cached by callback (compared by identity, see `compiled_calls`), types and
# calling convention. `@cfunction($f, ...)` lowers to `Expr(:cfunction, CFunction, f, rt, at, cc)`
# with `f` a runtime closure; its wrapper takes the closure as its argument and returns the
# `CFunction`, and is cached by types and calling convention alone.
function build_compiled_cfunction!(stmt::Expr, mod::Module, evalmod::Module)
    length(stmt.args) == 5 || return false
    T, fexpr, rt, at, cc = stmt.args
    (T === Ptr{Cvoid} || T === Base.CFunction) || return false
    (isa(cc, QuoteNode) && isa(cc.value, Symbol)) || return false
    RetType = resolve_ccall_type(rt, mod)
    ArgType = resolve_ccall_type(at, mod)
    (isa(RetType, Type) && isa(ArgType, SimpleVector)) || return false
    all(@nospecialize(t) -> isa(t, Type), ArgType) || return false
    (Base.has_free_typevars(RetType) || any(Base.has_free_typevars, ArgType)) && return false
    if T === Ptr{Cvoid}
        isa(fexpr, QuoteNode) || return false
        f = fexpr.value
        if isa(f, Symbol)
            isdefinedglobal(mod, f) || return false
            f = getglobal(mod, f)
        elseif isa(f, GlobalRef)
            isdefinedglobal(f.mod, f.name) || return false
            f = getglobal(f.mod, f.name)
        elseif isa(f, Expr)
            # Arbitrary callback expressions can have side effects or throw. Do not evaluate
            # them speculatively, since the fallback would repeat those effects after an error.
            is_constant_target(f, mod) || return false
            f = try Core.eval(mod, f) catch _; return false; end
        end
        cc_key = (:cfunction, f, RetType, ArgType, cc.value, evalmod)
        wrapargs = ()
        callargs = ()
        fbody = QuoteNode(f)
    else
        cc_key = (:cfunction, Base.CFunction, RetType, ArgType, cc.value, evalmod)
        closure = gensym("closure")
        wrapargs = (closure,)
        callargs = (fexpr,)
        fbody = closure
    end
    wrapper = get(compiled_calls, cc_key, nothing)
    if wrapper === nothing
        methname = gensym("compiled_cfunction")
        def = :(
            function $methname($(wrapargs...))
                return $(Expr(:cfunction, T, fbody, RetType, ArgType, cc))
            end)
        # Defining the method validates the C types (`check_c_types`); an invalid signature is
        # left to `evaluate_foreigncall` to report when the statement runs.
        wrapper = try Core.eval(evalmod, def) catch _; return false; end
        compiled_calls[cc_key] = wrapper
    end
    stmt.head = :call
    empty!(stmt.args)
    push!(stmt.args, QuoteNode(wrapper))
    append!(stmt.args, callargs)
    return true
end

function replace_coretypes!(@nospecialize(src); rev::Bool=false)
    if isa(src, CodeInfo)
        replace_coretypes_list!(src.code; rev=rev)
    elseif isa(src, Expr)
        replace_coretypes_list!(src.args; rev=rev)
    end
    return src
end

function replace_coretypes_list!(list::AbstractVector; rev::Bool=false)
    function rep(@nospecialize(x), rev::Bool)
        if rev
            isa(x, SSAValue) && return Core.SSAValue(x.id)
            isa(x, SlotNumber) && return Core.SlotNumber(x.id)
            return x
        else
            isa(x, Core.SSAValue) && return SSAValue(x.id)
            isa(x, Core.SlotNumber) && return SlotNumber(x.id)
            isa(x, Core.Compiler.Argument) && return SlotNumber(x.n)
            @static if VERSION < v"1.11.0-DEV.337"
            isa(x, Core.Compiler.TypedSlot) && return SlotNumber(x.id)
            end
            return x
        end
    end

    for (i, stmt) in enumerate(list)
        rstmt = rep(stmt, rev)
        if rstmt !== stmt
            list[i] = rstmt
        elseif isa(stmt, GotoIfNot)
            cond = stmt.cond
            rcond = rep(cond, rev)
            if rcond !== cond
                list[i] = GotoIfNot(rcond, stmt.dest)
            end
        elseif isa(stmt, ReturnNode)
            val = stmt.val
            rval = rep(val, rev)
            if rval !== val
                list[i] = ReturnNode(rval)
            end
        elseif @static (isdefinedglobal(Core.IR, :EnterNode) && true) && isa(stmt, Core.IR.EnterNode)
            if isdefined(stmt, :scope)
                rscope = rep(stmt.scope, rev)
                if rscope !== stmt.scope
                    list[i] = Core.IR.EnterNode(stmt.catch_dest, rscope)
                end
            end
        elseif isa(stmt, Expr)
            replace_coretypes!(stmt; rev=rev)
        end
    end
    return nothing
end

function reverse_lookup_globalref!(list)
    # This only handles the function in calls
    for stmt in list
        if isexpr(stmt, :(=))
            stmt = (stmt::Expr).args[2]
        end
        if isexpr(stmt, :call)
            stmt = stmt::Expr
            f = stmt.args[1]
            if isa(f, QuoteNode)
                f = f.value
                if isa(f, Function) && !isa(f, Core.IntrinsicFunction)
                    ft = typeof(f)
                    tn = ft.name::Core.TypeName
                    name = String(tn.name)
                    if startswith(name, '#')
                        name = name[2:end]
                    end
                    stmt.args[1] = GlobalRef(tn.module, Symbol(name))
                end
            end
        end
    end
    return list
end
