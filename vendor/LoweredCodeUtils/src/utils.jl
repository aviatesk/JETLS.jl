const AnySSAValue = Union{Core.IR.SSAValue,JuliaInterpreter.SSAValue}
const AnySlotNumber = Union{Core.IR.SlotNumber,JuliaInterpreter.SlotNumber}

# to circumvent https://github.com/JuliaLang/julia/issues/37342, we inline these `isa`
# condition checks at surface AST level
# https://github.com/JuliaLang/julia/pull/38905 will get rid of the need of these hacks
macro isssa(stmt)
    :($(GlobalRef(Core, :isa))($(esc(stmt)), $(GlobalRef(Core.IR, :SSAValue))) ||
      $(GlobalRef(Core, :isa))($(esc(stmt)), $(GlobalRef(JuliaInterpreter, :SSAValue))))
end
macro issslotnum(stmt)
    :($(GlobalRef(Core, :isa))($(esc(stmt)), $(GlobalRef(Core.IR, :SlotNumber))) ||
      $(GlobalRef(Core, :isa))($(esc(stmt)), $(GlobalRef(JuliaInterpreter, :SlotNumber))))
end

"""
    iscallto(stmt, name, src)

Returns `true` is `stmt` is a call expression to `name`.
"""
function iscallto(@nospecialize(stmt), mod::Module, name::GlobalRef, src)
    if isa(stmt, Expr)
        if stmt.head === :call
            a = stmt.args[1]
            if isa(a, SSAValue) || isa(a, Core.SSAValue)
                a = src.code[a.id]
            end
            normalize_defsig(a, mod) === name && return true
            is_global_ref(a, Core, :_apply) && normalize_defsig(stmt.args[2], mod) === name && return true
            is_global_ref(a, Core, :_apply_iterate) && normalize_defsig(stmt.args[3], mod) === name && return true
        end
    end
    return false
end

"""
    getcallee(stmt)

Returns the function (or Symbol) being called in a :call expression.
"""
function getcallee(@nospecialize(stmt))
    if isa(stmt, Expr)
        if stmt.head === :call
            a = stmt.args[1]
            is_global_ref(a, Core, :_apply) && return stmt.args[2]
            is_global_ref(a, Core, :_apply_iterate) && return stmt.args[3]
            return a
        end
    end
    error(stmt, " is not a call expression")
end

function callee_matches(f, mod, sym)
    is_global_ref(f, mod, sym) && return true
    if isdefined(mod, sym) && isa(f, QuoteNode)
        f.value === getfield(mod, sym) && return true  # a consequence of JuliaInterpreter.optimize!
    end
    return false
end

# Recognize the default-constructor call emitted when lowering a struct definition.
function is_defaultctors_call(@nospecialize(stmt))
    isexpr(stmt, :call) || return false
    f = stmt.args[1]
    is_global_ref(f, Core, :_defaultctors) && return true
    is_global_ref(f, Base, :_defaultctors) && return true
    @static if isdefined(Core, :_defaultctors)
        is_quotenode_egal(f, Core._defaultctors) && return true
    end
    @static if isdefined(Base, :_defaultctors)
        is_quotenode_egal(f, Base._defaultctors) && return true
    end
    return false
end

function getrhs(@nospecialize(stmt))
    lhs_rhs = get_lhs_rhs(stmt)
    return lhs_rhs === nothing ? stmt : lhs_rhs[2]
end

ismethod(frame::Frame)  = ismethod(pc_expr(frame))
ismethod3(frame::Frame) = ismethod3(pc_expr(frame))

# Check if a call argument refers to Core.define_method
function is_define_method_ref(@nospecialize(f))
    is_global_ref(f, Core, :define_method) && return true
    @static if isdefined(Core, :define_method)
        is_quotenode_egal(f, Core.define_method) && return true
    end
    return false
end

# define_method(mod, name) — 2-arg form creates generic function binding
function is_define_method_call_2arg(@nospecialize(stmt))
    isexpr(stmt, :call) || return false
    length(stmt.args) == 3 || return false
    return is_define_method_ref(stmt.args[1])
end

# define_method(mod, name_or_mt, sigdata, codeinfo) — 4-arg form defines a method
function is_define_method_call_4arg(@nospecialize(stmt))
    isexpr(stmt, :call) || return false
    length(stmt.args) == 5 || return false
    return is_define_method_ref(stmt.args[1])
end

ismethod(stmt)  = isexpr(stmt, :method) || is_define_method_call_2arg(stmt) || is_define_method_call_4arg(stmt)
ismethod1(stmt) = isexpr(stmt, :method, 1) || is_define_method_call_2arg(stmt)
ismethod3(stmt) = isexpr(stmt, :method, 3) || is_define_method_call_4arg(stmt)

# Extract the "name" argument from a method-definition statement.
# For Expr(:method, name, ...) it's args[1]; for define_method(mod, name, ...) it's args[3].
function method_name(@nospecialize(stmt))
    if is_define_method_call_2arg(stmt) || is_define_method_call_4arg(stmt)
        return stmt.args[3]
    else
        return stmt.args[1]
    end
end

# Extract the module from a define_method call, or nothing for :method expressions.
function method_module(@nospecialize(stmt))
    if is_define_method_call_2arg(stmt) || is_define_method_call_4arg(stmt)
        return stmt.args[2]  # define_method(mod, name, ...)
    end
    return nothing
end

# Extract the CodeInfo body from a method3 statement.
# For Expr(:method, name, sig, body) it's args[3]; for define_method(mod, name, sigdata, body) it's args[5].
function method_body(@nospecialize(stmt))
    if is_define_method_call_4arg(stmt)
        return stmt.args[5]
    else
        return stmt.args[3]
    end
end

function ismethod_with_name(src, stmt, target::AbstractString; reentrant::Bool=false)
    if reentrant
        name = stmt
    else
        ismethod3(stmt) || return false
        name = method_name(stmt)
        if name === nothing && isexpr(stmt, :method)
            name = stmt.args[2]
        end
    end
    isdone = false
    while !isdone
        if name isa AnySSAValue || name isa AnySlotNumber
            name = src.code[name.id]
        elseif isexpr(name, :call) && is_quotenode_egal(name.args[1], Core.svec)
            name = name.args[2]
        elseif isexpr(name, :call) && is_quotenode_egal(name.args[1], Core.Typeof)
            name = name.args[2]
        elseif isexpr(name, :call) && is_quotenode_egal(name.args[1], Core.apply_type)
            for arg in name.args[2:end]
                ismethod_with_name(src, arg, target; reentrant=true) && return true
            end
            isdone = true
        elseif isexpr(name, :call) && is_quotenode_egal(name.args[1], UnionAll)
            for arg in name.args[2:end]
                ismethod_with_name(src, arg, target; reentrant=true) && return true
            end
            isdone = true
        else
            isdone = true
        end
    end
    # On Julia 1.6 we have to add escaping (CBinding makes function names like "(S)")
    target = escape_string(target, "()")
    return match(Regex("(^|#)$target(\$|#)"), isa(name, GlobalRef) ? string(name.name) : string(name)) !== nothing
end

# anonymous function types are defined in a :thunk expr with a characteristic CodeInfo
function isanonymous_typedef(@nospecialize stmt)
    if isa(stmt, Expr)
        stmt.head === :thunk || return false
        stmt = stmt.args[1]
    end
    if isa(stmt, CodeInfo)
        src = stmt    # just for naming consistency
        length(src.code) >= 4 || return false
        stmt = src.code[end-1]
        isexpr(stmt, :call) || return false
        is_global_ref(stmt.args[1], Core, :_typebody!) || return false
        stmt = isa(stmt.args[3], Core.SSAValue) ? src.code[end-3] : src.code[end-2]
        lhs_rhs = get_lhs_rhs(stmt)
        lhs_rhs === nothing && return false
        lhs, _ = lhs_rhs
        if isa(lhs, GlobalRef)
            lhs = lhs.name
        else
            isa(lhs, Symbol) || return false
        end
        return startswith(String(lhs), "#")
    end
    return false
end

# Recognize the `Core.resolve_typegroup` call that creates the types of a type
# group. On Julia versions where `struct` definitions lower through the
# typegroup mechanism, ordinary structs also produce this form (with a
# single-element group); `typegroup` blocks produce multi-element groups.
function is_resolve_typegroup_call(@nospecialize(stmt))
    isexpr(stmt, :call) || return false
    f = (stmt::Expr).args[1]
    is_global_ref(f, Core, :resolve_typegroup) && return true
    @static if isdefined(Core, :resolve_typegroup)
        is_quotenode_egal(f, Core.resolve_typegroup) && return true
    end
    return false
end

function istypedef(stmt)
    isa(stmt, Expr) || return false
    stmt = getrhs(stmt)
    isa(stmt, Expr) || return false
    @static if all(s->isdefined(Core,s), structdecls)
        if stmt.head === :call
            f = stmt.args[1]
            if isa(f, GlobalRef)
                f.mod === Core && f.name ∈ structdecls && return true
            end
            if isa(f, QuoteNode)
                (f.value === Core._structtype || f.value === Core._abstracttype ||
                 f.value === Core._primitivetype) && return true
            end
        end
    end
    is_resolve_typegroup_call(stmt) && return true
    isanonymous_typedef(stmt) && return true
    return false
end

# Check if stmt is a Core.declare_global(...) call
function is_declare_global(@nospecialize(stmt))
    isexpr(stmt, :call) || return false
    f = stmt.args[1]
    @static if isdefined(Core, :declare_global)
        is_global_ref(f, Core, :declare_global) && return true
        is_quotenode_egal(f, Core.declare_global) && return true
    end
    return false
end

# Check if stmt is a Core.declare_const(...) call
function is_declare_const(@nospecialize(stmt))
    isexpr(stmt, :call) || return false
    f = stmt.args[1]
    @static if isdefined(Core, :declare_const)
        is_global_ref(f, Core, :declare_const) && return true
        is_quotenode_egal(f, Core.declare_const) && return true
    end
    return false
end

# Given a typedef at `src.code[idx]`, return the range of statement indices that encompass the typedef.
# The range does not include any constructor methods.
function typedef_range(src::CodeInfo, idx)
    stmt = src.code[idx]
    istypedef(stmt) || error(stmt, " is not a typedef")
    stmt = stmt::Expr
    isanonymous_typedef(stmt) && return idx:idx
    # Search backwards to the previous :global or Core.declare_global
    istart = idx
    while istart >= 1
        s = src.code[istart]
        isexpr(s, :global) && break
        is_declare_global(s) && break
        istart -= 1
    end
    if is_resolve_typegroup_call(getrhs(stmt))
        # Typegroup form: `TypeVar` bindings and struct-info svecs, then
        # `resolve_typegroup(mod, typevars, infos, olds)`, then `getfield`
        # extractions and one `declare_const` per type, closed by `latestworld`.
        # Ordinary struct definitions open with a `global` marker; `typegroup`
        # blocks do not, so if none was found fall back to extending the range
        # backwards to the previous statement that cannot be part of the group.
        if istart < 1
            istart = idx
            for j = idx-1:-1:1
                s = src.code[j]
                (isexpr(s, :latestworld) || isexpr(s, :method) || isexpr(s, :thunk) ||
                 is_return(s)) && break
                istart = j
            end
        end
        iend, n = idx, length(src.code)
        while iend <= n
            s = src.code[iend]
            (isexpr(s, :latestworld) || isexpr(s, :global) || is_return(s)) && break
            iend += 1
        end
        iend <= n || error("no final latestworld found for typegroup")
        return istart:iend-1
    end
    istart >= 1 || error("no initial :global or declare_global found")
    iend, n = idx, length(src.code)
    have_typebody = have_equivtypedef = false
    while iend <= n
        stmt = src.code[iend]
        if isa(stmt, Expr)
            stmt.head === :global && break
            stmt.head === :latestworld && break
            # New lowering uses Core.declare_const for the final binding
            is_declare_const(stmt) && break
            # Unwrap assignments (e.g. `_1 = Core._typebody!(...)`) to find the call
            callstmt = stmt.head === :(=) ? getrhs(stmt) : stmt
            if isa(callstmt, Expr) && callstmt.head === :call
                if (is_global_ref(callstmt.args[1], Core, :_typebody!) || is_quotenode_egal(callstmt.args[1], Core._typebody!))
                    have_typebody = true
                elseif (is_global_ref(callstmt.args[1], Core, :_equiv_typedef) || is_quotenode_egal(callstmt.args[1], Core._equiv_typedef))
                    have_equivtypedef = true
                    # Advance to the type-assignment (or declare_const call)
                    while iend <= n
                        stmt = src.code[iend]
                        get_lhs_rhs(stmt) !== nothing && break
                        is_declare_const(stmt) && break
                        iend += 1
                    end
                end
                if have_typebody && have_equivtypedef
                    iend += 1   # compensate for the `iend-1` in the return
                    break
                end
            end
        end
        is_return(stmt) && break
        iend += 1
    end
    iend <= n || (@show src; error("no final :global or declare_const found"))
    return istart:iend-1
end

function sparam_ub(meth::Method)
    typs = []
    sig = meth.sig
    while sig isa UnionAll
        push!(typs, Symbol(sig.var.ub))
        sig = sig.body
    end
    return Core.svec(typs...)
end

showempty(list) = isempty(list) ? '∅' : list

# Smooth the transition between CC and Base (not requried for v1.12 and above)
rng(bb::BasicBlock) = (r = bb.stmts; return CC.first(r):CC.last(r))

function pushall!(dest, src)
    for item in src
        push!(dest, item)
    end
    return dest
end

# computes strongly connected components of a control flow graph `cfg`
# NOTE adapted from https://github.com/JuliaGraphs/Graphs.jl/blob/5878e7be4d68b2a1c179d1367aea670db115ebb5/src/connectivity.jl#L265-L357
# since to load an entire Graphs.jl is a bit cost-ineffective in terms of a trade-off of latency vs. maintainability
function strongly_connected_components(g::CFG)
    T = Int
    zero_t = zero(T)
    one_t = one(T)
    nvg = nv(g)
    count = one_t

    index = zeros(T, nvg)         # first time in which vertex is discovered
    stack = Vector{T}()           # stores vertices which have been discovered and not yet assigned to any component
    onstack = zeros(Bool, nvg)    # false if a vertex is waiting in the stack to receive a component assignment
    lowlink = zeros(T, nvg)       # lowest index vertex that it can reach through back edge (index array not vertex id number)
    parents = zeros(T, nvg)       # parent of every vertex in dfs
    components = Vector{Vector{T}}()    # maintains a list of scc (order is not guaranteed in API)

    dfs_stack = Vector{T}()

    @inbounds for s in vertices(g)
        if index[s] == zero_t
            index[s] = count
            lowlink[s] = count
            onstack[s] = true
            parents[s] = s
            push!(stack, s)
            count = count + one_t

            # start dfs from 's'
            push!(dfs_stack, s)

            while !isempty(dfs_stack)
                v = dfs_stack[end] # end is the most recently added item
                u = zero_t
                @inbounds for v_neighbor in outneighbors(g, v)
                    if index[v_neighbor] == zero_t
                        # unvisited neighbor found
                        u = v_neighbor
                        break
                        # GOTO A push u onto DFS stack and continue DFS
                    elseif onstack[v_neighbor]
                        # we have already seen n, but can update the lowlink of v
                        # which has the effect of possibly keeping v on the stack until n is ready to pop.
                        # update lowest index 'v' can reach through out neighbors
                        lowlink[v] = min(lowlink[v], index[v_neighbor])
                    end
                end
                if u == zero_t
                    # All out neighbors already visited or no out neighbors
                    # we have fully explored the DFS tree from v.
                    # time to start popping.
                    popped = pop!(dfs_stack)
                    lowlink[parents[popped]] = min(
                        lowlink[parents[popped]], lowlink[popped]
                    )

                    if index[v] == lowlink[v]
                        # found a cycle in a completed dfs tree.
                        component = Vector{T}()

                        while !isempty(stack) # break when popped == v
                            # drain stack until we see v.
                            # everything on the stack until we see v is in the SCC rooted at v.
                            popped = pop!(stack)
                            push!(component, popped)
                            onstack[popped] = false
                            # popped has been assigned a component, so we will never see it again.
                            if popped == v
                                # we have drained the stack of an entire component.
                                break
                            end
                        end

                        reverse!(component)
                        push!(components, component)
                    end

                else # LABEL A
                    # add unvisited neighbor to dfs
                    index[u] = count
                    lowlink[u] = count
                    onstack[u] = true
                    parents[u] = v
                    count = count + one_t

                    push!(stack, u)
                    push!(dfs_stack, u)
                    # next iteration of while loop will expand the DFS tree from u.
                end
            end
        end
    end

    # # assert with the original implementation
    # oracle_components = oracle_scc(cfg_to_sdg(g))
    # @assert Set(Set.(components)) == Set(Set.(oracle_components))

    return components
end

# compatibility with Graphs.jl interfaces
@inline nv(cfg::CFG) = length(cfg.blocks)
@inline vertices(cfg::CFG) = 1:nv(cfg)
@inline outneighbors(cfg::CFG, v) = cfg.blocks[v].succs

# using Graphs: SimpleDiGraph, add_edge!, strongly_connected_components as oracle_scc
# function cfg_to_sdg(cfg::CFG)
#     g = SimpleDiGraph(length(cfg.blocks))
#     for (v, block) in enumerate(cfg.blocks)
#         for succ in block.succs
#             add_edge!(g, v, succ)
#         end
#     end
#     return g
# end
