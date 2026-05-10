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

@testset "'Hover' request/response" begin
    @testset "documented global binding" begin
        single_hover_test("""
            \"\"\"Documented binding.\"\"\"
            const documented_binding = 42
            documented_binding│
        """, "Documented binding.")
    end

    @testset "undocumented global binding" begin
        single_hover_test("""
            const undocumented_binding = 42
            undocumented_binding│
        """, "No documentation found")
    end

    @testset "non-existent identifier" begin
        single_hover_test("unexisting_binding│", "No documentation found")
    end

    @testset "global function with docstring" begin
        single_hover_test("""
            \"\"\"Documented method.\"\"\"
            func(x::Int) = x
            func│(42)
        """, "Documented method.")
    end

    @testset "module-qualified function" begin
        single_hover_test("""
            module M_Doc
                \"\"\"Documented method.\"\"\"
                func(x::Int) = x
            end
            M_Doc.func│(42)
        """, "Documented method.")
    end

    @testset "module alias resolves through DocsBinding helper" begin
        single_hover_test("""
            using Base: Base as B
            B│.sin(42)
        """, JETLS.lsrender(@doc Base))
    end

    @testset "Core singleton (`nothing`) docstring" begin
        single_hover_test("nothing│", JETLS.lsrender(@doc nothing))
    end

    @testset "macrocall — bare identifier" begin
        single_hover_test("@inline│ sin(42)", JETLS.lsrender(@doc @inline))
    end

    @testset "macrocall — module-qualified" begin
        single_hover_test("Base.@inline│ sin(42)", JETLS.lsrender(@doc @inline))
    end

    @testset "regex literal" begin
        single_hover_test("rx = r│\"foo\"", JETLS.lsrender(@doc r""))
    end

    @testset "for-loop variable shows local kind tag" begin
        single_hover_test("""
            let xs = collect(1:10)
                Any[Core.Const(x│) for x in xs]
            end
        """, "(local) x")
    end

    @testset "function singleton header announces resolved value" begin
        # `mycos` is an alias to `cos`; the user can't tell from the source
        # text alone, so the header `mycos :: typeof(cos)` makes the
        # resolved value's singleton type explicit.
        single_hover_test("""
            const mycos = cos
            myc│os
        """, r"mycos :: typeof\(cos\)"; broken=true)
    end

    @testset "indexing expression resolves to element function" begin
        # `s[2]│` is a `K"ref"` (lowering to `getindex`); const-prop yields
        # `Core.Const(cos)`, and the source `s[2]` doesn't contain "cos" so
        # the header announces the resolved function's singleton type.
        single_hover_test("""
            let s = (sin, cos)
                s[2]│
            end
        """, r"s\[2\] :: typeof\(cos\)")
    end
end

module lowering_module end
get_local_hover(args...; kwargs...) = get_local_hover(lowering_module, args...; kwargs...)
function get_local_hover(mod::Module, text::AbstractString, pos::Position; filename::AbstractString=@__FILE__)
    fi = JETLS.FileInfo(#=version=#0, text, filename)
    uri = filename2uri(filename)
    st0_top = JETLS.build_syntax_tree(fi)
    @assert JS.kind(st0_top) === JS.K"toplevel"
    offset = JETLS.xy_to_offset(fi, pos)
    state = JETLS.ServerState()
    pp = JETLS.LSPostProcessor(JETLS.JET.PostProcessor())
    return JETLS.expression_hover(state, fi, uri, st0_top, offset, mod, pp)
end

@testset "'Hover' resolves docs through field access via inference" begin
    # `sv.value` resolves to `sin` via type inference, so hovering on `value`
    # should surface `sin`'s docstring even though there is no surface-level
    # identifier `sin` at the cursor.
    single_hover_test("""
        function func(x)
            sv = Some(sin)
            sv.va│lue(x)
        end
    """, JETLS.lsrender(@doc sin))
end

@testset "'hover' for local bindings inside a macrocall" begin
    # Regression: argument binding `xxx` introduced under `@something` must
    # still resolve to the surrounding function's parameter rather than
    # whatever the macro's expansion happens to reference.
    clean_text, positions = JETLS.get_text_and_positions("""
        function func(xxx, yyy)
            value = @something rand((xx│x, yyy, nothing))
            return value
        end
    """)
    result = get_local_hover(clean_text, only(positions))
    @test result isa Hover
    @test occursin("(argument) xxx", result.contents.value)
end

@testset "'hover' shows inferred type for local bindings" begin
    @testset "type-annotated argument" begin
        clean_text, positions = JETLS.get_text_and_positions("""
            function f(x::Int)
                x│
            end
        """)
        result = get_local_hover(clean_text, only(positions))
        @test result isa Hover
        @test occursin("(argument) x :: Int", result.contents.value)
    end

    @testset "untyped argument falls back to Any" begin
        clean_text, positions = JETLS.get_text_and_positions("""
            function f(x)
                x│
            end
        """)
        result = get_local_hover(clean_text, only(positions))
        @test result isa Hover
        @test occursin("(argument) x :: Any", result.contents.value)
    end

    @testset "local binding inferred from literal" begin
        clean_text, positions = JETLS.get_text_and_positions("""
            function f()
                y = 42
                y│
            end
        """)
        result = get_local_hover(clean_text, only(positions))
        @test result isa Hover
        @test occursin("(local) y :: Int", result.contents.value)
    end

    @testset "closure values format as a function-arrow signature" begin
        # closures get rewritten to `Core.OpaqueClosure` by JETLS' inference
        # pipeline; surface that as `(args...) -> rt` instead of leaking the
        # `Core.OpaqueClosure{...}` representation. The `PartialOpaque`
        # lattice element preserves argument names, so the hover shows `(x)`
        # rather than `(Any)`.
        clean_text, positions = JETLS.get_text_and_positions("""
            function f()
                g = x -> x + 1
                g│
            end
        """)
        result = get_local_hover(clean_text, only(positions))
        @test result isa Hover
        @test occursin("(local) g :: (x) -> Any", result.contents.value)
        @test !occursin("OpaqueClosure", result.contents.value)
    end

    @testset "typed closure preserves argument types in signature" begin
        clean_text, positions = JETLS.get_text_and_positions("""
            function f()
                g = (x::Int, y::Int) -> x + y
                g│
            end
        """)
        result = get_local_hover(clean_text, only(positions))
        @test result isa Hover
        @test occursin("(local) g :: (x::$Int, y::$Int) -> $Int", result.contents.value)
    end

    @testset "type at cursor should be flow sensitive" begin
        # local hover queries the type at the cursor (use site), so successive
        # assignments to the same name show the most recent type, not a merge
        # of all assignments' types.
        clean_text, positions = JETLS.get_text_and_positions("""
            let x = rand((rand(), nothing))
                if x !== nothing
                    println(x│)
                end
            end
        """)
        result = get_local_hover(clean_text, only(positions))
        @test result isa Hover
        @test occursin("(local) x :: Float64", result.contents.value)
    end
end

end # module test_hover
