module test_syntax_tree_cache

using Test
using JETLS
using JETLS: JS, SyntaxTree
using JETLS.LSP
using JETLS.URIs2

# Every node reachable from `root` through children and provenance, mapped to its
# field values and a copy of its children vector
function snapshot_tree(root::SyntaxTree)
    snapshot = IdDict{SyntaxTree,Tuple{Tuple,Union{Nothing,Vector{SyntaxTree}}}}()
    stack = SyntaxTree[root]
    while !isempty(stack)
        st = pop!(stack)
        haskey(snapshot, st) && continue
        cs = getfield(st, :children)
        snapshot[st] = (ntuple(i -> getfield(st, i), fieldcount(SyntaxTree)),
                        cs === nothing ? nothing : copy(cs))
        cs === nothing || append!(stack, cs)
        src = getfield(st, :source)
        src isa SyntaxTree && push!(stack, src)
    end
    return snapshot
end

function is_same_snapshot(a::IdDict, b::IdDict)
    length(a) == length(b) || return false
    for (st, (fields, cs)) in a
        (fields′, cs′) = @something get(b, st, nothing) return false
        fields === fields′ || return false
        if cs === nothing || cs′ === nothing
            cs === cs′ || return false
        else
            length(cs) == length(cs′) || return false
            all(i -> cs[i] === cs′[i], eachindex(cs)) || return false
        end
    end
    return true
end

const CODE = raw"""
module SyntaxTreeCacheTarget

using Test
import Base: show

\"\"\"
    Point{T<:Real}

A point in the plane.
\"\"\"
struct Point{T<:Real}
    x::T
    y::T
end

Base.show(io::IO, p::Point) = print(io, "Point(", p.x, ", ", p.y, ")")

Base.@kwdef mutable struct Counter
    name::String = "default"
    count::Int = 0
end

@inline norm2(p::Point) = p.x^2 + p.y^2

Base.@constprop :none function update!(c::Counter, xs::Vector{Int}; scale::Int = 2)
    total = 0
    for (i, x) in enumerate(xs)
        total += x * scale
        c.count += i
    end
    ys = [x + 1 for x in xs if isodd(x)]
    f = y -> y + total
    msg = lazy"updated $(c.name) with $(length(ys)) items"
    @assert total >= 0 msg
    @info "done" total
    return f(total), ys
end

macro double(ex)
    return :(2 * $(esc(ex)))
end

const PATTERN = r"[a-z]+"
const DOUBLED = @double 21
const PLATFORM = @static Sys.iswindows() ? "windows" : "other"
task = Threads.@spawn sum(1:10)
view_sum(xs) = sum(@view xs[1:2])
pair = let a = 1, b = 2
    (a, b)
end
broken = (1 + )
include("other.jl")

@testset "update!" begin
    c = Counter()
    @test update!(c, [1, 2, 3])[1] > 0
    @test_throws MethodError update!(c, "x")
    @inferred norm2(Point(1.0, 2.0))
end

end # module SyntaxTreeCacheTarget
"""

@testset "snapshot_tree detects mutation" begin
    for mutate! in (
            st::SyntaxTree -> JS.setmeta!(st[1], :mutated, true),
            st::SyntaxTree -> push!(JS.children(st[1]), st[1][1]),
            st::SyntaxTree -> setfield!(st[1][1], :value, :mutated))
        fi = JETLS.FileInfo(#=version=#1, "f(x) = x + 1", "test.jl"; cache_tree0=true)
        st0 = fi.syntax_tree0::SyntaxTree
        snapshot = snapshot_tree(st0)
        @test is_same_snapshot(snapshot, snapshot_tree(st0))
        mutate!(st0)
        @test !is_same_snapshot(snapshot, snapshot_tree(st0))
    end
end

# Requests share the cached `syntax_tree0` of a synchronized document without copying it,
# so no consumer may mutate it
@testset "cached syntax tree is not mutated" begin
    server = JETLS.Server()
    state = server.state
    filename = joinpath(@__DIR__, "testfile_syntax_tree_cache.jl")
    uri = filename2uri(filename)
    fi = JETLS.cache_file_info!(server, uri, #=version=#1, CODE)
    st0 = fi.syntax_tree0::SyntaxTree
    @test JETLS.build_syntax_tree(fi) === st0
    snapshot = snapshot_tree(st0)
    is_unchanged() = is_same_snapshot(snapshot, snapshot_tree(st0))

    context_module = @__MODULE__
    world = Base.get_world_counter()
    full_range = Range(;
        start = Position(; line = 0, character = 0),
        var"end" = JETLS.offset_to_xy(fi, sizeof(CODE) + 1))
    positions = Position[JETLS.offset_to_xy(fi, m.offset)
        for m in eachmatch(r"\b[A-Za-z_]\w*", CODE)]
    call_bytes = Int[i + 1 for i in findall(in(('(', ',')), codeunits(CODE))]

    @testset "testsets" begin
        JETLS.compute_testsetinfos!(server, st0, JETLS.EMPTY_TESTSETINFOS)
        @test is_unchanged()
    end
    @testset "diagnostics" begin
        JETLS.get_per_file_diagnostics!(server, uri, fi, JETLS.DUMMY_CANCEL_FLAG)
        @test is_unchanged()
    end
    @testset "document symbols and inlay hints" begin
        symbols = JETLS.get_document_symbols!(state, uri, fi)
        hints = InlayHint[]
        JETLS.syntactic_inlay_hints!(hints, symbols, fi, full_range; min_lines = 0)
        JETLS.type_inlay_hints!(hints, state, fi, JETLS.build_syntax_tree(fi), uri, full_range)
        for hint in hints
            JETLS.resolve_inlay_hint(state, hint)
        end
        @test is_unchanged()
    end
    @testset "semantic tokens and document links" begin
        JETLS.compute_semantic_tokens(state, uri, fi)
        JETLS.collect_include_document_links!(DocumentLink[], state, uri, fi)
        @test is_unchanged()
    end
    @testset "signature help" begin
        for b in call_bytes
            JETLS.cursor_siginfos(fi, b, context_module; world)
        end
        @test is_unchanged()
    end
    @testset "hover and navigation" begin
        for pos in positions
            JETLS._get_hover(state, fi, uri, pos; context_module)
            JETLS.find_definition(server, uri, fi, pos; context_module)
            JETLS.find_declaration(server, uri, fi, pos)
            JETLS.find_type_definition(server, uri, fi, pos)
            JETLS.find_references(server, uri, fi, pos)
            JETLS.document_highlights!(DocumentHighlight[], state, uri, fi, pos)
        end
        @test is_unchanged()
    end
    @testset "rename" begin
        for pos in positions
            JETLS.prepare_local_binding_rename(state, uri, fi, pos, context_module, world)
            JETLS.get_local_binding_rename(server, uri, fi, pos, context_module, world, "renamed")
            JETLS.get_global_binding_rename(server, uri, fi, pos, context_module, world, "renamed")
        end
        @test is_unchanged()
    end
    @testset "completions" begin
        snapshot_doc = JETLS.get_document_snapshot(state, uri)::JETLS.DocumentSnapshot
        for pos in positions
            JETLS.get_completion_items(state, uri, snapshot_doc, pos, nothing; context_module)
        end
        @test is_unchanged()
    end
    @testset "code actions" begin
        for pos in positions
            range = Range(; start = pos, var"end" = pos)
            code_actions = Union{CodeAction,Command}[]
            JETLS.macro_expansion_code_actions!(code_actions, server, uri, fi, range)
            JETLS.type_annotation_code_actions!(code_actions, server, uri, fi, range)
            JETLS.testrunner_testcase_code_actions!(code_actions, uri, fi, range)
        end
        @test is_unchanged()
    end
end

end # module test_syntax_tree_cache
