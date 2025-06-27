using JETLS: JS, JL

function parsedstream(s::AbstractString, rule::Symbol=:all)
    stream = JS.ParseStream(s)
    JS.parse!(stream; rule)
    return stream
end

function jsparse(s::AbstractString; ignore_errors=true, kws...)
    JS.build_tree(JS.SyntaxNode, parsedstream(s); filename=@__FILE__, ignore_errors, kws...)
end

function jlparse(s::AbstractString; ignore_errors=true, kws...)
    JS.build_tree(JL.SyntaxTree, parsedstream(s); filename=@__FILE__, ignore_errors, kws...)
end

# For interactive use
# ===================

# dump all intermediate ctx and st into the global scope for inspection
# use `stop` if some lowering pass mutates ctx in a way you don't want
function jldebug(st0_in::JL.SyntaxTree, stop=5)
    global ctx5, st5, ctx4, st4, ctx3, st3, ctx2, st2, ctx1, st1
    stop = stop - 1; stop < 0 && return; ctx1, st1 = JL.expand_forms_1(Module(), st0_in)
    stop = stop - 1; stop < 0 && return; ctx2, st2 = JL.expand_forms_2(ctx1, st1)
    stop = stop - 1; stop < 0 && return; ctx3, st3 = JL.resolve_scopes(ctx2, st2)
    stop = stop - 1; stop < 0 && return; ctx4, st4 = JL.convert_closures(ctx3, st3)
    stop = stop - 1; stop < 0 && return; ctx5, st5 = JL.linearize_ir(ctx4, st4)
    st5
end
function jldebug(s::String, stop=5)
    global st0 = jsparse(s)
    jldebug(st0, stop)
end

# Select a node by ID from a tree (its underlying graph), graph, or ctx
function jlnode(g::JL.SyntaxGraph, i::JL.NodeId)
    t = JL.SyntaxTree(g, i)
    # show(stdout, MIME("text/x.sexpression"), t)
    t
end
function jlnode(st::JL.SyntaxTree, i::JL.NodeId)
    t = JL.SyntaxTree(st._graph, i)
    t
end
function jlnode(ctx::T where {T<:JL.AbstractLoweringContext}, i::JL.NodeId)
    t = JL.SyntaxTree(ctx.graph, i)
end
