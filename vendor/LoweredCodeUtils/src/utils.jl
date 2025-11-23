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

function getrhs(@nospecialize(stmt))
    lhs_rhs = get_lhs_rhs(stmt)
    return lhs_rhs === nothing ? stmt : lhs_rhs[2]
end

ismethod(frame::Frame)  = ismethod(pc_expr(frame))
ismethod3(frame::Frame) = ismethod3(pc_expr(frame))

ismethod(stmt)  = isexpr(stmt, :method)
ismethod1(stmt) = isexpr(stmt, :method, 1)
ismethod3(stmt) = isexpr(stmt, :method, 3)
function ismethod_with_name(src, stmt, target::AbstractString; reentrant::Bool=false)
    if reentrant
        name = stmt
    else
        ismethod3(stmt) || return false
        name = stmt.args[1]
        if name === nothing
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
    isanonymous_typedef(stmt) && return true
    return false
end

# Given a typedef at `src.code[idx]`, return the range of statement indices that encompass the typedef.
# The range does not include any constructor methods.
function typedef_range(src::CodeInfo, idx)
    stmt = src.code[idx]
    istypedef(stmt) || error(stmt, " is not a typedef")
    stmt = stmt::Expr
    isanonymous_typedef(stmt) && return idx:idx
    # Search backwards to the previous :global
    istart = idx
    while istart >= 1
        isexpr(src.code[istart], :global) && break
        isexpr(src.code[istart], :latestworld) && break
        istart -= 1
    end
    istart >= 1 || error("no initial :global found")
    iend, n = idx, length(src.code)
    have_typebody = have_equivtypedef = false
    while iend <= n
        stmt = src.code[iend]
        if isa(stmt, Expr)
            stmt.head === :global && break
            stmt.head === :latestworld && break
            if stmt.head === :call
                if (is_global_ref(stmt.args[1], Core, :_typebody!) || is_quotenode_egal(stmt.args[1], Core._typebody!))
                    have_typebody = true
                elseif (is_global_ref(stmt.args[1], Core, :_equiv_typedef) || is_quotenode_egal(stmt.args[1], Core._equiv_typedef))
                    have_equivtypedef = true
                    # Advance to the type-assignment
                    while iend <= n
                        stmt = src.code[iend]
                        get_lhs_rhs(stmt) !== nothing && break
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
    iend <= n || (@show src; error("no final :global found"))
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
