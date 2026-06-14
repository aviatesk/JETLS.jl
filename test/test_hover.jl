module test_hover

using Test
using JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

# Helper to run hover tests against a script. Caller's `tester` is invoked
# once per cursor position with `(i, result, uri)`.
function with_hover_request(tester, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, clean_code))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            for (i, pos) in enumerate(positions)
                (; raw_res) = writereadmsg(HoverRequest(;
                    id = id_counter[] += 1,
                    params = HoverParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        position = pos)))
                tester(i, raw_res.result, uri)
            end
        end
    end
end

# Single-position hover assertion. `pat === nothing` asserts the hover
# resolves to `null`; otherwise the rendered Markdown must `occursin(pat, …)`.
function single_hover_test(
        text::AbstractString, pat::Union{AbstractString, Regex, Nothing};
        broken::Bool = false
    )
    with_hover_request(text) do _, result, _
        if pat === nothing
            @test result === null
        else
            @test result !== null
            @test result.contents isa MarkupContent
            @test result.contents.kind === MarkupKind.Markdown
            @test occursin(pat, result.contents.value) broken=broken
        end
    end
end

# Test subroutines
@test isnothing(JETLS.hover_type_string(Core.Const(push!), "push!"))

# End-to-end sanity checks that the LSP `textDocument/hover` request/response
# path is wired correctly (`DidOpen` → analysis → `HoverRequest` →
# `MarkupContent`-shaped reply), covering both the `get_hover` (expression)
# branch and the `keyword_hover` fallback that `handle_HoverRequest` reaches
# when `get_hover` returns nothing. Other hover scenarios are covered
# locally via `hover_test` below, which skips the LSP roundtrip and the
# workspace full-analysis.
@testset HierarchicalTestSet "'Hover' request/response sanity" begin
    @testset "expression hover" begin
        single_hover_test("""
            \"\"\"Documented binding.\"\"\"
            const documented_binding = 42
            documented_binding│
        """, "Documented binding.")
    end

    @testset "keyword hover" begin
        single_hover_test("i│f true; 1; end", "performs conditional evaluation")
    end
end

function get_hover(
        text::AbstractString, pos::Position;
        filename::AbstractString = @__FILE__,
        context_module::Union{Nothing,Module} = nothing
    )
    server = JETLS.Server()
    uri = filename2uri(filename)
    fi = JETLS.cache_file_info!(server, uri, 0, text)
    return JETLS.get_hover(server.state, fi, uri, pos; context_module)
end

# `single_hover_test`-shaped assertion that skips the LSP roundtrip — for
# cases that don't depend on workspace full-analysis. `context_module`
# overrides the default `Main` lookup so the test can pre-define globals
# (with docstrings) in a side module and exercise unqualified hover paths
# against them. `notpat` lets a caller additionally assert that some pattern
# is *not* present in the rendered Markdown.
function hover_test(
        text::AbstractString, pat::Union{AbstractString, Regex, Nothing};
        context_module::Union{Nothing,Module} = nothing,
        notpat::Union{AbstractString, Regex, Nothing} = nothing,
        broken::Bool = false
    )
    clean_text, positions = JETLS.get_text_and_positions(text)
    @assert length(positions) == 1
    result = get_hover(clean_text, only(positions); context_module)
    if pat === nothing
        @test result === nothing broken=broken
    else
        @test result isa Hover broken=broken
        @test occursin(pat, result.contents.value) broken=broken
        notpat === nothing ||
            @test !occursin(notpat, result.contents.value) broken=broken
    end
end

# Side modules pre-populated with the user bindings the hover tests below
# need, so `hover_test` can resolve them without running full-analysis on
# the test source — we pass each module as `context_module` to override the
# default `Main` lookup. `using Base: Base as B` etc. takes effect when the
# `module … end` block is evaluated at file-include time.
module M_doc_binding
    """Documented binding."""
    const documented_binding = 42
end
module M_undoc_binding
    const undocumented_binding = 42
end
module M_doc_func
    """Documented method."""
    func(x::Int) = x
end
module M_base_alias
    using Base: Base as B
end
module M_alias_const
    const mycos = cos
end
module M_overloaded
    """Generic doc for `op`."""
    op(x) = x
    """Method-specific doc for `op(::Int)`."""
    op(x::Int) = x + 1
    """Method-specific doc for `op(::String)`."""
    op(x::String) = uppercase(x)
end
module M_iface_overloaded
    # `function iface end` stores its docstring at `Union{}`, and `iface` has no
    # `Tuple{Any}`-keyed method — needed so the "no-match fallback" path is reachable
    # (it's suppressed by any `Any`-accepting method).

    """Interface-level doc for `iface`."""
    function iface end
    """Method-specific doc for `iface(::Int)`."""
    iface(x::Int) = x + 1
end
module M_operator_dispatch
    struct MyArr end
    """Method-specific doc for `getindex(::MyArr, ::Int)`."""
    Base.getindex(::MyArr, ::Int) = 42
end
module M_undoc_dispatch
    # `undoc(::Int)` has no docstring; only `undoc(::String)` is documented.
    # Hover on `undoc(1)` narrows to `Tuple{Int}`, which doesn't `<:` the
    # stored `Tuple{String}` doc key. Suppress the unrelated overload instead
    # of falling back to it.
    undoc(x::Int) = x
    """Doc for `undoc(::String)`."""
    undoc(x::String) = x
end
module M_undoc_abstract_dispatch
    # `gen(::AbstractVector)` has no docstring; only `gen(::Vector{T})` is
    # documented. The dispatched method's sig (`Tuple{AbstractVector}`) is a
    # *supertype* of the stored doc key (`Tuple{Vector{T}}`), so a forward
    # `sig <: msig` check alone wouldn't match — the lookup must consider the
    # reverse direction (or type intersection) to surface the related doc.
    gen(a::AbstractVector) = a
    """Doc for `gen(::Vector{T})`."""
    gen(a::Vector{T}) where T = a
end
module M_field_hover
    """Documented field-level struct."""
    struct DocStruct
        """The x field — an integer."""
        x::Int
        """The y field — a string."""
        y::String
        z::Float64  # no field doc
    end
end

@testset HierarchicalTestSet "'hover' user-binding resolution" begin
    @testset "documented global binding" begin
        hover_test("documented_binding│", "Documented binding.";
            context_module = M_doc_binding)
    end

    @testset "undocumented global binding" begin
        hover_test("undocumented_binding│", "undocumented_binding";
            context_module = M_undoc_binding,
            notpat = "No documentation found")
    end

    @testset "non-existent identifier" begin
        hover_test("unexisting_binding│", r"\(global\) unexisting_binding")
    end

    @testset "global function with docstring" begin
        hover_test("func│(42)", "Documented method.";
            context_module = M_doc_func)
    end

    # Cross-module access: the test text qualifies through `M_doc_func`
    # (defined above), exercising the dot-prefix module-resolution path.
    @testset "module-qualified function" begin
        hover_test("M_doc_func.func│(42)", "Documented method.";
            context_module = @__MODULE__)
    end

    # Cursor on the callee identifier shows the full call expression with
    # its return type in the header
    @testset "callee identifier promotes header to call expression" begin
        hover_test("func│(42)", "func(42) :: $Int";
            context_module = M_doc_func)
        hover_test("M_doc_func.func│(42)", "M_doc_func.func(42) :: $Int";
            context_module = @__MODULE__)
    end

    @testset "module alias resolves through DocsBinding helper" begin
        hover_test("B│.sin(42)", JETLS.lsrender(@doc Base);
            context_module = M_base_alias)
    end

    @testset "function singleton header announces resolved value" begin
        # `mycos` is an alias to `cos`; the user can't tell from the source
        # text alone, so the header `mycos :: typeof(cos)` makes the
        # resolved value's singleton type explicit.
        hover_test("myc│os", r"mycos :: typeof\(cos\)";
            context_module = M_alias_const)
    end

    # `sv.value` resolves to `sin` via type inference, so hovering on
    # `value` should surface `sin`'s docstring even though no surface-level
    # `sin` identifier sits at the cursor.
    @testset "docs through field access via inference" begin
        hover_test("""
            function func(x)
                sv = Some(sin)
                sv.va│lue(x)
            end
        """, "Compute sine of `x`")
    end

    @testset "method-specific doc at call dispatch site" begin
        @testset "generic + method-specific docs (no interface decl)" begin
            @testset "matches Int method on `op│(1)`" begin
                hover_test("op│(1)", "Method-specific doc for `op(::Int)`.";
                    context_module = M_overloaded,
                    notpat = "Method-specific doc for `op(::String)`.")
            end
            @testset "matches String method on `op│(\"x\")`" begin
                hover_test("op│(\"x\")", "Method-specific doc for `op(::String)`.";
                    context_module = M_overloaded,
                    notpat = "Method-specific doc for `op(::Int)`.")
            end
            @testset "end-of-call cursor `op(\"x\")│` skips doc" begin
                hover_test("op(\"x\")│", r"op\(\"x\"\) :: String";
                    context_module = M_overloaded,
                    notpat = "Method-specific doc")
            end
            @testset "non-call cursor keeps every overload's doc" begin
                hover_test("op│", "Method-specific doc for `op(::Int)`.";
                    context_module = M_overloaded)
                hover_test("op│", "Method-specific doc for `op(::String)`.";
                    context_module = M_overloaded)
            end
        end

        @testset "interface-decl doc (`function f end`)" begin
            @testset "interface-decl doc shown at non-call cursor" begin
                hover_test("iface│", "Interface-level doc for `iface`.";
                    context_module = M_iface_overloaded)
                hover_test("iface│", "Method-specific doc for `iface(::Int)`.";
                    context_module = M_iface_overloaded)
            end
            @testset "interface-decl doc dropped at narrowing call site" begin
                hover_test("iface│(1)", "Method-specific doc for `iface(::Int)`.";
                    context_module = M_iface_overloaded,
                    notpat = "Interface-level doc for `iface`.")
            end
            @testset "no-match fallback returns every doc" begin
                hover_test("iface│(1.0)", "Interface-level doc for `iface`.";
                    context_module = M_iface_overloaded)
                hover_test("iface│(1.0)", "Method-specific doc for `iface(::Int)`.";
                    context_module = M_iface_overloaded)
            end
        end

        @testset "multiple overloads' docs are visually separated" begin
            clean_text, positions = JETLS.get_text_and_positions("op│")
            result = get_hover(clean_text, only(positions); context_module = M_overloaded)
            @test result isa Hover
            value = result.contents.value
            @test length(collect(eachmatch(r"^---$"m, value))) == 3
            @test occursin(
                r"`op\(::Int\)`\..*?\n---\n.*?`op\(::String\)`\."s, value)
        end

        # Narrowed dispatch sig that doesn't `<:` any stored doc key must not
        # leak the unrelated overload's doc via Base.Docs.doc's all-docs fallback.
        @testset "narrow lookup suppresses unrelated overload's doc" begin
            hover_test("undoc│(1)", r"undoc\(1\) :: Int";
                context_module = M_undoc_dispatch,
                notpat = "Doc for `undoc(::String)`.")
        end

        # Dispatch sig is a supertype of a stored doc key (e.g.
        # `filter(::AbstractArray)` dispatches to a doc-less method while
        # `filter(f, a)`'s docstring is attached to the specific
        # `Tuple{Any, Array{T,N}}` key). The lookup should surface the
        # specific doc as a proxy.
        @testset "narrow lookup surfaces specific doc under abstract dispatch" begin
            hover_test("let xs = view([1,2,3], 1:2); gen│(xs); end",
                "Doc for `gen(::Vector{T})`.";
                context_module = M_undoc_abstract_dispatch)
        end
    end

    # Cursor on an operator-dispatch surface (`xs[i]│`, `[a, b]│`, …) shows
    # only the `expr :: T` header, not the dispatched method's doc.
    @testset "no doc at operator-dispatch surface `arr[1]│`" begin
        hover_test("""
            let arr = MyArr()
                arr[1]│
            end
        """, "arr[1] :: $Int";
            context_module = M_operator_dispatch,
            notpat = "Method-specific doc")
    end

    @testset "instance field access surfaces field-level doc" begin
        @testset "documented field on `s.x│`" begin
            hover_test("""
                let s = DocStruct(1, "a", 0.0)
                    s.x│
                end
            """, "The x field";
                context_module = M_field_hover)
        end

        @testset "undocumented field on `s.z│` shows no doc body" begin
            hover_test("""
                let s = DocStruct(1, "a", 0.0)
                    s.z│
                end
            """, "s.z :: Float64";
                context_module = M_field_hover,
                notpat = "The x field")
        end
    end
end

@testset HierarchicalTestSet "'hover' Core / Base / locally-bound resolution" begin
    @testset "Core singleton (`nothing`) docstring" begin
        hover_test("nothing│", JETLS.lsrender(@doc nothing))
    end

    @testset "macrocall — bare identifier" begin
        hover_test("@inline│ sin(42)", JETLS.lsrender(@doc @inline))
    end

    @testset "macrocall — module-qualified" begin
        hover_test("Base.@inline│ sin(42)", JETLS.lsrender(@doc @inline))
    end

    @testset "regex literal" begin
        hover_test("rx = r│\"foo\"", JETLS.lsrender(@doc r""))
    end

    @testset "for-loop variable shows local kind tag" begin
        hover_test("""
            let xs = collect(1:10)
                Any[Core.Const(x│) for x in xs]
            end
        """, "(local) x")
    end
end

@testset HierarchicalTestSet "'hover' for local bindings inside a macrocall" begin
    # Regression: argument binding `xxx` introduced under `@something` must
    # still resolve to the surrounding function's parameter rather than
    # whatever the macro's expansion happens to reference.
    hover_test("""
        function func(xxx, yyy)
            value = @something rand((xx│x, yyy, nothing))
            return value
        end
    """, "(argument) xxx")
end

@testset HierarchicalTestSet "'hover' shows inferred type for local bindings" begin
    @testset "type-annotated argument" begin
        hover_test("""
            function f(x::Int)
                x│
            end
        """, "(argument) x :: Int")
    end

    @testset "untyped argument falls back to Any" begin
        hover_test("""
            function f(x)
                x│
            end
        """, "(argument) x :: Any")
    end

    @testset "local binding inferred from literal" begin
        hover_test("""
            function f()
                y = 42
                y│
            end
        """, "(local) y :: Int")
    end

    @testset "multi-for comprehension iteration binding" begin
        hover_test("""
            let xs = [1, 2, 3], ys = [1.0]
                [x + y for x in xs for y│ in ys]
            end
        """, "(argument) y :: Float64")
    end

    @testset "closure values format as a function-arrow signature" begin
        # closures get rewritten to `Core.OpaqueClosure` by JETLS' inference
        # pipeline; surface that as `(args...) -> rt` instead of leaking the
        # `Core.OpaqueClosure{...}` representation. The `PartialOpaque`
        # lattice element preserves argument names, so the hover shows `(x)`
        # rather than `(Any)`.
        hover_test("""
            function f()
                g = x -> x + 1
                g│
            end
        """, "(local) g :: (x) -> Any"; notpat="OpaqueClosure")
    end

    @testset "typed closure preserves argument types in signature" begin
        hover_test("""
            function f()
                g = (x::Int, y::Int) -> x + y
                g│
            end
        """, "(local) g :: (x::$Int, y::$Int) -> $Int")
    end

    @testset "type at cursor should be flow sensitive" begin
        # local hover queries the type at the cursor (use site), so successive
        # assignments to the same name show the most recent type, not a merge
        # of all assignments' types.
        hover_test("""
            let x = rand((rand(), nothing))
                if x !== nothing
                    println(x│)
                end
            end
        """, "(local) x :: Float64")
    end
end

@testset HierarchicalTestSet "'hover' on call-like surfaces" begin
    # Selector regression: `[1, 2, 3]│` (cursor right after `]`) used to miss
    # because `K"vect"` wasn't in `select_enclosing_call`'s kind set.
    @testset "array literal" begin
        hover_test("[1, 2, 3]│", "Vector{$Int}")
    end

    # Exercises both the `K"typed_comprehension"` selector extension and
    # `type_for_typed_comprehension`'s `<: Array` filter (which picks the
    # `Array{T,N}(undef, …)` allocation out of the inlined-loop scaffolding).
    @testset "typed comprehension" begin
        hover_test("Int[i for i in 1:5]│", "Vector{$Int}")
    end
end

@testset "indexing expression resolves to element function" begin
    # `s[2]│` is a `K"ref"` (lowering to `getindex`); const-prop yields
    # `Core.Const(cos)`, and the source `s[2]` doesn't contain "cos" so
    # the header announces the resolved function's singleton type.
    hover_test("""
        let s = (sin, cos)
            s[2]│
        end
    """, r"s\[2\] :: typeof\(cos\)")
end

end # module test_hover
