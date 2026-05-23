module test_docs

using Test
using JETLS
using Markdown: Markdown

# Fixtures
meth_concrete(::Int) = nothing
meth_noargs() = nothing
meth_multi(::Int, _::String) = nothing
meth_vararg(::Int...) = nothing
meth_two_tvars(::T, ::S) where {T,S} = nothing
meth_with_sparam(::T) where T<:Union{Float32,Float64} = nothing

@testset "method_doc_sig" begin
    @test JETLS.method_doc_sig(only(methods(meth_concrete, (Int,)))) == Tuple{Int}
    @test JETLS.method_doc_sig(only(methods(meth_noargs, ()))) == Tuple{}
    @test JETLS.method_doc_sig(only(methods(meth_multi, (Int, String)))) == Tuple{Int, String}
    @test JETLS.method_doc_sig(only(methods(meth_vararg, (Vararg{Int},)))) == Tuple{Vararg{Int}}
    @test JETLS.method_doc_sig(only(methods(meth_two_tvars, (Int, String)))) == Tuple{T, S} where {T, S}
    @test JETLS.method_doc_sig(only(methods(meth_with_sparam, (Float64,)))) ==
        Tuple{<:Union{Float32,Float64}}
end

# Fixtures for renamed-import handling in `DocsBinding`. Each module uses
# `using Base: ... as ...` so the local symbol differs from the canonical
# name — the case JuliaLang/julia#55119 fails on without the workaround.
module M_module_rename
    using Base: Base as B
end
module M_function_rename
    using Base: sum as mysum
end

# Sample bindings exercised across the lookup tests.
module M_docs_sample
    """Generic doc for `op`."""
    op(x) = x
    """Method-specific doc for `op(::Int)`."""
    op(x::Int) = x + 1

    """Interface-level doc for `iface`."""
    function iface end
    """Method-specific doc for `iface(::Int)`."""
    iface(x::Int) = x + 1

    """Doc for `gen(::Vector{T})`."""
    gen(a::Vector{T}) where T = a
    gen(a::AbstractVector) = a  # no doc on this method

    undoc(x::Int) = x  # no doc
    """Doc for `undoc(::String)`."""
    undoc(x::String) = x

    nodoc(x) = x  # binding with no docstring on any method
end

# Captured after the fixture modules above are defined so `invoke_in_world`
# calls in `lookup_doc_for_*` reach a world that can see them (avoids
# Julia 1.12+ "access to binding in a world prior to its definition world").
const world = Base.get_world_counter()

@testset "DocsBinding resolves `as`-renamed imports" begin
    # Module rename: `B === Base`, canonical binding is the Base module's
    # self-reference (normalised to `(Main, :Base)` by Binding's module-symbol
    # rule), not the non-existent `Base.B`.
    b = JETLS.DocsBinding(M_module_rename, :B, world)
    @test b.var === :Base

    # Function rename: canonical is `Base.sum`, not the non-existent `Base.mysum`.
    b = JETLS.DocsBinding(M_function_rename, :mysum, world)
    @test b.mod === Base
    @test b.var === :sum
end

@testset "narrow_doc_lookup" begin
    b_op = Base.Docs.Binding(M_docs_sample, :op)

    @testset "method-specific match wins, generic doc still surfaced via intersect" begin
        md = JETLS.narrow_doc_lookup(b_op, Tuple{Int}, world)
        @test md isa Markdown.MD
        s = string(md)
        # Both `op(x)` generic (Tuple{Any}, intersects with Tuple{Int}) and
        # `op(::Int)` specific are kept.
        @test occursin("Generic doc for `op`.", s)
        @test occursin("Method-specific doc for `op(::Int)`.", s)
    end

    @testset "unrelated overload suppressed" begin
        # Tuple{String} matches the String overload only; Int's doc dropped.
        md = JETLS.narrow_doc_lookup(b_op, Tuple{String}, world)
        @test md isa Markdown.MD
        s = string(md)
        @test occursin("Generic doc for `op`.", s)  # generic still covers it
        @test !occursin("Method-specific doc for `op(::Int)`.", s)
    end

    @testset "interface-decl doc dropped when method-specific match found" begin
        b_iface = Base.Docs.Binding(M_docs_sample, :iface)
        md = JETLS.narrow_doc_lookup(b_iface, Tuple{Int}, world)
        @test md isa Markdown.MD
        s = string(md)
        @test occursin("Method-specific doc for `iface(::Int)`.", s)
        @test !occursin("Interface-level doc for `iface`.", s)
    end

    @testset "interface-decl doc serves as fallback when no method match" begin
        b_iface = Base.Docs.Binding(M_docs_sample, :iface)
        # `Tuple{Float64}` doesn't intersect with `Tuple{Int}` — only `Union{}`
        # interface declaration survives.
        md = JETLS.narrow_doc_lookup(b_iface, Tuple{Float64}, world)
        @test md isa Markdown.MD
        s = string(md)
        @test occursin("Interface-level doc for `iface`.", s)
        @test !occursin("Method-specific doc for `iface(::Int)`.", s)
    end

    @testset "no match, no interface → nothing" begin
        b_undoc = Base.Docs.Binding(M_docs_sample, :undoc)
        # Dispatch on `Tuple{Int}` lands on the doc-less `undoc(::Int)` method;
        # the only stored key is `Tuple{String}` which doesn't intersect.
        md = JETLS.narrow_doc_lookup(b_undoc, Tuple{Int}, world)
        @test md === nothing
    end

    @testset "msig <: sig direction (specific doc surfaced under abstract dispatch)" begin
        b_gen = Base.Docs.Binding(M_docs_sample, :gen)
        # Dispatch sig is `Tuple{AbstractVector}` (the doc-less method).
        # Stored key is `Tuple{Vector{T}} where T` — `<:` fails in the forward
        # direction, but intersection picks up `Vector{T}` as a useful proxy.
        md = JETLS.narrow_doc_lookup(b_gen, Tuple{AbstractVector}, world)
        @test md isa Markdown.MD
        @test occursin("Doc for `gen(::Vector{T})`.", string(md))
    end

    @testset "Base.filter cases" begin
        b_filter = Base.Docs.Binding(Base, :filter)

        # `filter(f, a::Array{T,N})`'s docstring is keyed on `Tuple{Any, Array{T,N}}`
        # in its docsystem-mangled union form. `Tuple{Any, Vector{Int}}` intersects.
        md = JETLS.narrow_doc_lookup(b_filter, Tuple{Any, Vector{Int}}, world)
        @test md isa Markdown.MD
        @test occursin("filter(f, a)", string(md))

        # `Tuple{Any, AbstractArray}` doesn't `<:` the Array-keyed doc, but
        # intersection (= `Vector` etc.) still surfaces the generic doc.
        md = JETLS.narrow_doc_lookup(b_filter, Tuple{Any, AbstractArray}, world)
        @test md isa Markdown.MD
        @test occursin("filter(f, a)", string(md))

        # `Dict` intersects with `Tuple{Any, AbstractDict}` only.
        md = JETLS.narrow_doc_lookup(b_filter, Tuple{Any, Dict{Int,String}}, world)
        @test md isa Markdown.MD
        s = string(md)
        @test occursin("filter(f, d::AbstractDict)", s)
        @test !occursin("filter(f, a::Array", s)
    end

    @testset "Base.push! cross-module noise suppression" begin
        # `Compiler.EscapeAnalysis` registers a `push!(::IntDisjointSet)` doc
        # under the canonical `Binding(Base, :push!)` (the Binding constructor
        # normalises across re-imports). `Base.Docs.doc`'s all-docs fallback
        # would surface it on any `push!` lookup; intersection-based narrowing
        # keeps only the Base interface doc since EA's `Tuple{IntDisjointSet}`
        # key has empty intersection with `Tuple{Vector{Int}, Int}`.
        b_push = Base.Docs.Binding(Base, :push!)
        md = JETLS.narrow_doc_lookup(b_push, Tuple{Vector{Int}, Int}, world)
        @test md isa Markdown.MD
        s = string(md)
        @test occursin("push!(collection, items...)", s)  # Base interface doc kept
        @test !occursin("IntDisjointSet", s)              # EA's doc filtered out
    end
end

@testset "lookup_doc_for_binding" begin
    @testset "with sig narrows" begin
        md = JETLS.lookup_doc_for_binding(M_docs_sample, :op, Tuple{Int}, world)
        @test md isa Markdown.MD
        s = string(md)
        @test occursin("Method-specific doc for `op(::Int)`.", s)
    end

    @testset "with sig=nothing returns full Base.Docs.doc" begin
        # Without narrowing both the generic and Int-specific docs come back.
        md = JETLS.lookup_doc_for_binding(M_docs_sample, :op, nothing, world)
        @test md isa Markdown.MD
        s = string(md)
        @test occursin("Generic doc for `op`.", s)
        @test occursin("Method-specific doc for `op(::Int)`.", s)
    end

    @testset "non-existent binding returns nothing" begin
        @test JETLS.lookup_doc_for_binding(M_docs_sample, :nonexistent, nothing, world) === nothing
        @test JETLS.lookup_doc_for_binding(M_docs_sample, :nonexistent, Tuple{Int}, world) === nothing
    end

    @testset "undocumented binding strips the 'No documentation found' placeholder" begin
        md = JETLS.lookup_doc_for_binding(M_docs_sample, :nodoc, nothing, world)
        @test md isa Markdown.MD
        s = string(md)
        @test !occursin("No documentation found", s)
        # The auto-generated summary that follows the placeholder should
        # survive so the hover surface still has something informative.
        @test occursin("nodoc", s)
    end
end

@testset "lookup_doc_for_value" begin
    @testset "non-documentable value returns nothing" begin
        @test JETLS.lookup_doc_for_value(42, Tuple{Int}, world) === nothing
        @test JETLS.lookup_doc_for_value("hello", Tuple{String}, world) === nothing
        @test JETLS.lookup_doc_for_value(nothing, nothing, world) === nothing
    end

    @testset "Function value with sig narrows via aliasof" begin
        # `aliasof(filter, typeof(filter))` lands on `Base.filter`'s binding;
        # the dict sig intersects only `Tuple{Any, AbstractDict}`.
        md = JETLS.lookup_doc_for_value(filter, Tuple{Any, Dict{Int,String}}, world)
        @test md isa Markdown.MD
        @test length(md.content) == 1
        @test occursin("filter(f, d::AbstractDict)", string(md))
    end

    @testset "Function value with sig=nothing returns full Base.Docs.doc" begin
        md = JETLS.lookup_doc_for_value(filter, nothing, world)
        @test md isa Markdown.MD
        # Without narrowing all four `Base.filter` docs are concatenated.
        @test length(md.content) >= 4
    end

    @testset "Module value with sig=nothing returns full Base.Docs.doc" begin
        md = JETLS.lookup_doc_for_value(Base, nothing, world)
        @test md isa Markdown.MD
    end
end

end # module test_docs
