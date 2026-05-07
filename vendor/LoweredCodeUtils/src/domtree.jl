# This was copied from Julia's source code (base/compiler/ssair/domtree.jl) and
# unnecessary parts were removed. The original license statement is:

# # This file is a part of Julia. License is MIT: https://julialang.org/license

# A few items needed to be added:

import Base: length, copy, copy!

# END additions


const BBNumber = Int
const PreNumber = Int
const PostNumber = Int

struct DFSTree
    # These map between BB number and pre- or postorder numbers
    to_pre::Vector{PreNumber}
    from_pre::Vector{BBNumber}
    to_post::Vector{PostNumber}
    from_post::Vector{BBNumber}

    # Records parent relationships in the DFS tree
    # (preorder number -> preorder number)
    # Storing it this way saves a few lookups in the snca_compress! algorithm
    to_parent_pre::Vector{PreNumber}
end

function DFSTree(n_blocks::Int)
    return DFSTree(zeros(PreNumber, n_blocks),
                   Vector{BBNumber}(undef, n_blocks),
                   zeros(PostNumber, n_blocks),
                   Vector{BBNumber}(undef, n_blocks),
                   zeros(PreNumber, n_blocks))
end

copy(D::DFSTree) = DFSTree(copy(D.to_pre),
                           copy(D.from_pre),
                           copy(D.to_post),
                           copy(D.from_post),
                           copy(D.to_parent_pre))

function copy!(dst::DFSTree, src::DFSTree)
    copy!(dst.to_pre, src.to_pre)
    copy!(dst.from_pre, src.from_pre)
    copy!(dst.to_post, src.to_post)
    copy!(dst.from_post, src.from_post)
    copy!(dst.to_parent_pre, src.to_parent_pre)
    return dst
end

length(D::DFSTree) = length(D.from_pre)

function DFS!(D::DFSTree, blocks::Vector{BasicBlock}, is_post_dominator::Bool)
    copy!(D, DFSTree(length(blocks)))
    if is_post_dominator
        # TODO: We're using -1 as the virtual exit node here. Would it make
        #       sense to actually have a real BB for the exit always?
        to_visit = Tuple{BBNumber, PreNumber, Bool}[(-1, 0, false)]
    else
        to_visit = Tuple{BBNumber, PreNumber, Bool}[(1, 0, false)]
    end
    pre_num = is_post_dominator ? 0 : 1
    post_num = 1
    while !isempty(to_visit)
        # Because we want the postorder number as well as the preorder number,
        # we don't pop the current node from the stack until we're moving up
        # the tree
        (current_node_bb, parent_pre, pushed_children) = to_visit[end]

        if pushed_children
            # Going up the DFS tree, so all we need to do is record the
            # postorder number, then move on
            if current_node_bb != -1
                D.to_post[current_node_bb] = post_num
                D.from_post[post_num] = current_node_bb
            end
            post_num += 1
            pop!(to_visit)

        elseif current_node_bb != -1 && D.to_pre[current_node_bb] != 0
            # Node has already been visited, move on
            pop!(to_visit)
            continue
        else
            # Going down the DFS tree

            # Record preorder number
            if current_node_bb != -1
                D.to_pre[current_node_bb] = pre_num
                D.from_pre[pre_num] = current_node_bb
                D.to_parent_pre[pre_num] = parent_pre
            end

            # Record that children (will) have been pushed
            to_visit[end] = (current_node_bb, parent_pre, true)

            if is_post_dominator && current_node_bb == -1
                edges = Int[bb for bb in 1:length(blocks) if isempty(blocks[bb].succs)]
            else
                edges = is_post_dominator ? blocks[current_node_bb].preds :
                                            blocks[current_node_bb].succs
            end

            # Push children to the stack
            for succ_bb in edges
                if succ_bb == 0
                    # Edge 0 indicates an error entry, but shouldn't affect
                    # the post-dominator tree.
                    @assert is_post_dominator
                    continue
                end
                push!(to_visit, (succ_bb, pre_num, false))
            end

            pre_num += 1
        end
    end

    # If all blocks are reachable, this is a no-op, otherwise, we shrink these
    # arrays.
    resize!(D.from_pre, pre_num - 1)
    resize!(D.from_post, post_num - 1) # should be same size as pre_num - 1
    resize!(D.to_parent_pre, pre_num - 1)

    return D
end

DFS(blocks::Vector{BasicBlock}, is_post_dominator::Bool=false) = DFS!(DFSTree(0), blocks, is_post_dominator)

"""
Keeps the per-BB state of the Semi NCA algorithm. In the original formulation,
there are three separate length `n` arrays, `label`, `semi` and `ancestor`.
Instead, for efficiency, we use one array in a array-of-structs style setup.
"""
struct SNCAData
    semi::PreNumber
    label::PreNumber
end

"Represents a Basic Block, in the DomTree"
struct DomTreeNode
    # How deep we are in the DomTree
    level::Int
    # The BB indices in the CFG for all Basic Blocks we immediately dominate
    children::Vector{BBNumber}
end

DomTreeNode() = DomTreeNode(1, Vector{BBNumber}())

"Data structure that encodes which basic block dominates which."
struct GenericDomTree{IsPostDom}
    # These can be reused when updating domtree dynamically
    dfs_tree::DFSTree
    snca_state::Vector{SNCAData}

    # Which basic block immediately dominates each basic block, using BB indices
    idoms_bb::Vector{BBNumber}

    # The nodes in the tree (ordered by BB indices)
    nodes::Vector{DomTreeNode}
end
const DomTree = GenericDomTree{false}
const PostDomTree = GenericDomTree{true}

function (T::Type{<:GenericDomTree})()
    return T(DFSTree(0), SNCAData[], BBNumber[], DomTreeNode[])
end

function construct_domtree(blocks::Vector{BasicBlock})
    return update_domtree!(blocks, DomTree(), true, 0)
end

function construct_postdomtree(blocks::Vector{BasicBlock})
    return update_domtree!(blocks, PostDomTree(), true, 0)
end

function update_domtree!(blocks::Vector{BasicBlock}, domtree::GenericDomTree{IsPostDom},
                         recompute_dfs::Bool, max_pre::PreNumber) where {IsPostDom}
    if recompute_dfs
        DFS!(domtree.dfs_tree, blocks, IsPostDom)
    end

    if max_pre == 0
        max_pre = length(domtree.dfs_tree)
    end

    SNCA!(domtree, blocks, max_pre)
    compute_domtree_nodes!(domtree)
    return domtree
end

function compute_domtree_nodes!(domtree::GenericDomTree{IsPostDom}) where {IsPostDom}
    # Compute children
    copy!(domtree.nodes,
          DomTreeNode[DomTreeNode() for _ in 1:length(domtree.idoms_bb)])
    for (idx, idom) in Iterators.enumerate(domtree.idoms_bb)
        ((!IsPostDom && idx == 1) || idom == 0) && continue
        push!(domtree.nodes[idom].children, idx)
    end
    # n.b. now issorted(domtree.nodes[*].children) since idx is sorted above
    # Recursively set level
    if IsPostDom
        for (node, idom) in enumerate(domtree.idoms_bb)
            idom == 0 || continue
            update_level!(domtree.nodes, node, 1)
        end
    else
        update_level!(domtree.nodes, 1, 1)
    end
    return domtree.nodes
end

function update_level!(nodes::Vector{DomTreeNode}, node::BBNumber, level::Int)
    worklist = Tuple{BBNumber, Int}[(node, level)]
    while !isempty(worklist)
        (node, level) = pop!(worklist)
        nodes[node] = DomTreeNode(level, nodes[node].children)
        foreach(nodes[node].children) do child
            push!(worklist, (child, level+1))
        end
    end
end

dom_edges(domtree::DomTree, blocks::Vector{BasicBlock}, idx::BBNumber) =
    blocks[idx].preds
dom_edges(domtree::PostDomTree, blocks::Vector{BasicBlock}, idx::BBNumber) =
    blocks[idx].succs

"""
The main Semi-NCA algorithm. Matches Figure 2.8 in [LG05]. Note that the
pseudocode in [LG05] is not entirely accurate. The best way to understand
what's happening is to read [LT79], then the description of SLT in [LG05]
(warning: inconsistent notation), then the description of Semi-NCA.
"""
function SNCA!(domtree::GenericDomTree{IsPostDom}, blocks::Vector{BasicBlock}, max_pre::PreNumber) where {IsPostDom}
    D = domtree.dfs_tree
    state = domtree.snca_state
    # There may be more blocks than are reachable in the DFS / dominator tree
    n_blocks = length(blocks)
    n_nodes = length(D)

    # `label` is initialized to the identity mapping (though the paper doesn't
    # make that clear). The rationale for this is Lemma 2.4 in [LG05] (i.e.
    # Theorem 4 in [LT79]). Note however, that we don't ever look at `semi`
    # until it is fully initialized, so we could leave it uninitialized here if
    # we wanted to.
    resize!(state, n_nodes)
    for w in 1:max_pre
        # Only reset semidominators for nodes we want to recompute
        state[w] = SNCAData(typemax(PreNumber), w)
    end

    # If we are only recomputing some of the semidominators, the remaining
    # labels should be reset, because they may have become inapplicable to the
    # node/semidominator we are currently processing/recomputing. They can
    # become inapplicable because of path compressions that were triggered by
    # nodes that should only be processed after the current one (but were
    # processed the last time `SNCA!` was run).
    #
    # So, for every node that is not being reprocessed, we reset its label to
    # its semidominator, which is the value that its label assumes once its
    # semidominator is computed. If this was too conservative, i.e. if the
    # label would have been updated before we process the current node in a
    # situation where all semidominators were recomputed, then path compression
    # will produce the correct label.
    for w in max_pre+1:n_nodes
        semi = state[w].semi
        state[w] = SNCAData(semi, semi)
    end

    # Calculate semidominators, but only for blocks with preorder number up to
    # max_pre
    ancestors = copy(D.to_parent_pre)
    relevant_blocks = IsPostDom ? (1:max_pre) : (2:max_pre)
    for w::PreNumber in reverse(relevant_blocks)
        # LLVM initializes this to the parent, the paper initializes this to
        # `w`, but it doesn't really matter (the parent is a predecessor, so at
        # worst we'll discover it below). Save a memory reference here.
        semi_w = typemax(PreNumber)
        last_linked = PreNumber(w + 1)
        for v ∈ dom_edges(domtree, blocks, D.from_pre[w])
            # For the purpose of the domtree, ignore virtual predecessors into
            # catch blocks.
            v == 0 && continue

            v_pre = D.to_pre[v]

            # Ignore unreachable predecessors
            v_pre == 0 && continue

            # N.B.: This conditional is missing from the pseudocode in figure
            # 2.8 of [LG05]. It corresponds to the `ancestor[v] != 0` check in
            # the `eval` implementation in figure 2.6
            if v_pre >= last_linked
                # `v` has already been processed, so perform path compression

                # For performance, if the number of ancestors is small avoid
                # the extra allocation of the worklist.
                if length(ancestors) <= 32
                    snca_compress!(state, ancestors, v_pre, last_linked)
                else
                    snca_compress_worklist!(state, ancestors, v_pre, last_linked)
                end
            end

            # The (preorder number of the) semidominator of a block is the
            # minimum over the labels of its predecessors
            semi_w = min(semi_w, state[v_pre].label)
        end
        state[w] = SNCAData(semi_w, semi_w)
    end

    # Compute immediate dominators, which for a node must be the nearest common
    # ancestor in the (immediate) dominator tree between its semidominator and
    # its parent (see Lemma 2.6 in [LG05]).
    idoms_pre = copy(D.to_parent_pre)
    for v in (IsPostDom ? (1:n_nodes) : (2:n_nodes))
        idom = idoms_pre[v]
        vsemi = state[v].semi
        while idom > vsemi
            idom = idoms_pre[idom]
        end
        idoms_pre[v] = idom
    end

    # Express idoms in BB indexing
    resize!(domtree.idoms_bb, n_blocks)
    for i::BBNumber in 1:n_blocks
        if (!IsPostDom && i == 1) || D.to_pre[i] == 0
            domtree.idoms_bb[i] = 0
        else
            ip = idoms_pre[D.to_pre[i]]
            domtree.idoms_bb[i] = ip == 0 ? 0 : D.from_pre[ip]
        end
    end
end

"""
Matches the snca_compress algorithm in Figure 2.8 of [LG05], with the
modification suggested in the paper to use `last_linked` to determine whether
an ancestor has been processed rather than storing `0` in the ancestor array.
"""
function snca_compress!(state::Vector{SNCAData}, ancestors::Vector{PreNumber},
                        v::PreNumber, last_linked::PreNumber)
    u = ancestors[v]
    @assert u < v
    if u >= last_linked
        snca_compress!(state, ancestors, u, last_linked)
        if state[u].label < state[v].label
            state[v] = SNCAData(state[v].semi, state[u].label)
        end
        ancestors[v] = ancestors[u]
    end
    nothing
end

function snca_compress_worklist!(
        state::Vector{SNCAData}, ancestors::Vector{PreNumber},
        v::PreNumber, last_linked::PreNumber)
    # TODO: There is a smarter way to do this
    u = ancestors[v]
    worklist = Tuple{PreNumber, PreNumber}[(u,v)]
    @assert u < v
    while !isempty(worklist)
        u, v = last(worklist)
        if u >= last_linked
            if ancestors[u] >= last_linked
                push!(worklist, (ancestors[u], u))
                continue
            end
            if state[u].label < state[v].label
                state[v] = SNCAData(state[v].semi, state[u].label)
            end
            ancestors[v] = ancestors[u]
        end
        pop!(worklist)
    end
end

"""
    dominates(domtree::DomTree, bb1::Int, bb2::Int) -> Bool

Checks if `bb1` dominates `bb2`.
`bb1` and `bb2` are indexes into the `CFG` blocks.
`bb1` dominates `bb2` if the only way to enter `bb2` is via `bb1`.
(Other blocks may be in between, e.g `bb1->bbx->bb2`).
"""
dominates(domtree::DomTree, bb1::BBNumber, bb2::BBNumber) =
    _dominates(domtree, bb1, bb2)

"""
    postdominates(domtree::PostDomTree, bb1::Int, bb2::Int) -> Bool

Checks if `bb1` post-dominates `bb2`.
`bb1` and `bb2` are indexes into the `CFG` blocks.
`bb1` post-dominates `bb2` if every pass from `bb2` to the exit is via `bb1`.
(Other blocks may be in between, e.g `bb2->bbx->bb1->exit`).
"""
postdominates(domtree::PostDomTree, bb1::BBNumber, bb2::BBNumber) =
    _dominates(domtree, bb1, bb2)

function _dominates(domtree::GenericDomTree, bb1::BBNumber, bb2::BBNumber)
    bb1 == bb2 && return true
    target_level = domtree.nodes[bb1].level
    source_level = domtree.nodes[bb2].level
    source_level < target_level && return false
    for _ in (source_level - 1):-1:target_level
        bb2 = domtree.idoms_bb[bb2]
    end
    return bb1 == bb2
end

"""
    nearest_common_dominator(domtree::GenericDomTree, a::BBNumber, b::BBNumber)

Compute the nearest common (post-)dominator of `a` and `b`.
"""
function nearest_common_dominator(domtree::GenericDomTree, a::BBNumber, b::BBNumber)
    a == 0 && return a
    b == 0 && return b
    alevel = domtree.nodes[a].level
    blevel = domtree.nodes[b].level
    # W.l.g. assume blevel <= alevel
    if alevel < blevel
        a, b = b, a
        alevel, blevel = blevel, alevel
    end
    while alevel > blevel
        a = domtree.idoms_bb[a]
        alevel -= 1
    end
    while a != b && a != 0
        a = domtree.idoms_bb[a]
        b = domtree.idoms_bb[b]
    end
    @assert a == b
    return a
end
