module test_definition

using Test
using JETLS

include("setup.jl")

@testset "method location" begin
    linenum = @__LINE__; method_for_test_method_definition_range() = 1
    @assert length(methods(method_for_test_method_definition_range)) == 1
    test_method = first(methods(method_for_test_method_definition_range))
    method_location = JETLS.Location(test_method)
    @test method_location isa JETLS.LSP.Location
    @test JETLS.URIs2.uri2filepath(method_location.uri) == @__FILE__
    @test method_location.range.start.line == (linenum - 1)
end

module TestModuleDefinitionRange
myidentity(x) = x
end
const LINE_TestModuleDefinitionRange = (@__LINE__) - 3

@testset "module location" begin
    loc = JETLS.Location(TestModuleDefinitionRange)
    @test loc isa JETLS.LSP.Location
    @test JETLS.URIs2.uri2filepath(loc.uri) == @__FILE__
    @test loc.range.start.line == LINE_TestModuleDefinitionRange-1
end

# Full-analysis helper — reserved for the single end-to-end
# request/response sanity testset below. Every other testset in this
# file uses the lightweight `definition_test` (which skips the LSP
# roundtrip and the workspace full-analysis).
function with_definition_request(tester, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, clean_code))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            cnt = 0
            for (i, pos) in enumerate(positions)
                (; raw_res) = writereadmsg(DefinitionRequest(;
                    id = id_counter[] += 1,
                    params = DefinitionParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        position = pos)))
                cnt += tester(i, raw_res.result, uri)
            end
            return cnt
        end
    end
end

@testset "request/response sanity" begin
    # Round-trip sanity check that covers DidOpen → analysis →
    # `DefinitionRequest` → `DefinitionResponse`, exercising the full LSP
    # path that the lightweight `definition_test` skips. Every other
    # testset in this file uses the lightweight helpers.
    @test with_definition_request("""
                func(x) = 1
                fu│nc(1.0)
            """) do _, result, uri
        @test result isa Vector{Location}
        @test length(result) == 1
        @test first(result).uri == uri
        @test first(result).range.start.line == 0
        return 1
    end == 1
end

# Single-cursor `find_definition` wrapper that skips the LSP roundtrip
# and the workspace full-analysis. `context_module` overrides the
# analysis-derived module so the test can seed the lookup with a
# pre-populated side module (defined as a runtime `module ... end` in
# this file). Returns `(locations, origin_node)` like `JETLS.find_definition`.
function find_definition(
        text::AbstractString, pos::Position;
        filename::AbstractString = joinpath(@__DIR__, "testfile_$(gensym(:definition)).jl"),
        context_module::Union{Nothing,Module} = nothing
    )
    server = JETLS.Server()
    fi = JETLS.FileInfo(#=version=#0, text, filename)
    furi = filename2uri(filename)
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, furi => fi), nothing
    end
    return JETLS.find_definition(server, furi, fi, pos; context_module)
end

# `definition_test(text, expected; ...)` — single-cursor assertion shorthand.
# `expected === nothing`    → expects `find_definition` to return no locations.
# `expected isa Int`        → expects exactly one location at `expected`
#                              (0-based line). File is not checked — for
#                              in-source jumps the URI is a gensym'd temp file,
#                              and for fixture jumps the line uniquely
#                              identifies the target.
# `expected isa Vector{Int}` → expects `length(locations) == length(expected)`
#                              with set-equal 0-based line numbers.
function definition_test(
        text::AbstractString, expected;
        context_module::Union{Nothing,Module} = nothing,
        broken::Bool = false
    )
    clean_text, positions = JETLS.get_text_and_positions(text)
    @assert length(positions) == 1
    locations, _ = find_definition(clean_text, only(positions); context_module)
    if expected === nothing
        @test isempty(locations) broken=broken
    elseif expected isa Int
        @test length(locations) == 1 broken=broken
        if length(locations) == 1
            @test first(locations).range.start.line == expected broken=broken
        end
    elseif expected isa Vector{Int}
        @test length(locations) == length(expected) broken=broken
        for line in expected
            @test any(l -> l.range.start.line == line, locations) broken=broken
        end
    else
        error("Unexpected `expected` type: $(typeof(expected))")
    end
end

# Side modules pre-populated with fixtures the lightweight `definition_test`
# helper consumes via `context_module = M_xxx` overrides. Each `LINE_*`
# constant captures the (1-based) line where the preceding definition
# lives, so tests can assert jumps without hard-coding line numbers.
module M_call_narrowing
    func(::Int) = 1
    const LINE_INT = (@__LINE__) - 1
    func(::Float64) = 2
    const LINE_FLOAT = (@__LINE__) - 1
end

module M_target_node
    m_func(_) = 1
    const LINE_M_FUNC = (@__LINE__) - 1
end

module M_function_in_module
    m_func(_) = 1
    const LINE_M_FUNC = (@__LINE__) - 1
end

@testset HierarchicalTestSet "'Definition' for methods" begin
    @testset "function definition" begin
        @testset "callee identifier jumps to def" begin
            definition_test("""
                    func(x) = 1
                    fu│nc(1.0)
                """, 0)
        end
        @testset "cursor on argument returns null" begin
            definition_test("""
                    func(x) = 1
                    func(1.│0)
                """, nothing)
        end
        @testset "function reference in `let` block" begin
            definition_test("""
                    func(x) = 1
                    let; func│; end
                """, 0)
        end
        @testset "kwcall callee unresolved at Phase 1 falls through to binding pass" begin
            definition_test("""
                    func(x; kw=1) = x
                    func│(42; kw=10)
                """, 0)
        end
    end

    @testset "call-site dispatch narrowing" begin
        # Cursor on a call site narrows to the method dispatch picked
        # for the inferred argtypes, rather than falling through to the
        # binding pass which would return every `:def` of the function.
        @testset "narrows `func(1.0)` to `func(::Float64)`" begin
            definition_test("fu│nc(1.0)", M_call_narrowing.LINE_FLOAT - 1;
                context_module = M_call_narrowing)
        end
        @testset "narrows `func(1)` to `func(::Int)`" begin
            definition_test("fu│nc(1)", M_call_narrowing.LINE_INT - 1;
                context_module = M_call_narrowing)
        end
        @testset "bare cursor returns all `:def`s via binding pass" begin
            definition_test("func│",
                [M_call_narrowing.LINE_INT - 1, M_call_narrowing.LINE_FLOAT - 1];
                context_module = M_call_narrowing)
        end
    end

    @testset "Base functions" begin
        sin_cand_file_, sin_cand_line = functionloc(first(methods(sin, (Float64,))))
        sin_cand_file = JETLS.to_full_path(sin_cand_file_)

        @testset "`Base.Compiler.tmeet` resolves" begin
            text, positions = JETLS.get_text_and_positions("Base.Compiler.tm│eet")
            locs, _ = find_definition(text, only(positions))
            @test length(locs) >= 1
        end
        @testset "`sin(1.0)` jumps to `Base.sin(::Float64)`" begin
            text, positions = JETLS.get_text_and_positions("si│n(1.0)")
            locs, _ = find_definition(text, only(positions))
            @test any(locs) do l
                JETLS.uri2filepath(l.uri) == sin_cand_file &&
                l.range.start.line == (sin_cand_line - 1)
            end
        end
        @testset "`+` operator resolves" begin
            text, positions = JETLS.get_text_and_positions("1 +│ 2")
            locs, _ = find_definition(text, only(positions))
            @test length(locs) >= 1
        end
        @testset "`Base.cos(x)` ignores local `cos(x) = 1`" begin
            filename = joinpath(@__DIR__, "testfile_$(gensym(:definition)).jl")
            text, positions = JETLS.get_text_and_positions("""
                    cos(x) = 1
                    global x::Float64 = let x = 42
                        Base.co│s(x)
                    end
                """)
            locs, _ = find_definition(text, only(positions); filename)
            @test length(locs) >= 1
            @test all(l -> JETLS.uri2filepath(l.uri) != filename, locs)
        end
    end

    @testset "operator-dispatch fallback" begin
        # Cursor on a call-like surface form (`xs[i]`, `[a, b]`, `[a; b]`,
        # `[a for x in xs]`) that didn't surface a `Const` at Phase 3
        # falls through to Phase 4 and jumps to the matched operator's
        # dispatch (`getindex`, `Base.vect`, `Base.vcat`, `Base.collect`).
        #
        # `arr` / `i` are function parameters so inference can't concrete-eval
        # the call to a `Const` and skip method matching — that would bypass
        # Phase 4 entirely (no `:matches` recorded for the surface byte range).
        getindex_cand_file_, getindex_cand_line =
            functionloc(first(methods(getindex, (Vector{Int}, Int))))
        getindex_cand_file = JETLS.to_full_path(getindex_cand_file_)

        function operator_dispatch_locs(cursor_text::AbstractString)
            text, positions = JETLS.get_text_and_positions("""
                function f(arr::Vector{Int}, i::Int)
                    $cursor_text
                end
            """)
            locs, _ = find_definition(text, only(positions))
            return locs
        end

        @testset "`arr[i]` jumps to `getindex(::Vector{Int}, ::Int)`" begin
            locs = operator_dispatch_locs("arr[i]│")
            @test any(locs) do l
                JETLS.uri2filepath(l.uri) == getindex_cand_file &&
                l.range.start.line == (getindex_cand_line - 1)
            end
        end
        @testset "`[arr[1], arr[2]]` jumps to `Base.vect`" begin
            locs = operator_dispatch_locs("[arr[1], arr[2]]│")
            @test length(locs) >= 1
        end
        @testset "`[arr; arr]` jumps to `Base.vcat`" begin
            locs = operator_dispatch_locs("[arr; arr]│")
            @test length(locs) >= 1
        end
        @testset "comprehension jumps to `Base.collect`" begin
            locs = operator_dispatch_locs("[x for x in arr]│")
            @test length(locs) >= 1
        end
    end

    @testset "function in module" begin
        @testset "unqualified call resolves through `context_module`" begin
            definition_test("m_│func(1.0)",
                M_function_in_module.LINE_M_FUNC - 1;
                context_module = M_function_in_module)
        end
        @testset "undefined Main-scope reference returns null" begin
            definition_test("m_│func(1.0)", nothing)
        end
        @testset "qualified call resolves to module member" begin
            definition_test("M_function_in_module.m_│func(1.0)",
                M_function_in_module.LINE_M_FUNC - 1;
                context_module = @__MODULE__)
        end
    end

    @testset "struct type and function aggregation" begin
        @testset "struct type at function signature" begin
            definition_test("""
                    struct Hello
                        who::String
                        Hello(who::AbstractString) = new(String(who))
                    end
                    function say(h::Hel│lo)
                        println("Hello, \$(h.who)")
                    end
                """, 0)
        end
        @testset "function with default arguments aggregates" begin
            definition_test("""
                    struct Hello; who::String; end
                    function say_defarg(h::Hello, s = "Hello")
                        println("\$s, \$(h.who)")
                    end
                    say_defar│g
                """, 1)
        end
        @testset "function with keyword arguments aggregates" begin
            definition_test("""
                    struct Hello; who::String; end
                    function say_kwarg(h::Hello; s = "Hello")
                        println("\$s, \$(h.who)")
                    end
                    say_kwar│g
                """, 1)
        end
    end

    @testset "target node selection" begin
        # Simple in-source `func` — Main-scope binding pass.
        @testset "bare function (no parens)" begin
            definition_test("""
                    func(x) = 1
                    func│ # bare function
                """, 0)
        end
        @testset "callee right edge" begin
            definition_test("""
                    func(x) = 1
                    func│(1.0)
                """, 0)
        end
        @testset "callee left edge" begin
            definition_test("""
                    func(x) = 1
                    │func(1.0)
                """, 0)
        end
        # Qualified `M_target_node.m_func` — resolved via the side-module
        # fixture so the lightweight path doesn't need full-analysis.
        @testset "qualified callee right edge" begin
            definition_test("M_target_node.m_func│(1.0)",
                M_target_node.LINE_M_FUNC - 1;
                context_module = @__MODULE__)
        end
        @testset "qualified callee left edge" begin
            definition_test("M_target_node.│m_func(1.0)",
                M_target_node.LINE_M_FUNC - 1;
                context_module = @__MODULE__)
        end
    end
end

module M_module_location
    m_func(_) = 1
end
const LINE_M_module_location = (@__LINE__) - 3

@testset HierarchicalTestSet "'Definition' for modules" begin
    @testset "module reference jumps to module def" begin
        definition_test("M_module_location│.m_func(1.0)",
            LINE_M_module_location - 1;
            context_module = @__MODULE__)
    end
    @testset "`Core` has no meaningful source location" begin
        definition_test("Core│.isdefined", nothing)
    end
end

@testset HierarchicalTestSet "'Definition' for local bindings" begin
    @testset "local definition with both branches" begin
        definition_test("""
                function func(x, y)
                    if rand(Bool)
                        z = x
                    else
                        z = y
                    end
                    return z│
                end
            """, [2, 4])
    end

    @testset "local argument with docstring on enclosing function" begin
        definition_test("""
                \"\"\"Docstring\"\"\"
                function func(xxx, yyy)
                    value = xxx│ + yyy
                    return value
                end
            """, 1)
    end

    @testset "local argument referenced inside a macrocall" begin
        definition_test("""
                function func(xxx, yyy)
                    value = @something rand((xxx│, yyy, nothing))
                    return value
                end
            """, 0)
    end
end

@testset "'Definition' for imported names" begin
    # Cursor on an imported name should NOT stop at the import site.
    # The import site is a declaration (`:decl`), not a `:def`, so the
    # binding pass falls through and reflection jumps to the source
    # (e.g. `sin` in `Base`). Wrapping `using Base: sin` and the usage
    # in `module M_import_test ... end` keeps both in the same lowering
    # pass (otherwise `find_definition` only processes the cursor's
    # toplevel and never sees the `using` line).
    sin_cand_file_, sin_cand_line = functionloc(first(methods(sin, (Float64,))))
    sin_cand_file = JETLS.to_full_path(sin_cand_file_)
    filename = joinpath(@__DIR__, "testfile_$(gensym(:definition)).jl")
    text, positions = JETLS.get_text_and_positions("""
            module M_import_test
                using Base: sin
                si│n(1.0)
            end
        """)
    locs, _ = find_definition(text, only(positions); filename)
    @test length(locs) >= 1
    # Jump must go outside the synthetic source (to `Base`'s source).
    @test all(l -> JETLS.uri2filepath(l.uri) != filename, locs)
    @test any(locs) do l
        JETLS.uri2filepath(l.uri) == sin_cand_file &&
        l.range.start.line == (sin_cand_line - 1)
    end
end

@testset "'Definition' for global bindings" begin
    @testset "untyped global" begin
        definition_test("""
                GLOBAL_VAR = 42
                function use_globals()
                    GLOBAL_VA│R
                end
            """, 0)
    end
    @testset "const global" begin
        definition_test("""
                const CONST_VAR = 100
                function use_globals()
                    CONST_VA│R
                end
            """, 0)
    end
    @testset "mutable global with multiple assignments" begin
        definition_test("""
                MUTABLE_VAR = 1
                MUTABLE_VAR = 2
                function use_globals()
                    MUTABLE_VA│R
                end
            """, [0, 1])
    end
end

end # module test_definition
