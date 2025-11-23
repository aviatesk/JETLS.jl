## Phase 1: direct links

# There are 3 types of entities to track: ssavalues (line/statement numbers), slots, and named objects.
# Each entity can have a number of "predecessors" (forward edges), which can be any combination of these
# three entity types. Likewise, each entity can have a number of "successors" (backward edges), also any
# combination of these entity types.
struct Links
    ssas::Vector{Int}
    slots::Vector{Int}
    names::Vector{GlobalRef}
end
Links() = Links(Int[], Int[], GlobalRef[])

function Base.show(io::IO, l::Links)
    print(io, "ssas: ", showempty(l.ssas),
              ", slots: ", showempty(l.slots),
              ", names: ")
    print(IOContext(io, :typeinfo=>Vector{GlobalRef}), showempty(l.names))
    print(io, ';')
end

struct CodeLinks
    thismod::Module
    ssapreds::Vector{Links}
    ssasuccs::Vector{Links}
    slotpreds::Vector{Links}
    slotsuccs::Vector{Links}
    slotassigns::Vector{Vector{Int}}
    namepreds::Dict{GlobalRef,Links}
    namesuccs::Dict{GlobalRef,Links}
    nameassigns::Dict{GlobalRef,Vector{Int}}
end
function CodeLinks(thismod::Module, nlines::Int, nslots::Int)
    makelinks(n) = [Links() for _ = 1:n]

    return CodeLinks(thismod,
                     makelinks(nlines),
                     makelinks(nlines),
                     makelinks(nslots),
                     makelinks(nslots),
                     [Int[] for _ = 1:nslots],
                     Dict{GlobalRef,Links}(),
                     Dict{GlobalRef,Links}(),
                     Dict{GlobalRef,Vector{Int}}())
end
function CodeLinks(thismod::Module, src::CodeInfo)
    cl = CodeLinks(thismod, length(src.code), length(src.slotnames))
    direct_links!(cl, src)
end

function Base.show(io::IO, cl::CodeLinks)
    print(io, "CodeLinks:")
    print_slots(io, cl)
    print_names(io, cl)
    nstmts = length(cl.ssapreds)
    nd = ndigits(nstmts)
    print(io, "\nCode:")
    for i = 1:nstmts
        print(io, '\n', lpad(i, nd), " preds: ")
        show(io, cl.ssapreds[i])
        print(io, '\n', lpad(i, nd), " succs: ")
        show(io, cl.ssasuccs[i])
    end
end

function print_slots(io::IO, cl::CodeLinks)
    nslots = length(cl.slotpreds)
    nd = ndigits(nslots)
    for i = 1:nslots
        print(io, "\nslot ", lpad(i, nd), ':')
        print(io, "\n  preds: ")
        show(io, cl.slotpreds[i])
        print(io, "\n  succs: ")
        show(io, cl.slotsuccs[i])
        print(io, "\n  assign @: ")
        show(io, cl.slotassigns[i])
    end
end

function print_names(io::IO, cl::CodeLinks)
    ukeys = namedkeys(cl)
    for key in ukeys
        print(io, '\n', key, ':')
        if haskey(cl.namepreds, key)
            print(io, "\n  preds: ")
            show(io, cl.namepreds[key])
        end
        if haskey(cl.namesuccs, key)
            print(io, "\n  succs: ")
            show(io, cl.namesuccs[key])
        end
        if haskey(cl.nameassigns, key)
            print(io, "\n  assign @: ")
            show(io, cl.nameassigns[key])
        end
    end
end

function print_with_code(preprint, postprint, io::IO, src::CodeInfo)
    src = copy(src)
    JuliaInterpreter.replace_coretypes!(src; rev=true)
    JuliaInterpreter.reverse_lookup_globalref!(src.code)
    io = IOContext(io,
        :displaysize=>displaysize(io),
        :SOURCE_SLOTNAMES => Base.sourceinfo_slotnames(src))
    used = BitSet()
    cfg = compute_basic_blocks(src.code)
    for stmt in src.code
        CC.scan_ssa_use!(push!, used, stmt)
    end
    @static if isdefined(Base, :__has_internal_change) && Base.__has_internal_change(v"1.12-alpha", :printcodeinfocalls)
        sptypes = let parent = src.parent
            parent isa MethodInstance ?
                CC.sptypes_from_meth_instance(parent) :
                CC.EMPTY_SPTYPES
        end
    end
    line_info_preprinter = IRShow.lineinfo_disabled
    line_info_postprinter = IRShow.default_expr_type_printer
    preprint(io)
    bb_idx_prev = bb_idx = 1
    for idx = 1:length(src.code)
        preprint(io, idx)
        @static if isdefined(Base, :__has_internal_change) && Base.__has_internal_change(v"1.12-alpha", :printcodeinfocalls)
            bb_idx = IRShow.show_ir_stmt(io, src, idx, line_info_preprinter, line_info_postprinter, sptypes, used, cfg, bb_idx)
        else
            bb_idx = IRShow.show_ir_stmt(io, src, idx, line_info_preprinter, line_info_postprinter, used, cfg, bb_idx)
        end
        postprint(io, idx, bb_idx != bb_idx_prev)
        bb_idx_prev = bb_idx
    end
    max_bb_idx_size = ndigits(length(cfg.blocks))
    line_info_preprinter(io, " "^(max_bb_idx_size + 2), 0)
    postprint(io)
    return nothing
end

"""
    print_with_code(io, src::CodeInfo, cl::CodeLinks)

Interweave display of code and links.

!!! compat "Julia 1.6"
    This function produces dummy output if suitable support is missing in your version of Julia.

"""
function print_with_code(io::IO, src::CodeInfo, cl::CodeLinks)
    function preprint(io::IO)
        print(io, "Slots:")
        print_slots(io, cl)
        print(io, "\nNames:")
        print_names(io, cl)
        println(io)
    end
    preprint(::IO, ::Int) = nothing
    postprint(::IO) = nothing
    postprint(io::IO, idx::Int, bbchanged::Bool) = postprint_linelinks(io, idx, src, cl, bbchanged)

    print_with_code(preprint, postprint, io, src)
end

function postprint_linelinks(io::IO, idx::Int, src::CodeInfo, cl::CodeLinks, bbchanged::Bool)
    printstyled(io, bbchanged ? " " : "│", color=:light_black)
    printstyled(io, "             # ", color=:yellow)
    stmt = src.code[idx]
    lhs_rhs = get_lhs_rhs(stmt)
    if lhs_rhs !== nothing
        lhs, _ = lhs_rhs
        lhs = normalize_defsig(lhs, cl.thismod)
        if @issslotnum(lhs)
            # id = lhs.id
            # preds, succs = cl.slotpreds[id], cl.slotsuccs[id]
            printstyled(io, "see slot ", lhs.id, '\n', color=:yellow)
        else
            # preds, succs = cl.namepreds[lhs], cl.namesuccs[lhs]
            printstyled(io, "see name ", lhs, '\n', color=:yellow)
        end
    else
        preds, succs = cl.ssapreds[idx], cl.ssasuccs[idx]
        printstyled(io, "preds: ", preds, " succs: ", succs, '\n', color=:yellow)
    end
    return nothing
end

function namedkeys(cl::CodeLinks)
    ukeys = Set{GlobalRef}()
    for c in (cl.namepreds, cl.namesuccs, cl.nameassigns)
        for k in keys(c)
            push!(ukeys, k)
        end
    end
    return ukeys
end

# Required by Revise, but otherwise deprecated
# The depwarn is currently disabled because Revise's tests check for empty warning logs
function is_assignment_like(@nospecialize stmt)
    # Base.depwarn("is_assignment_like is deprecated, switch to `LoweredCodeUtils.get_lhs_rhs`", :is_assignment_like)
    return isexpr(stmt, :(=)) || isexpr(stmt, :const, 2)
end

function get_lhs_rhs(@nospecialize stmt)
    if isexpr(stmt, :(=))
        return Pair{Any,Any}(stmt.args[1], stmt.args[2])
    elseif isexpr(stmt, :const) && length(stmt.args) == 2
        # TODO: remove lowered :const when Julia min compat >= 1.13
        return Pair{Any,Any}(stmt.args[1], stmt.args[2])
    elseif isexpr(stmt, :call) && length(stmt.args) == 4
        f = stmt.args[1]
        # TODO: remove isdefined when Julia min compat >= 1.13
        if is_global_ref_egal(f, :setglobal!, Core.setglobal!) || @static isdefined(Core, :declare_const) && is_global_ref_egal(f, :declare_const,  Core.declare_const)
            mod = stmt.args[2]
            mod isa Module || return nothing
            name = stmt.args[3]
            if name isa QuoteNode
                name = name.value
            end
            name isa Symbol || return nothing
            lhs = GlobalRef(mod, name)
            return Pair{Any,Any}(lhs, stmt.args[4])
        end
    end
    return nothing
end

function direct_links!(cl::CodeLinks, src::CodeInfo)
    # Utility for when a stmt itself contains a CodeInfo
    function add_inner!(cl::CodeLinks, icl::CodeLinks, idx)
        for (name, _) in icl.nameassigns
            assigns = get!(Vector{Int}, cl.nameassigns, name)
            push!(assigns, idx)
        end
        for (name, _) in icl.namesuccs
            succs = get!(Links, cl.namesuccs, name)
            push!(succs.ssas, idx)
        end
    end

    P = Pair{Union{SSAValue,SlotNumber,GlobalRef},Links}

    for (i, stmt) in enumerate(src.code)
        if isexpr(stmt, :thunk) && (arg1 = stmt.args[1]; arg1 isa CodeInfo)
            icl = CodeLinks(cl.thismod, arg1)
            add_inner!(cl, icl, i)
            continue
        elseif isexpr(stmt, :method)
            if length(stmt.args) === 1
                # A function with no methods was defined. Associate its new binding to it.
                name = stmt.args[1]
                if isa(name, Symbol)
                    name = GlobalRef(cl.thismod, name)
                end
                if !isa(name, GlobalRef)
                    error("name ", typeof(name), " not recognized")
                end
                assign = get!(Vector{Int}, cl.nameassigns, name)
                push!(assign, i)
                targetstore = get!(Links, cl.namepreds, name)
                target = P(name, targetstore)
                add_links!(target, stmt, cl)
            elseif length(stmt.args) === 3 && (arg3 = stmt.args[3]; arg3 isa CodeInfo) # method definition
                # A method was defined for an existing function.
                icl = CodeLinks(cl.thismod, arg3)
                add_inner!(cl, icl, i)
            end
            rhs = stmt
            target = P(SSAValue(i), cl.ssapreds[i])
        elseif (lhs_rhs = get_lhs_rhs(stmt); lhs_rhs !== nothing)
            # An assignment
            stmt = stmt::Expr
            lhs, rhs = lhs_rhs
            if @issslotnum(lhs)
                lhs = lhs::AnySlotNumber
                id = lhs.id
                target = P(SlotNumber(id), cl.slotpreds[id])
                push!(cl.slotassigns[id], i)
            elseif isa(lhs, GlobalRef) || isa(lhs, Symbol)
                if isa(lhs, Symbol)
                    lhs = GlobalRef(cl.thismod, lhs)
                end
                targetstore = get!(Links, cl.namepreds, lhs)
                target = P(lhs, targetstore)
                assign = get(cl.nameassigns, lhs, nothing)
                if assign === nothing
                    cl.nameassigns[lhs] = assign = Int[]
                end
                push!(assign, i)
            else
                error("lhs ", lhs, " not recognized")
            end
        else
            rhs = stmt
            target = P(SSAValue(i), cl.ssapreds[i])
        end
        add_links!(target, rhs, cl)
    end
    return cl
end

function add_links!(target::Pair{Union{SSAValue,SlotNumber,GlobalRef},Links}, @nospecialize(stmt), cl::CodeLinks)
    _targetid, targetstore = target
    targetid = _targetid::Union{SSAValue,SlotNumber,GlobalRef}
    # Adds bidirectional edges
    if @isssa(stmt)
        stmt = stmt::AnySSAValue
        push!(targetstore, SSAValue(stmt.id))    # forward edge
        push!(cl.ssasuccs[stmt.id], targetid)    # backward edge
    elseif @issslotnum(stmt)
        stmt = stmt::AnySlotNumber
        push!(targetstore, SlotNumber(stmt.id))
        push!(cl.slotsuccs[stmt.id], targetid)
    elseif isa(stmt, GlobalRef) || isa(stmt, Symbol)
        if isa(stmt, Symbol)
            stmt = GlobalRef(cl.thismod, stmt)
        end
        push!(targetstore, stmt)
        namestore = get!(Links, cl.namesuccs, stmt)
        push!(namestore, targetid)
    elseif isa(stmt, Expr)
        if stmt.head === :globaldecl
            for i = 1:length(stmt.args)
                a = stmt.args[i]
                if a isa GlobalRef
                    namestore = get!(Links, cl.namepreds, a) # TODO should this information be tracked in the separate `cl.namedecls` store?
                    push!(namestore, targetid)
                    if targetid isa SSAValue
                        push!(namestore, SSAValue(targetid.id+1)) # +1 for :latestworld
                    end
                else
                    add_links!(target, a, cl)
                end
            end
        elseif stmt.head !== :copyast
            stmt = stmt::Expr
            arng = 1:length(stmt.args)
            if stmt.head === :call
                f = stmt.args[1]
                if !@isssa(f) && !@issslotnum(f)
                    # Avoid putting named callees on the namestore
                    arng = 2:length(stmt.args)
                end
                if f isa GlobalRef && f == GlobalRef(Core, :declare_global) && 3 <= length(stmt.args) <= 5
                    # Core.declare_global(module::Module, name::Symbol, strong::Bool=false, [ty::Type])
                    m = stmt.args[2]
                    s = stmt.args[3]
                    strong = length(stmt.args) >= 4 ? stmt.args[4] === true : false
                    if strong && m isa Module && s isa QuoteNode && s.value isa Symbol
                        a = GlobalRef(m, s.value::Symbol)
                        namestore = get!(Links, cl.namepreds, a) # TODO should this information be tracked in the separate `cl.namedecls` store?
                        push!(namestore, targetid)
                        if targetid isa SSAValue
                            push!(namestore, SSAValue(targetid.id+1)) # +1 for :latestworld
                        end
                    end
                    arng = 4:length(stmt.args)
                end
            end
            for i in arng
                add_links!(target, stmt.args[i], cl)
            end
        end
    elseif stmt isa Core.GotoIfNot
        add_links!(target, stmt.cond, cl)
    elseif stmt isa Core.ReturnNode
        add_links!(target, stmt.val, cl)
    end
    return nothing
end

function Base.push!(l::Links, id)
    if isa(id, SSAValue)
        k = id.id
        k ∉ l.ssas && push!(l.ssas, k)
    elseif isa(id, SlotNumber)
        k = id.id
        k ∉ l.slots && push!(l.slots, k)
    else
        id = id::GlobalRef
        id ∉ l.names && push!(l.names, id)
    end
    return id
end

## Phase 2: replacing slot-links with statement-links (and adding name-links to statement-links)

# Now that we know the full set of dependencies, we can safely replace references to names
# by references to the relevant line numbers.

"""
`Variable` holds information about named variables.
Unlike SSAValues, a single Variable can be assigned from multiple code locations.

If `v` is a `Variable`, then
- `v.assigned` is a list of statement numbers on which it is assigned
- `v.preds` is the set of statement numbers upon which this assignment depends
- `v.succs` is the set of statement numbers which make use of this variable

`preds` and `succs` are short for "predecessors" and "successors," respectively.
These are meant in the sense of execution order, not statement number; depending on control-flow,
a variable may have entries in `preds` that are larger than the smallest entry in `assigned`.
"""
struct Variable
    assigned::Vector{Int}
    preds::Vector{Int}
    succs::Vector{Int}
end

function Base.show(io::IO, v::Variable)
    print(io, "assigned on ", showempty(v.assigned))
    print(io, ", depends on ", showempty(v.preds))
    print(io, ", and used by ", showempty(v.succs))
end

# This will be documented below at the "user-level" constructor.
# preds[i] is the list of predecessors for the `i`th statement in the CodeInfo
# succs[i] is the list of successors for the `i`th statement in the CodeInfo
# byname[name] summarizes this CodeInfo's dependence on Variable `name`.
struct CodeEdges
    preds::Vector{Vector{Int}}
    succs::Vector{Vector{Int}}
    byname::Dict{GlobalRef,Variable}
end
CodeEdges(n::Integer) = CodeEdges([Int[] for i = 1:n], [Int[] for i = 1:n], Dict{GlobalRef,Variable}())

function Base.show(io::IO, edges::CodeEdges)
    println(io, "CodeEdges:")
    for (name, v) in edges.byname
        print(io, "  ", name, ": ")
        show(io, v)
        println(io)
    end
    n = length(edges.preds)
    nd = ndigits(n)
    for i = 1:n
        println(io, "  statement ", lpad(i, nd), " depends on ", showempty(edges.preds[i]), " and is used by ", showempty(edges.succs[i]))
    end
    return nothing
end

"""
    edges = CodeEdges(src::CodeInfo)

Analyze `src` and determine the chain of dependencies.

- `edges.preds[i]` lists the preceding statements that statement `i` depends on.
- `edges.succs[i]` lists the succeeding statements that depend on statement `i`.
- `edges.byname[v]` returns information about the predecessors, successors, and assignment statements
  for an object `v::GlobalRef`.
"""
function CodeEdges(mod::Module, src::CodeInfo)
    cl = CodeLinks(mod, src)
    CodeEdges(src, cl)
end

function CodeEdges(src::CodeInfo, cl::CodeLinks)
    # The main task here is to elide the slot-dependencies and convert
    # everything to just ssas & names.

    # Replace/add named intermediates (slot & named-variable references) with statement numbers
    nstmts, nslots = length(src.code), length(src.slotnames)
    marked, slothandled = BitSet(), fill(false, nslots)  # working storage during resolution
    edges = CodeEdges(nstmts)
    emptylink = Links()
    emptylist = Int[]
    for (i, stmt) in enumerate(src.code)
        # Identify line predecents for slots and named variables
        if (lhs_rhs = get_lhs_rhs(stmt); lhs_rhs !== nothing)
            stmt = stmt::Expr
            lhs, _ = lhs_rhs
            # Mark predecessors and successors of this line by following ssas & named assignments
            if @issslotnum(lhs)
                lhs = lhs::AnySlotNumber
                # This line assigns a slot. Mark all predecessors.
                id = lhs.id
                linkpreds, linksuccs, listassigns = cl.slotpreds[id], cl.slotsuccs[id], cl.slotassigns[id]
            else
                lhs = lhs::Union{GlobalRef,Symbol}
                if lhs isa Symbol
                    lhs = GlobalRef(cl.thismod, lhs)
                end
                linkpreds = get(cl.namepreds, lhs, emptylink)
                linksuccs = get(cl.namesuccs, lhs, emptylink)
                listassigns = get(cl.nameassigns, lhs, emptylist)
            end
        else
            linkpreds, linksuccs, listassigns = cl.ssapreds[i], cl.ssasuccs[i], emptylist
        end
        # Assign the predecessors
        # For "named" predecessors, we depend only on their assignments
        empty!(marked)
        fill!(slothandled, false)
        follow_links!(marked, linkpreds, cl.slotpreds, cl.slotassigns, slothandled)
        pushall!(marked, listassigns)
        for key in linkpreds.names
            pushall!(marked, get(cl.nameassigns, key, emptylist))
        end
        delete!(marked, i)
        append!(edges.preds[i], marked)
        # Similarly for successors
        empty!(marked)
        fill!(slothandled, false)
        follow_links!(marked, linksuccs, cl.slotsuccs, cl.slotassigns, slothandled)
        pushall!(marked, listassigns)
        for key in linksuccs.names
            pushall!(marked, get(cl.nameassigns, key, emptylist))
        end
        delete!(marked, i)
        append!(edges.succs[i], marked)
    end
    # Add named variables
    ukeys = namedkeys(cl)
    for key in ukeys
        assigned = get(cl.nameassigns, key, Int[])
        empty!(marked)
        linkpreds = get(cl.namepreds, key, emptylink)
        pushall!(marked, linkpreds.ssas)
        for j in linkpreds.slots
            pushall!(marked, cl.slotassigns[j])
        end
        for key in linkpreds.names
            pushall!(marked, get(cl.nameassigns, key, emptylist))
        end
        preds = append!(Int[], marked)
        empty!(marked)
        linksuccs = get(cl.namesuccs, key, emptylink)
        pushall!(marked, linksuccs.ssas)
        for j in linksuccs.slots
            pushall!(marked, cl.slotassigns[j])
            pushall!(marked, cl.slotsuccs[j].ssas)
        end
        for key in linksuccs.names
            pushall!(marked, get(cl.nameassigns, key, emptylist))
        end
        succs = append!(Int[], marked)
        edges.byname[key] = Variable(assigned, preds, succs)
    end

    return edges
end

# Follow slot links to their non-slot leaves
function follow_links!(marked, l::Links, slotlinks, slotassigns, slothandled)
    pushall!(marked, l.ssas)
    for id in l.slots
        slothandled[id] && continue
        slothandled[id] = true
        pushall!(marked, slotassigns[id])
        follow_links!(marked, slotlinks[id], slotlinks, slotassigns, slothandled)
    end
    return marked
end

"""
    print_with_code(io, src::CodeInfo, edges::CodeEdges)

Interweave display of code and edges.

!!! compat "Julia 1.6"
    This function produces dummy output if suitable support is missing in your version of Julia.

"""
function print_with_code(io::IO, src::CodeInfo, edges::CodeEdges)
    function preprint(io::IO)
        printstyled(io, "Names:", color=:yellow)
        for (name, var) in edges.byname
            print(io, '\n', name, ": ")
            show(io, var)
        end
        printstyled(io, "\nCode:\n", color=:yellow)
    end
    preprint(::IO, ::Int) = nothing
    postprint(::IO) = nothing
    postprint(io::IO, idx::Int, bbchanged::Bool) = postprint_lineedges(io, idx, edges, bbchanged)

    print_with_code(preprint, postprint, io, src)
end

function postprint_lineedges(io::IO, idx::Int, edges::CodeEdges, bbchanged::Bool)
    printstyled(io, bbchanged ? " " : "│", color=:light_black)
    printstyled(io, "             # ", color=:yellow)
    preds, succs = edges.preds[idx], edges.succs[idx]
    printstyled(io, "preds: ", showempty(preds), ", succs: ", showempty(succs), '\n', color=:yellow)
    return nothing
end

function terminal_preds(i::Int, edges::CodeEdges)
    s, covered = BitSet(), BitSet()
    push!(covered, i)
    for p in edges.preds[i]
        terminal_preds!(s, p, edges, covered)
    end
    return s
end
function terminal_preds!(s, j, edges, covered)  # can't be an inner function because it calls itself (Core.Box)
    j ∈ covered && return s
    push!(covered, j)
    preds = edges.preds[j]
    if isempty(preds)
        push!(s, j)
    else
        for p in preds
            terminal_preds!(s, p, edges, covered)
        end
    end
    return s
end

"""
    isrequired = lines_required(obj::GlobalRef, src::CodeInfo, edges::CodeEdges)
    isrequired = lines_required(idx::Int,                     src::CodeInfo, edges::CodeEdges)

Determine which lines might need to be executed to evaluate `obj` or the statement indexed by `idx`.
If `isrequired[i]` is `false`, the `i`th statement is *not* required.
In some circumstances all statements marked `true` may be needed, in others control-flow
will end up skipping a subset of such statements, perhaps while repeating others multiple times.

See also [`lines_required!`](@ref) and [`selective_eval!`](@ref).
"""
function lines_required(obj::GlobalRef, src::CodeInfo, edges::CodeEdges; kwargs...)
    isrequired = falses(length(edges.preds))
    objs = Set{GlobalRef}([obj])
    return lines_required!(isrequired, objs, src, edges; kwargs...)
end

function lines_required(idx::Int, src::CodeInfo, edges::CodeEdges; kwargs...)
    isrequired = falses(length(edges.preds))
    isrequired[idx] = true
    objs = Set{GlobalRef}()
    return lines_required!(isrequired, objs, src, edges; kwargs...)
end

"""
    lines_required!(isrequired::AbstractVector{Bool}, src::CodeInfo, edges::CodeEdges;
                    norequire = ())

Like `lines_required`, but where `isrequired[idx]` has already been set to `true` for all statements
that you know you need to evaluate. All other statements should be marked `false` at entry.
On return, the complete set of required statements will be marked `true`.

`norequire` keyword argument specifies statements (represented as iterator of `Int`s) that
should _not_ be marked as a requirement.
For example, use `norequire = LoweredCodeUtils.exclude_named_typedefs(src, edges)` if you're
extracting method signatures and not evaluating new definitions.
"""
function lines_required!(isrequired::AbstractVector{Bool}, src::CodeInfo, edges::CodeEdges; kwargs...)
    objs = Set{GlobalRef}()
    return lines_required!(isrequired, objs, src, edges; kwargs...)
end

function exclude_named_typedefs(src::CodeInfo, edges::CodeEdges)
    norequire = BitSet()
    i = 1
    nstmts = length(src.code)
    while i <= nstmts
        stmt = getrhs(src.code[i])
        if istypedef(stmt) && !isanonymous_typedef(stmt::Expr)
            r = typedef_range(src, i)
            pushall!(norequire, r)
            i = last(r)+1
        else
            i += 1
        end
    end
    return norequire
end

function lines_required!(isrequired::AbstractVector{Bool}, objs, src::CodeInfo, edges::CodeEdges; norequire = ())
    # Mark any requested objects (their lines of assignment)
    objs = add_requests!(isrequired, objs, edges, norequire)

    # Compute basic blocks, which we'll use to make sure we mark necessary control-flow
    cfg = compute_basic_blocks(src.code)  # needed for control-flow analysis
    postdomtree = construct_postdomtree(cfg.blocks)

    # We'll mostly use generic graph traversal to discover all the lines we need,
    # but structs are in a bit of a different category (especially on Julia 1.5+).
    # It's easiest to discover these at the beginning.
    typedefs = find_typedefs(src)

    changed = true
    iter = 0
    while changed
        changed = false

        # Handle ssa predecessors
        changed |= add_ssa_preds!(isrequired, src, edges, norequire)

        # Handle named dependencies
        changed |= add_named_dependencies!(isrequired, edges, objs, norequire)

        # Add control-flow
        changed |= add_control_flow!(isrequired, src, cfg, postdomtree)

        # So far, everything is generic graph traversal. Now we add some domain-specific information
        changed |= add_typedefs!(isrequired, src, edges, typedefs, norequire)
        changed |= add_inplace!(isrequired, src, edges, norequire)

        iter += 1  # just for diagnostics
    end

    # now mark the active goto nodes
    add_active_gotos!(isrequired, src, cfg, postdomtree)

    return isrequired
end

function add_requests!(isrequired, objs, edges::CodeEdges, norequire)
    objsnew = Set{GlobalRef}()
    for obj in objs
        add_obj!(isrequired, objsnew, obj, edges, norequire)
    end
    return objsnew
end

function add_ssa_preds!(isrequired, src::CodeInfo, edges::CodeEdges, norequire)
    changed = false
    for idx = 1:length(src.code)
        if isrequired[idx]
            changed |= add_preds!(isrequired, idx, edges, norequire)
        end
    end
    return changed
end

function add_named_dependencies!(isrequired, edges::CodeEdges, objs, norequire)
    changed = false
    for (obj, uses) in edges.byname
        obj ∈ objs && continue
        if any(view(isrequired, uses.succs))
            changed |= add_obj!(isrequired, objs, obj, edges, norequire)
        end
    end
    return changed
end

function add_preds!(isrequired, idx, edges::CodeEdges, norequire)
    chngd = false
    preds = edges.preds[idx]
    for p in preds
        isrequired[p] && continue
        p ∈ norequire && continue
        isrequired[p] = true
        chngd = true
        add_preds!(isrequired, p, edges, norequire)
    end
    return chngd
end
function add_succs!(isrequired, idx, edges::CodeEdges, succs, norequire)
    chngd = false
    for p in succs
        isrequired[p] && continue
        p ∈ norequire && continue
        isrequired[p] = true
        chngd = true
        add_succs!(isrequired, p, edges, edges.succs[p], norequire)
    end
    return chngd
end
function add_obj!(isrequired, objs, obj::GlobalRef, edges::CodeEdges, norequire)
    chngd = false
    for p in edges.byname[obj].preds
        p ∈ norequire && continue
        isrequired[p] && continue
        isrequired[p] = true
        chngd = true
    end
    for d in edges.byname[obj].assigned
        d ∈ norequire && continue
        isrequired[d] && continue
        isrequired[d] || add_preds!(isrequired, d, edges, norequire)
        isrequired[d] = true
        chngd = true
    end
    push!(objs, obj)
    return chngd
end

## Add control-flow


# The goal of this function is to request concretization of the minimal necessary control
# flow to evaluate statements whose concretization have already been requested.
# The basic algorithm is based on what was proposed in [^Wei84]. If there is even one active
# block in the blocks reachable from a conditional branch up to its successors' nearest
# common post-dominator (referred to as 𝑰𝑵𝑭𝑳 in the paper), it is necessary to follow
# that conditional branch and execute the code. Otherwise, execution can be short-circuited
# from the conditional branch to the nearest common post-dominator.
#
# COMBAK: It is important to note that in Julia's intermediate code representation (`CodeInfo`),
# "short-circuiting" a specific code region is not a simple task. Simply ignoring the path
# to the post-dominator does not guarantee fall-through to the post-dominator. Therefore,
# a more careful implementation is required for this aspect.
#
# [Wei84]: M. Weiser, "Program Slicing," IEEE Transactions on Software Engineering, 10, pages 352-357, July 1984.
function add_control_flow!(isrequired, src::CodeInfo, cfg::CFG, postdomtree)
    local changed::Bool = false
    function mark_isrequired!(idx::Int)
        if !isrequired[idx]
            changed |= isrequired[idx] = true
            return true
        end
        return false
    end
    for bbidx = 1:length(cfg.blocks) # forward traversal
        bb = cfg.blocks[bbidx]
        nsuccs = length(bb.succs)
        if nsuccs == 0
            continue
        elseif nsuccs == 1
            continue # leave a fall-through terminator unmarked: `GotoNode`s are marked later
        elseif nsuccs == 2
            termidx = bb.stmts[end]
            @assert is_conditional_terminator(src.code[termidx]) "invalid IR"
            if is_conditional_block_active(isrequired, bb, cfg, postdomtree)
                mark_isrequired!(termidx)
            else
                # fall-through to the post dominator block (by short-circuiting all statements between)
            end
        end
    end
    return changed
end

is_conditional_terminator(@nospecialize stmt) = stmt isa GotoIfNot ||
    (@static @isdefined(EnterNode) ? stmt isa EnterNode : isexpr(stmt, :enter))

function is_conditional_block_active(isrequired, bb::BasicBlock, cfg::CFG, postdomtree)
    return visit_𝑰𝑵𝑭𝑳_blocks(bb, cfg, postdomtree) do postdominator::Int, 𝑰𝑵𝑭𝑳::BitSet
        for blk in 𝑰𝑵𝑭𝑳
            if blk == postdominator
                continue # skip the post-dominator block and continue to a next infl block
            end
            if any(@view isrequired[cfg.blocks[blk].stmts])
                return true
            end
        end
        return false
    end
end

function visit_𝑰𝑵𝑭𝑳_blocks(func, bb::BasicBlock, cfg::CFG, postdomtree)
    succ1, succ2 = bb.succs
    postdominator = nearest_common_dominator(postdomtree, succ1, succ2)
    𝑰𝑵𝑭𝑳 = reachable_blocks(cfg, succ1, postdominator) ∪ reachable_blocks(cfg, succ2, postdominator)
    return func(postdominator, 𝑰𝑵𝑭𝑳)
end

function reachable_blocks(cfg, from_bb::Int, to_bb::Int)
    worklist = Int[from_bb]
    visited = BitSet(from_bb)
    if to_bb == from_bb
        return visited
    end
    push!(visited, to_bb)
    function visit!(bb::Int)
        if bb ∉ visited
            push!(visited, bb)
            push!(worklist, bb)
        end
    end
    while !isempty(worklist)
        foreach(visit!, cfg.blocks[pop!(worklist)].succs)
    end
    return visited
end

function add_active_gotos!(isrequired, src::CodeInfo, cfg::CFG, postdomtree)
    dead_blocks = compute_dead_blocks(isrequired, src, cfg, postdomtree)
    changed = false
    for bbidx = 1:length(cfg.blocks)
        if bbidx ∉ dead_blocks
            bb = cfg.blocks[bbidx]
            nsuccs = length(bb.succs)
            if nsuccs == 1
                termidx = bb.stmts[end]
                if src.code[termidx] isa GotoNode
                    changed |= isrequired[termidx] = true
                end
            end
        end
    end
    return changed
end

# find dead blocks using the same approach as `add_control_flow!`, for the converged `isrequired`
function compute_dead_blocks(isrequired, src::CodeInfo, cfg::CFG, postdomtree)
    dead_blocks = BitSet()
    for bbidx = 1:length(cfg.blocks)
        bb = cfg.blocks[bbidx]
        nsuccs = length(bb.succs)
        if nsuccs == 2
            termidx = bb.stmts[end]
            @assert is_conditional_terminator(src.code[termidx]) "invalid IR"
            visit_𝑰𝑵𝑭𝑳_blocks(bb, cfg, postdomtree) do postdominator::Int, 𝑰𝑵𝑭𝑳::BitSet
                is_𝑰𝑵𝑭𝑳_active = false
                for blk in 𝑰𝑵𝑭𝑳
                    if blk == postdominator
                        continue # skip the post-dominator block and continue to a next infl block
                    end
                    if any(@view isrequired[cfg.blocks[blk].stmts])
                        is_𝑰𝑵𝑭𝑳_active |= true
                        break
                    end
                end
                if !is_𝑰𝑵𝑭𝑳_active
                    union!(dead_blocks, delete!(𝑰𝑵𝑭𝑳, postdominator))
                end
            end
        end
    end
    return dead_blocks
end

# Do a traveral of "numbered" predecessors and find statement ranges and names of type definitions
function find_typedefs(src::CodeInfo)
    typedef_blocks, typedef_names = UnitRange{Int}[], Symbol[]
    i = 1
    nstmts = length(src.code)
    while i <= nstmts
        stmt = getrhs(src.code[i])
        if istypedef(stmt) && !isanonymous_typedef(stmt::Expr)
            stmt = stmt::Expr
            r = typedef_range(src, i)
            push!(typedef_blocks, r)
            name = stmt.head === :call ? stmt.args[3] : stmt.args[1]
            if isa(name, QuoteNode)
                name = name.value
            end
            isa(name, Symbol) || @show src i r stmt
            push!(typedef_names, name::Symbol)
            i = last(r)+1
        else
            i += 1
        end
    end
    return typedef_blocks, typedef_names
end

# New struct definitions, including their constructors, get spread out over many
# statements. If we're evaluating any of them, it's important to evaluate *all* of them.
function add_typedefs!(isrequired, src::CodeInfo, edges::CodeEdges, (typedef_blocks, typedef_names), norequire)
    changed = false
    stmts = src.code
    idx = 1
    while idx < length(stmts)
        stmt = stmts[idx]
        isrequired[idx] || (idx += 1; continue)
        for (typedefr, typedefn) in zip(typedef_blocks, typedef_names)
            if idx ∈ typedefr
                ireq = view(isrequired, typedefr)
                if !all(ireq)
                    changed = true
                    ireq .= true
                    # Also mark any by-type constructor(s) associated with this typedef
                    var = get(edges.byname, typedefn, nothing)
                    if var !== nothing
                        for s in var.succs
                            s ∈ norequire && continue
                            stmt2 = stmts[s]
                            if isexpr(stmt2, :method) && (fname = (stmt2::Expr).args[1]; fname === false || fname === nothing)
                                isrequired[s] = true
                            end
                        end
                    end
                end
                idx = last(typedefr) + 1
                continue
            end
        end
        # Anonymous functions may not yet include the method definition
        if isanonymous_typedef(stmt)
            i = idx + 1
            while i <= length(stmts) && !ismethod3(stmts[i])
                i += 1
            end
            if i <= length(stmts) && (stmts[i]::Expr).args[1] == false
                tpreds = terminal_preds(i, edges)
                if minimum(tpreds) == idx && i ∉ norequire
                    changed |= !isrequired[i]
                    isrequired[i] = true
                end
            end
        end
        idx += 1
    end
    return changed
end

# For arrays, add any `push!`, `pop!`, `empty!` or `setindex!` statements
# This is needed for the "Modify @enum" test in Revise
function add_inplace!(isrequired, src, edges, norequire)
    function mark_if_inplace(stmt, j)
        _changed = false
        fname = stmt.args[1]
        if (callee_matches(fname, Base, :push!) ||
            callee_matches(fname, Base, :pop!) ||
            callee_matches(fname, Base, :empty!) ||
            callee_matches(fname, Base, :setindex!))
            _changed = !isrequired[j]
            isrequired[j] = true
        end
        return _changed
    end

    changed = false
    for (i, isreq) in pairs(isrequired)
        isreq || continue
        for j in edges.succs[i]
            j ∈ norequire && continue
            stmt = src.code[j]
            if isexpr(stmt, :call) && length(stmt.args) >= 2
                arg = stmt.args[2]
                if @isssa(arg) && arg.id == i
                    changed |= mark_if_inplace(stmt, j)
                elseif @issslotnum(arg)
                    id = arg.id
                    # Check to see if we use this slot
                    for k in edges.preds[j]
                        isrequired[k] || continue
                        predstmt = src.code[k]
                        if (lhs_rhs = get_lhs_rhs(predstmt); lhs_rhs !== nothing)
                            lhs, _ = lhs_rhs
                            if @issslotnum(lhs) && lhs.id == id
                                changed |= mark_if_inplace(stmt, j)
                                break
                            end
                        end
                    end
                end
            end
        end
    end
    return changed
end

"""
    struct SelectiveInterpreter{S<:Interpreter,T<:AbstractVector{Bool}} <: Interpreter
        inner::S
        isrequired::T
    end

An `JuliaInterpreter.Interpreter` that executes only the statements marked `true` in `isrequired`.
Note that this interpreter does not recurse into callee frames.
That is, when `JuliaInterpreter.finish!(interp::SelectiveInterpreter, frame, ...)` is
performed, the `frame` will be executed selectively according to `interp.isrequired`, but
any callee frames within it will be executed by `interp.inner::Interpreter`, not by `interp`.
"""
struct SelectiveInterpreter{S<:Interpreter,T<:AbstractVector{Bool}} <: Interpreter
    inner::S
    isrequired::T
end
function JuliaInterpreter.step_expr!(interp::SelectiveInterpreter, frame::Frame, istoplevel::Bool)
    pc = frame.pc
    if interp.isrequired[pc]
        step_expr!(interp.inner, frame::Frame, istoplevel::Bool)
    else
        next_or_nothing!(interp, frame)
    end
end
function JuliaInterpreter.get_return(interp::SelectiveInterpreter, frame::Frame)
    pc = frame.pc
    node = pc_expr(frame, pc)
    if is_return(node)
        if interp.isrequired[pc]
            return lookup_return(interp.inner, frame, node)
        end
    else
        if isassigned(frame.framedata.ssavalues, pc)
            return frame.framedata.ssavalues[pcexec]
        end
    end
    return nothing
end

"""
    selective_eval!([interp::Interpreter=RecursiveInterpreter()], frame::Frame, isrequired::AbstractVector{Bool}, istoplevel=false)

Execute the code in `frame` in the manner of `JuliaInterpreter.finish_and_return!`,
but skipping all statements that are marked `false` in `isrequired`.
See [`lines_required`](@ref). Upon entry, if needed the caller must ensure that `frame.pc` is
set to the correct statement, typically `findfirst(isrequired)`.
See [`selective_eval_fromstart!`](@ref) to have that performed automatically.

`isrequired` pertains only to `frame` itself, not any of its callees.

This will return either a `BreakpointRef`, the value obtained from the last executed statement
(if stored to `frame.framedata.ssavlues`), or `nothing`.
Typically, assignment to a variable binding does not result in an ssa store by JuliaInterpreter.
"""
selective_eval!(interp::Interpreter, frame::Frame, isrequired::AbstractVector{Bool}, istoplevel::Bool=false) =
    JuliaInterpreter.finish_and_return!(SelectiveInterpreter(interp, isrequired), frame, istoplevel)
selective_eval!(args...) = selective_eval!(RecursiveInterpreter(), args...)

"""
    selective_eval_fromstart!([interp::Interpreter=RecursiveInterpreter()], frame, isrequired, istoplevel=false)

Like [`selective_eval!`](@ref), except it sets `frame.pc` to the first `true` statement in `isrequired`.
"""
function selective_eval_fromstart!(interp::Interpreter, frame, isrequired, istoplevel::Bool=false)
    pc = findfirst(isrequired)
    pc === nothing && return nothing
    frame.pc = pc
    return selective_eval!(interp, frame, isrequired, istoplevel)
end
selective_eval_fromstart!(args...) = selective_eval_fromstart!(RecursiveInterpreter(), args...)

"""
    print_with_code(io, src::CodeInfo, isrequired::AbstractVector{Bool})

Mark each line of code with its requirement status.

!!! compat "Julia 1.6"
    This function produces dummy output if suitable support is missing in your version of Julia.

"""
function print_with_code(io::IO, src::CodeInfo, isrequired::AbstractVector{Bool})
    nd = ndigits(length(isrequired))
    preprint(::IO) = nothing
    preprint(io::IO, idx::Int) = (c = isrequired[idx]; printstyled(io, lpad(idx, nd), ' ', c ? "t " : "f "; color = c ? :cyan : :plain))
    postprint(::IO) = nothing
    postprint(::IO, idx::Int, bbchanged::Bool) = nothing

    print_with_code(preprint, postprint, io, src)
end

function print_with_code(io::IO, frame::Frame, obj)
    src = frame.framecode.src
    src = copy(src)
    JuliaInterpreter.reverse_lookup_globalref!(src.code)
    print_with_code(io, src, obj)
end
