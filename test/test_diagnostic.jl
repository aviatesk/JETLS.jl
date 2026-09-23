module test_diagnostics

include("setup.jl")
include("jsjl-utils.jl")

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.URIs2
using JETLS.Glob

@testset "syntax error diagnostics" begin
    # Test with code that has syntax errors
    script_code = """
    function foo()
        x = 1
        if x > 0
            println("Positive")
        # Missing end
    end
    """

    withscript(script_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; server, writereadmsg, readmsg)
            # full-analysis does not report syntax errors as `JETLS/save` diagnostics
            (; raw_res) = writereadmsg(
                make_DidOpenTextDocumentNotification(uri, script_code))
            @test raw_res isa PublishDiagnosticsNotification
            @test !any(raw_res.params.diagnostics) do d
                d.source == JETLS.DIAGNOSTIC_SOURCE_SAVE
            end

            # the live scan pushes them for the open file, tagged with its version
            params = scan_live_diagnostics!(server, readmsg)[uri]
            @test params.version == 1
            @test any(d -> d.source == JETLS.DIAGNOSTIC_SOURCE_LIVE, params.diagnostics)
        end
    end
end

@testset "top-level error diagnostic" begin
    # Test with code that has syntax errors
    scriptcode = """
    include("nonexistent.jl")
    """

    # Use withscript to create a temporary file and run the test
    withscript(scriptcode) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.range.start.line == 0)
                    found_diagnostic = true
                    break
                end
            end
            @test found_diagnostic
        end
    end
end

function analyze_concretization(
        code::String, filename::String;
        mode::Symbol = :script,
        timeout::Union{Float64,String} = JETLS.JET.DEFAULT_CONCRETIZATION_TIMEOUT,
        pattern::Union{Nothing,String} = nothing
    )
    server = JETLS.Server()
    uri = filepath2uri(filename)
    entry = mode === :script ? JETLS.ScriptAnalysisEntry(uri) :
        JETLS.PackageSourceAnalysisEntry(dirname(filename), uri, Base.PkgId(@__MODULE__))
    request = JETLS.AnalysisRequest(
        entry, uri, #=generation=#1, #=token=#nothing, #=notify=#false)
    execution = JETLS.AnalysisExecution(request, #=prev_result=#nothing)
    interp = JETLS.LSInterpreter(server, execution)
    try
        @test JETLS.getjetconfigs(server, entry)[:concretization_timeout] == JETLS.JET.DEFAULT_CONCRETIZATION_TIMEOUT
        full_analysis = Dict{String,Any}("concretization_timeout" => timeout)
        if pattern !== nothing
            server.state.root_path = dirname(filename)
            full_analysis["concretization_patterns"] = Any[
                Dict{String,Any}("pattern" => pattern)]
        end
        settings = Dict{String,Any}("full_analysis" => full_analysis)
        JETLS.store_lsp_config!(JETLS.ConfigChangeTracker(), server, settings, "test")
        jetconfigs = JETLS.getjetconfigs(server, entry)
        @test jetconfigs[:concretization_timeout] == (timeout == "inf" ? Inf : timeout)
        context = Module(gensym(:ConcretizationTimeout))
        result = JETLS.JET.analyze_and_report_text!(interp, code, filename;
            jetconfigs...,
            context,
            virtualize = false,
            analyze_from_definitions = false)
        return (; result, context)
    finally
        close(server.endpoint)
        close(server.message_queue)
    end
end

@testset HierarchicalTestSet "concretization timeout diagnostic" begin
    for mode in (:script, :package), timeout in (0.1, "inf")
        filename = joinpath(@__DIR__, "concretization-timeout.jl")
        # Each iteration exceeds the timeout, but the loop also terminates if
        # timeout handling regresses. `@eval` forces the sleep to run concretely.
        code = """
            for _ in 1:3
                @eval begin
                    sleep(0.2)
                    timeout_fixture() = nothing
                end
            end
            """
        (; result) = analyze_concretization(code, filename; mode, timeout)
        if timeout == "inf"
            @test isempty(result.res.toplevel_error_reports)
            continue
        end
        report = only(result.res.toplevel_error_reports)
        @test report isa JETLS.JET.ConcretizationTimeoutErrorReport
        @test report.timeout == timeout
        @test isempty(report.st)
        @test report.file == filename
        @test report.line == 1
        @test isempty(result.res.inference_error_reports)

        uri = filepath2uri(filename)
        postprocessor = JETLS.JET.PostProcessor(result.res.actual2virtual)
        for markdown_rendering in (false, true)
            uri2diagnostics = JETLS.URI2Diagnostics(uri => Diagnostic[])
            JETLS.jet_result_to_diagnostics!(uri2diagnostics, result,
                Base.get_world_counter(), postprocessor; markdown_rendering)
            diag = only(uri2diagnostics[uri])
            @test diag.code == JETLS.TOPLEVEL_CONCRETIZATION_TIMEOUT_CODE
            @test diag.severity == DiagnosticSeverity.Error
            @test diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE
            @test diag.range == JETLS.line_range(report.line)
            @test occursin(string(timeout), diag.message)
        end
    end

    @testset "caught error in interpreted callee" begin
        code = """
            function guarded()
                local callee
                try
                    callee(1, 2, 3)
                catch err
                    err isa UndefVarError || rethrow()
                    return Any
                end
            end
            struct Guarded <: guarded() end
            """
        filename = joinpath(@__DIR__, "concretization-guarded.jl")
        (; result, context) = analyze_concretization(code, filename)
        @test isempty(result.res.toplevel_error_reports)
        @test isdefined(context, :Guarded)
    end

    @testset "callee timeout stack" begin
        for (mode, pattern) in ((:script, nothing), (:package, nothing),
                                (:script, "struct Timed <: drive() end")),
            timeout in (0.1, "inf")

            filename = joinpath(@__DIR__, "concretization-callee-timeout.jl")
            # `eval` sleeps natively, but recursive interpretation can stop before
            # the marker. Pattern-selected calls must finish before timing out.
            code = """
                function inner()
                    Core.eval(@__MODULE__, :(sleep(0.2)))
                    Core.eval(@__MODULE__, :(completed = true))
                    return Any
                end
                drive() = inner()
                struct Timed <: drive() end
                """
            (; result, context) = analyze_concretization(code, filename; mode, timeout, pattern)
            native = mode === :package || pattern !== nothing
            @test Base.invokelatest(isdefined, context, :completed) == (native || timeout == "inf")
            @test isempty(result.res.inference_error_reports)
            if timeout == "inf"
                @test isempty(result.res.toplevel_error_reports)
                @test isdefined(context, :Timed)
                continue
            end
            report = only(result.res.toplevel_error_reports)
            @test report isa JETLS.JET.ConcretizationTimeoutErrorReport
            @test report.timeout == timeout
            @test report.file == filename
            @test report.line == 7
            if native
                @test isempty(report.st)
            else
                @test any(frame -> frame.func === :inner && String(frame.file) == filename, report.st)
                @test any(frame -> frame.func === :drive && String(frame.file) == filename, report.st)
            end

            uri = filepath2uri(filename)
            uri2diagnostics = JETLS.URI2Diagnostics(uri => Diagnostic[])
            postprocessor = JETLS.JET.PostProcessor(result.res.actual2virtual)
            JETLS.jet_result_to_diagnostics!(uri2diagnostics, result, Base.get_world_counter(), postprocessor)
            diag = only(uri2diagnostics[uri])
            @test diag.code == JETLS.TOPLEVEL_CONCRETIZATION_TIMEOUT_CODE
            @test diag.severity == DiagnosticSeverity.Error
            @test diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE
            @test diag.range == JETLS.line_range(report.line)
            @test occursin(string(timeout), diag.message)
            @test !occursin("```", diag.message)
            if !native
                @test occursin("inner", diag.message)
                @test occursin("drive", diag.message)
                @test occursin(basename(filename), diag.message)
            end
        end
    end
end

function get_open_diagnostics(
        root_path::AbstractString, script_path::AbstractString, code::AbstractString;
        settings = nothing
    )
    uri = filepath2uri(script_path)
    rootUri = filepath2uri(root_path)
    diagnostics = Diagnostic[]
    withserver(; rootUri, settings) do (; writereadmsg)
        (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, code))
        @test raw_res isa PublishDiagnosticsNotification
        append!(diagnostics, raw_res.params.diagnostics)
    end
    return diagnostics
end

# Modified version of the MRE for aviatesk/JETLS.jl#464
# Type definitions require the branch condition's concrete value, unlike global assignments.
const missing_concretization_code = """
USE_PULSE = false

if USE_PULSE
    struct Pulse end
else
    struct NoPulse end
end
"""

function get_included_diagnostics(
        root_path::AbstractString, main_path::AbstractString,
        included_path::AbstractString, settings
    )
    main_uri = filepath2uri(main_path)
    included_uri = filepath2uri(included_path)
    rootUri = filepath2uri(root_path)
    diagnostics = Diagnostic[]
    withserver(; rootUri, settings) do (; writereadmsg)
        (; raw_res) = writereadmsg(
            make_DidOpenTextDocumentNotification(main_uri, read(main_path, String));
            read=2)
        included_response = only(filter(raw_res) do response
            return response isa PublishDiagnosticsNotification &&
                response.params.uri == included_uri
        end)
        append!(diagnostics, included_response.params.diagnostics)
    end
    return diagnostics
end

function concretization_settings(path::Union{Nothing,String} = nothing)
    pattern = Dict{String,Any}("pattern" => "USE_PULSE = x_")
    path === nothing || (pattern["path"] = path)
    return Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "concretization_patterns" => Any[pattern]))
end

@testset HierarchicalTestSet "missing concretization diagnostic" begin
    @testset "`missing_concretization_data` preserves assignment syntax" begin
        for (expression, expected) in (
                (:(RandomType::DataType = rand((Bool, Int))), "RandomType::DataType = x_"),
                (:(global RandomType = rand((Bool, Int))), "global RandomType = x_"),
                (:(const RandomType = rand((Bool, Int))), "const RandomType = x_"),
                (:(outer = RandomType = rand((Bool, Int))), "outer = (RandomType = x_)"),
                # non-standard names need `var"..."` quoting to stay parseable
                (Expr(:(=), Symbol("USE PULSE"), :(rand(Bool))), "var\"USE PULSE\" = x_"),
            )
            assignment = JETLS.JET.toplevel_assignment(expression, "config.jl", 1)
            report = JETLS.JET.MissingConcretizationErrorReport(
                false, GlobalRef(Main, :RandomType), assignment, "use.jl", 1)
            data = JETLS.missing_concretization_data(report)
            @test data.pattern == expected
            # JET strips line numbers off configured patterns before matching
            @test JETLS.JET.striplines(Meta.parse(data.pattern)) == assignment.pattern
            @test data.assignment_file == "config.jl"
        end
        # no pattern could be derived: no `data`, hence no quick fix
        let assignment = JETLS.JET.toplevel_assignment(
                :(let; global RandomType = rand(Bool); end), "config.jl", 1)
            @test assignment.pattern === nothing
            report = JETLS.JET.MissingConcretizationErrorReport(
                false, GlobalRef(Main, :RandomType), assignment, "use.jl", 1)
            @test JETLS.missing_concretization_data(report) === nothing
        end
        let report = JETLS.JET.MissingConcretizationErrorReport(
                false, GlobalRef(Main, :RandomType), nothing, "use.jl", 1)
            @test JETLS.missing_concretization_data(report) === nothing
        end
    end

    @testset "conditional global assignments do not require concretization" begin
        for code in (
                # # aviatesk/JETLS.jl#464
                """
                USE_PULSE = false

                if USE_PULSE
                    SIMULATE = false
                else
                    SIMULATE = true
                end
                """,
                """
                let
                    global USE_PULSE = rand(Bool)
                end

                if USE_PULSE
                    SIMULATE = false
                else
                    SIMULATE = true
                end
                """,
            )
            mktempdir() do dir
                script_path = joinpath(dir, "issue464.jl")
                write(script_path, code)
                diagnostics = get_open_diagnostics(dir, script_path, code)
                @test !any(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics)
            end
        end
    end

    @testset "diagnostic reported for unconcretized global" begin
        mktempdir() do dir
            script_path = joinpath(dir, "conditional-types.jl")
            expected_path = uri2filename(filepath2uri(script_path))
            write(script_path, missing_concretization_code)
            diagnostics = get_open_diagnostics(dir, script_path, missing_concretization_code)
            diag = only(filter(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics))
            @test diag.data isa MissingConcretizationData
            @test diag.data.name == "USE_PULSE"
            @test diag.data.pattern == "USE_PULSE = x_"
            @test JETLS.paths_equal(diag.data.assignment_file, script_path)
            @test occursin("assignment at $expected_path:1", diag.message)
            @test occursin("`full_analysis.concretization_patterns`", diag.message)
            @test occursin("`.JETLSConfig.toml`", diag.message)
            @test occursin("preferred quick fix", diag.message)
            @test occursin("derived pattern `USE_PULSE = x_`", diag.message)
            @test !occursin("report_file", diag.message)
        end
    end

    # writing a pattern that covers the enclosing statement is left to the user, so no
    # `data` is attached and no quick fix is offered; the message still locates it
    @testset "no `data` when no pattern can be derived" begin
        mktempdir() do dir
            script_path = joinpath(dir, "nested.jl")
            expected_path = uri2filename(filepath2uri(script_path))
            code = """
                let
                    global USE_PULSE = rand(Bool)
                end

                if USE_PULSE
                    struct Pulse end
                else
                    struct NoPulse end
                end
                """
            write(script_path, code)
            diagnostics = get_open_diagnostics(dir, script_path, code)
            diag = only(filter(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics))
            @test diag.data === nothing
            @test occursin("`.JETLSConfig.toml` manually", diag.message)
            @test occursin("could not derive a safe pattern", diag.message)
            # the `let` statement, while the diagnostic is anchored at the use site
            @test occursin("assignment at $expected_path:1", diag.message)
            @test diag.range.start.line == 4
        end
    end

    @testset "suppressed by `.JETLSConfig.toml`" begin
        mktempdir() do dir
            script_path = joinpath(dir, "conditional-types.jl")
            write(script_path, missing_concretization_code)
            write(joinpath(dir, ".JETLSConfig.toml"), """
                [[full_analysis.concretization_patterns]]
                pattern = "USE_PULSE = x_"
                """)
            diagnostics = get_open_diagnostics(dir, script_path, missing_concretization_code)
            @test !any(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics)
        end
    end

    @testset "suppressed by LSP settings" begin
        mktempdir() do dir
            script_path = joinpath(dir, "conditional-types.jl")
            write(script_path, missing_concretization_code)
            settings = concretization_settings("conditional-types.jl")
            diagnostics = get_open_diagnostics(dir, script_path, missing_concretization_code; settings)
            @test !any(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics)
        end
    end

    @testset "pattern `path` scoping with `include`" begin
        mktempdir() do dir
            main_path = joinpath(dir, "main.jl")
            included_path = joinpath(dir, "config.jl")
            write(main_path, "include(\"config.jl\")\n")
            write(included_path, missing_concretization_code)

            @testset "path of the includer does not match" begin
                diagnostics = get_included_diagnostics(dir, main_path, included_path, concretization_settings("main.jl"))
                @test any(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics)
            end

            @testset "path of the included file matches" begin
                diagnostics = get_included_diagnostics(dir, main_path, included_path, concretization_settings("config.jl"))
                @test !any(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics)
            end
        end
    end

    @testset "configured patterns do not apply outside the workspace" begin
        mktempdir() do dir
            workspace = joinpath(dir, "workspace")
            mkpath(workspace)
            main_path = joinpath(workspace, "main.jl")
            included_path = joinpath(dir, "config.jl")
            write(main_path, "include($(repr(included_path)))\n")
            write(included_path, missing_concretization_code)
            for settings in (
                    concretization_settings(),
                    concretization_settings(replace(included_path, '\\' => '/')),
                )
                diagnostics = get_included_diagnostics(workspace, main_path, included_path, settings)
                @test any(d -> d.code == JETLS.TOPLEVEL_MISSING_CONCRETIZATION_CODE, diagnostics)
            end
        end
    end
end

@testset "inference diagnostic (script analysis)" begin
    scriptcode = """
    struct MyStruct
        property::Int
    end
    function field_error()
        x = MyStruct(42)
        return x.propert  # FieldError: type `MyStruct` has no field `propert`, available fields: `property` (JETLS inference/field-error)
    end

    f32(x::Float32) = sin(x) + cos(x)
    call_f32(x) = f32(x)
    function main32()
        x = rand()
        @show call_f32(x) # no matching method found `f32(::Float64)` (JETLS inference/method-error)
    end
    """

    # Use withscript to create a temporary file and run the test
    withscript(scriptcode) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic1 = found_diagnostic2 = false
            for diag in raw_res.params.diagnostics
                if diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE
                    if diag.code == JETLS.INFERENCE_FIELD_ERROR_CODE && occursin("type `MyStruct` has no field `propert`, available fields: `property`", diag.message)
                        found_diagnostic1 = true
                    elseif diag.code == JETLS.INFERENCE_METHOD_ERROR_CODE && occursin("no matching method found `f32(::Float64)`", diag.message)
                        related2 = something(diag.relatedInformation, DiagnosticRelatedInformation[])
                        related_messages2 = map(info -> info.message, related2)
                        found_diagnostic2 = only(related_messages2) == "entry: main32()"
                    end
                end
            end
            @test found_diagnostic1
            @test found_diagnostic2
        end
    end
end

@testset "inference diagnostic (package analysis)" begin
    withpackage("TestPackageAnalysis", """
        module TestPackageAnalysis

        struct Hello
            who::String
        end
        function hello(x::Hello)
            return "Hello, \$(x.who)!"
        end

        module BadModule
            using ..TestPackageAnalysis: Hello
            function badhello1(x::Hello)
                return "Hello, \$(y.who)"  # `TestPackageAnalysis.BadModule.y` is not defined (JETLS inference/undef-global-var)
            end
            function badhello2(x::Hello)
                return _badhello2(x.who)  # no matching method found `_badhello2(::String)` (JETLS inference/method-error)
            end
            _badhello2(x::Hello) = "Hello, \$(x.who)"
        end

        end # module TestPackageAnalysis
        """) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestPackageAnalysis.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic1 = found_diagnostic2 = false
            for diag in raw_res.params.diagnostics
                if diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE
                    if diag.code == JETLS.INFERENCE_UNDEF_GLOBAL_VAR_CODE &&
                        occursin("`TestPackageAnalysis.BadModule.y` is not defined", diag.message)
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        found_diagnostic1 = true
                    end
                    if diag.code == JETLS.INFERENCE_METHOD_ERROR_CODE &&
                        occursin("no matching method found `_badhello2(::String)`", diag.message)
                        found_diagnostic2 = true
                    end
                end
            end
            @test found_diagnostic1
            @test found_diagnostic2
        end
    end
end

@testset "method overwrite diagnostic" begin
    withpackage("TestMethodOverwrite", """
        module TestMethodOverwrite

        function duplicate(x::Int)
            return x + 1
        end

        function duplicate(x::Int, y::Int=2)
            return x + y
        end

        end # module TestMethodOverwrite
        """) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestMethodOverwrite.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_METHOD_OVERWRITE_CODE &&
                    occursin("duplicate(::$Int)", diag.message) &&
                    occursin("overwritten", diag.message))
                    found_diagnostic = true
                    @test !isempty(diag.relatedInformation)
                    if !isempty(diag.relatedInformation)
                        related = first(diag.relatedInformation)
                        @test related.location.uri == uri
                        @test occursin("first method definition", related.message)
                    end
                    break
                end
            end
            @test found_diagnostic
        end
    end
end

@testset "abstract field diagnostic" begin
    withpackage("TestAbstractField", """
        module TestAbstractField

        struct BadStruct1
            xs::Vector{Integer}
        end

        struct BadStruct2
            xs::Vector{<:Integer}
        end

        struct BadStruct3
            x::Ref{Int}
        end

        const AbstractRefAlias = Ref{Int}
        struct BadStruct4
            x::AbstractRefAlias
        end

        end # module TestAbstractField
        """) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestAbstractField.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic1 = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_ABSTRACT_FIELD_CODE &&
                    occursin("BadStruct1", diag.message) &&
                    occursin("xs::Vector{Integer}", diag.message))
                    found_diagnostic1 = true
                    break
                end
            end
            @test found_diagnostic1

            found_diagnostic2 = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_ABSTRACT_FIELD_CODE &&
                    occursin("BadStruct2", diag.message) &&
                    occursin("xs::Vector{<:Integer}", diag.message))
                    found_diagnostic2 = true
                    break
                end
            end
            @test found_diagnostic2

            found_diagnostic3 = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_ABSTRACT_FIELD_CODE &&
                    occursin("BadStruct3", diag.message) &&
                    occursin("x::Ref{$Int}", diag.message))
                    found_diagnostic3 = true
                    data = diag.data
                    @test data isa AbstractRefFieldData
                    if data isa AbstractRefFieldData
                        @test data.ref_name_range.start.line == diag.range.start.line
                        @test data.ref_name_range.var"end".line == diag.range.var"end".line
                        @test data.ref_name_range.var"end".character -
                            data.ref_name_range.start.character == 3
                    end
                    break
                end
            end
            @test found_diagnostic3

            found_diagnostic4 = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_ABSTRACT_FIELD_CODE &&
                    occursin("BadStruct4", diag.message) &&
                    occursin("x::Ref{$Int}", diag.message))
                    found_diagnostic4 = true
                    @test diag.data === nothing
                    break
                end
            end
            @test found_diagnostic4
        end
    end
end

@testset "Empty package analysis" begin
    withpackage("TestEmptyPackageAnalysis", "module TestEmptyPackageAnalysis end") do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestEmptyPackageAnalysis.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))
            @test raw_res isa PublishDiagnosticsNotification
        end
    end
end

@testset "live diagnostics push cycle" begin
    script_code = "func(x) = nothing\n"
    withscript(script_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; server, writemsg, writereadmsg, readmsg, initialize_response)
            # `textDocument/diagnostic` is offered only on request
            @test initialize_response.result.capabilities.diagnosticProvider === nothing
            published = server.state.workspace_diagnostics_worker.published
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))
            @test raw_res isa PublishDiagnosticsNotification

            # `func(x) = nothing` has an unused argument, pushed with the document version
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version == 1
                @test length(params.diagnostics) == 1
                @test params.diagnostics[1].code == "lowering/unused-argument"
            end

            # nothing changed → the scan neither recomputes nor republishes
            let fingerprint = JETLS.load(published)[uri].fingerprint
                @test isempty(scan_live_diagnostics!(server, readmsg))
                @test JETLS.load(published)[uri].fingerprint == fingerprint
            end

            # editing the document bumps the version; renaming to `_x` makes the
            # unused-argument diagnostic disappear under the default
            # `allow_unused_underscore=true` config
            writemsg(make_DidChangeTextDocumentNotification(uri, "func(_x) = nothing\n", #=version=#2))
            wait_for_file_cache_version(server.state, uri, 2)
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version == 2
                @test isempty(params.diagnostics)
            end
            @test isempty(scan_live_diagnostics!(server, readmsg))

            # an edit that leaves the diagnostics as they are still republishes under the
            # new version: the client may have discarded the previous publish as stale
            writemsg(make_DidChangeTextDocumentNotification(
                uri, "func(_x) = nothing # edited\n", #=version=#3))
            wait_for_file_cache_version(server.state, uri, 3)
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version == 3
                @test isempty(params.diagnostics)
            end

            # a `[diagnostic]` config change recomputes the file: flipping
            # `allow_unused_underscore` to `false` brings the `_x` diagnostic back
            let settings = Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}("allow_unused_underscore" => false))
                (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                        params = DidChangeConfigurationParams(; settings));
                    read = 2)
                @test count(msg -> msg isa ShowMessageNotification, raw_res) == 1
                @test count(msg -> msg isa PublishDiagnosticsNotification, raw_res) == 1
            end
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version == 3
                @test length(params.diagnostics) == 1
                @test params.diagnostics[1].code == "lowering/unused-argument"
            end
        end
    end
end

@testset "File cache error handling" begin
    # Test requesting diagnostics for a file whose cache has not been populated yet
    withscript("# some code") do script_path
        uri = filepath2uri(script_path)
        withserver(; pull_diagnostics = true) do (; writereadmsg, id_counter)
            # Don't send DidOpenTextDocument notification, so no file cache is created
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri)
                    )))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test isempty(raw_res.result.items)
            end
        end
    end
end

@testset "Delayed file cache handling" begin
    # Test requesting diagnostics for a file whose cache has not been populated yet
    withscript("# some code") do script_path
        uri = filepath2uri(script_path)
        withserver(; pull_diagnostics = true) do (; writereadmsg, id_counter)
            # Don't send DidOpenTextDocument notification, so no file cache is created
            event = Base.Event()
            local success::Bool = false
            let id = id_counter[] += 1
                Threads.@spawn try
                    # `check=false`: this call races with the main thread's
                    # `writereadmsg(DidOpen; ...)` below on `received_queue` drain.
                    # Checking here would spuriously see `DidOpen` still queued
                    # (CI flake). Emptiness is still verified at shutdown via
                    # `withserver`'s own `writereadmsg` calls.
                    (; raw_res) = writereadmsg(
                        DocumentDiagnosticRequest(;
                            id,
                            params = DocumentDiagnosticParams(;
                                textDocument = TextDocumentIdentifier(; uri)
                            ));
                        read = 2, check = false)
                    @test any(raw_res) do @nospecialize res
                        res isa DocumentDiagnosticResponse &&
                        res.result isa RelatedFullDocumentDiagnosticReport
                    end
                    @test any(raw_res) do @nospecialize res
                        res isa PublishDiagnosticsNotification
                    end
                    success = true
                catch e
                    showerror(stderr, e, catch_backtrace())
                finally
                    notify(event)
                end
            end
            # Send `DidOpen` after the handler has started polling but before
            # `get_file_info`'s `JETLS_TEST_MODE` timeout (1.0s) fires, so the
            # test exercises the "cache arrives during polling" path.
            sleep(0.5)
            writereadmsg(make_DidOpenTextDocumentNotification(uri, read(script_path, String)); read=0, check=false)
            wait(event)
            @test success
        end
    end
end

@testset "textDocument/diagnostic message cycle" begin
    script_code = "func(x) = nothing\n"
    withscript(script_code) do script_path
        uri = filepath2uri(script_path)
        withserver(; pull_diagnostics = true) do (;
                server, writemsg, writereadmsg, id_counter, initialize_response)
            @test initialize_response.result.capabilities.diagnosticProvider !== nothing
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))
            @test raw_res isa PublishDiagnosticsNotification

            # initial pull: no `previousResultId` → full report carrying a `resultId`;
            # `func(x) = nothing` has an unused argument, so one diagnostic is reported
            local first_result_id::String
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri))))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId isa String
                @test length(raw_res.result.items) == 1
                @test raw_res.result.items[1].code == "lowering/unused-argument"
                first_result_id = raw_res.result.resultId
            end

            # repeat pull with matching `previousResultId` → unchanged report
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = first_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedUnchangedDocumentDiagnosticReport
                @test raw_res.result.resultId == first_result_id
            end

            # editing the document bumps the version → `resultId` changes; renaming to
            # `_x` makes the unused-argument diagnostic disappear under the default
            # `allow_unused_underscore=true` config
            writemsg(make_DidChangeTextDocumentNotification(uri, "func(_x) = nothing\n", #=version=#2))
            wait_for_file_cache_version(server.state, uri, 2)

            local second_result_id::String
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = first_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId isa String
                @test raw_res.result.resultId != first_result_id
                @test isempty(raw_res.result.items)
                second_result_id = raw_res.result.resultId
            end

            # repeat pull after edit with new `resultId` → unchanged
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = second_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedUnchangedDocumentDiagnosticReport
                @test raw_res.result.resultId == second_result_id
            end

            # mismatched `previousResultId` → full report (does not crash)
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = "not-a-real-id")))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId == second_result_id
                @test isempty(raw_res.result.items)
            end

            # `:diagnostic` config change → `resultId` changes so the client-side cached
            # `Unchanged` response is invalidated when the server's `request_diagnostic_refresh!`
            # prompts the client to re-pull. Flipping `allow_unused_underscore` to `false`
            # also brings the `_x` unused-argument diagnostic back.
            let settings = Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}("allow_unused_underscore" => false))
                (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                        params = DidChangeConfigurationParams(; settings));
                    read = 2)
                @test count(msg -> msg isa ShowMessageNotification, raw_res) == 1
                @test count(msg -> msg isa PublishDiagnosticsNotification, raw_res) == 1
            end

            local third_result_id::String
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = second_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId != second_result_id
                @test length(raw_res.result.items) == 1
                @test raw_res.result.items[1].code == "lowering/unused-argument"
                third_result_id = raw_res.result.resultId
            end
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = third_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedUnchangedDocumentDiagnosticReport
                @test raw_res.result.resultId == third_result_id
            end
        end
    end
end

@testset "workspace diagnostics push with pull diagnostics" begin
    pkg_code = """
    module TestWorkspaceDiagnosticPull
    using Base: sum
    include("util.jl")
    end # module TestWorkspaceDiagnosticPull
    """
    pkg_setup = function ()
        write(normpath(dirname(Pkg.project().path), "src", "util.jl"), "")
    end
    withpackage("TestWorkspaceDiagnosticPull", pkg_code; pkg_setup) do pkg_path
        util_uri = filepath2uri(normpath(pkg_path, "src", "util.jl"))
        main_path = normpath(pkg_path, "src", "TestWorkspaceDiagnosticPull.jl")
        main_uri = filepath2uri(main_path)
        main_code = read(main_path, String)
        rootUri = filepath2uri(pkg_path)
        has_unused_import(params) =
            any(d -> d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE, params.diagnostics)
        withserver(; rootUri, pull_diagnostics = true) do (; server, writereadmsg, readmsg)
            published = server.state.workspace_diagnostics_worker.published
            (; raw_res) = writereadmsg(
                make_DidOpenTextDocumentNotification(util_uri, ""); read = 2)
            @test all(msg -> msg isa PublishDiagnosticsNotification, raw_res)

            # Only the unopened main.jl is pushed; the open util.jl is left to the pull.
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test keys(scanned) == Set((main_uri,))
                @test has_unused_import(scanned[main_uri])
            end
            @test !haskey(JETLS.load(published), util_uri)

            # Opening main.jl hands it over to `textDocument/diagnostic`: the pushed live
            # diagnostics are forgotten and cleared on the client right away.
            (; raw_res) = writereadmsg(
                make_DidOpenTextDocumentNotification(main_uri, main_code))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == main_uri
            @test !has_unused_import(raw_res.params)
            @test !haskey(JETLS.load(published), main_uri)
            @test isempty(scan_live_diagnostics!(server, readmsg))

            # Closing it brings the push back with the next scan.
            writereadmsg(make_DidCloseTextDocumentNotification(main_uri); read = 2)
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test keys(scanned) == Set((main_uri,))
                @test has_unused_import(scanned[main_uri])
                @test scanned[main_uri].version === nothing
            end
        end
    end
end

@testset "live diagnostics of closed files are cleared by the scan" begin
    script_code = "func(x) = nothing\n"
    withscript(script_code) do script_path
        uri = filepath2uri(script_path)
        settings = Dict{String,Any}("diagnostic" => Dict{String,Any}("all_files" => false))
        withserver(; settings) do (; server, writereadmsg, readmsg)
            published = server.state.workspace_diagnostics_worker.published
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))
            @test raw_res isa PublishDiagnosticsNotification
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version == 1
                @test length(params.diagnostics) == 1
            end

            # `didClose` clears the file and forgets its entry, so the scan has nothing
            # left to clear.
            (; raw_res) = writereadmsg(make_DidCloseTextDocumentNotification(uri))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            @test isempty(raw_res.params.diagnostics)
            @test !haskey(JETLS.load(published), uri)
            @test isempty(scan_live_diagnostics!(server, readmsg))

            # A scan publish that raced with the close re-adds the entry; the next scan
            # forgets it and clears the file once more.
            JETLS.store!(published) do data
                live = JETLS.WorkspaceLiveDiagnostics("stale", 1, JETLS.Diagnostic[])
                JETLS.WorkspaceLiveDiagnosticsData(data, uri => live), nothing
            end
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version === nothing
                @test isempty(params.diagnostics)
            end
            @test !haskey(JETLS.load(published), uri)
        end
    end
end

@testset "live diagnostics fingerprint follows the module context of the analysis" begin
    script = "func(x) = x\n"
    withscript(script) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; server)
            @test JETLS.get_analysis_info(server.state.analysis_manager, uri) === nothing
            no_context = JETLS.compute_live_diagnostics_fingerprint(server, uri)

            JETLS.cache_file_info!(server, uri, 1, script)
            JETLS.cache_saved_file_info!(server.state, uri, script)
            JETLS.request_analysis!(server, uri, #=invalidate=#false; wait=true, notify_diagnostics=false)
            result = JETLS.get_analysis_info(server.state.analysis_manager, uri)::JETLS.AnalysisResult
            fingerprint = JETLS.compute_live_diagnostics_fingerprint(server, uri)
            @test fingerprint != no_context

            # A new result keeping the module context, like the final result following an
            # intermediate one, does not move the fingerprint.
            let same_context = JETLS.AnalysisResult(result.entry,
                    copy(result.uri2diagnostics), result.analyzer,
                    copy(result.analyzed_file_infos), result.actual2virtual,
                    Base.get_world_counter())
                JETLS.update_analysis_cache!(server.state, same_context)
                @test JETLS.compute_live_diagnostics_fingerprint(server, uri) == fingerprint
            end

            # A new module context, as every script reanalysis mints, moves it.
            let newmod = Module()
                analyzed_file_infos = Dict{URI,JETLS.JET.AnalyzedFileInfo}(
                    analyzed_uri => JETLS.JET.AnalyzedFileInfo(
                        [range => newmod for (range, _) in afi.module_range_infos])
                    for (analyzed_uri, afi) in result.analyzed_file_infos)
                new_context = JETLS.AnalysisResult(result.entry,
                    copy(result.uri2diagnostics), result.analyzer, analyzed_file_infos,
                    result.actual2virtual, Base.get_world_counter())
                JETLS.update_analysis_cache!(server.state, new_context)
                @test JETLS.compute_live_diagnostics_fingerprint(server, uri) != fingerprint
            end
        end
    end
end

@testset "a cancelled scan keeps the results that are still current" begin
    withscript("func(x, y) = x\n") do script_path1; withscript("g(a, b) = a\n") do script_path2
        uri1 = filepath2uri(script_path1)
        uri2 = filepath2uri(script_path2)
        withserver() do (; server)
            fingerprint1 = JETLS.compute_live_diagnostics_fingerprint(server, uri1)
            updates = Dict{URI,JETLS.WorkspaceLiveDiagnostics}(
                uri1 => JETLS.WorkspaceLiveDiagnostics(fingerprint1, nothing, Diagnostic[]),
                # computed from inputs that moved before the cancellation
                uri2 => JETLS.WorkspaceLiveDiagnostics("stale", nothing, Diagnostic[]))
            changed = Set((uri1, uri2))
            JETLS.retain_current_live_diagnostics!(updates, changed, server)
            @test keys(updates) == Set((uri1,))
            @test changed == Set((uri1,))
        end
    end end
end

@testset "a cancelled unit aggregation is not memoized" begin
    withscript("func(x) = x\n") do script_path
        uri = filepath2uri(script_path)
        withserver() do (; server)
            search_uris = Set((uri,))
            cache = JETLS.DefUsedNamesCache()
            cancel_flag = JETLS.CancelFlag(false)
            JETLS.cancel!(cancel_flag)
            JETLS.compute_def_used_names!(cache, server, search_uris;
                cancel_flag, skip_context_check = true)
            @test isempty(JETLS.load(cache))
            JETLS.compute_def_used_names!(cache, server, search_uris; skip_context_check = true)
            @test !isempty(JETLS.load(cache))
        end
    end
end

@testset "analysis setting changes leave the refresh to the reanalysis" begin
    capabilities = ClientCapabilities(;
        workspace = WorkspaceClientCapabilities(;
            diagnostics = DiagnosticWorkspaceClientCapabilities(; refreshSupport = true)))
    withserver(; capabilities, pull_diagnostics = true) do (; writereadmsg)
        # a `[diagnostic]` change moves the live diagnostics, so it asks for a re-pull
        let settings = Dict{String,Any}("diagnostic" => Dict{String,Any}("all_files" => false))
            (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                params = DidChangeConfigurationParams(; settings)); read = 2)
            @test count(msg -> msg isa ShowMessageNotification, raw_res) == 1
            @test count(msg -> msg isa WorkspaceDiagnosticRefreshRequest, raw_res) == 1
        end
        # an analysis setting only matters once the reanalysis stores its result
        let settings = Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("all_files" => false),
                "full_analysis" => Dict{String,Any}("concretization_timeout" => 5))
            (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                params = DidChangeConfigurationParams(; settings)))
            @test raw_res isa ShowMessageNotification
        end
    end
end

@testset "per-file diagnostics computed from an outdated version are not reused" begin
    withscript("func(x, y) = x\n") do script_path
        uri = filepath2uri(script_path)
        withserver(; pull_diagnostics = true) do (; server, writemsg, writereadmsg, id_counter)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, "func(x, y) = x\n"))
            @test raw_res isa PublishDiagnosticsNotification
            fi1 = JETLS.get_file_info(server.state, uri)
            writemsg(make_DidChangeTextDocumentNotification(uri, "func(x) = x\n", 2))
            wait_for_file_cache_version(server.state, uri, 2)

            # A pull that read the text before the edit stores its result after the
            # edit's invalidation.
            stale = JETLS.get_per_file_diagnostics!(server, uri, fi1, JETLS.DUMMY_CANCEL_FLAG)
            @test any(d -> d.code == JETLS.LOWERING_UNUSED_ARGUMENT_CODE, stale.diagnostics)

            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri))))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test !any(d -> d.code == JETLS.LOWERING_UNUSED_ARGUMENT_CODE, raw_res.result.items)
            end
        end
    end
end

@testset "reopening a file closed with `all_files=false` republishes it" begin
    script_code = "func(x) = nothing\n"
    withscript(script_code) do script_path
        uri = filepath2uri(script_path)
        settings = Dict{String,Any}("diagnostic" => Dict{String,Any}("all_files" => false))
        withserver(; settings) do (; server, writemsg, writereadmsg, readmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))
            @test raw_res isa PublishDiagnosticsNotification
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version == 1
                @test length(params.diagnostics) == 1
            end

            (; raw_res) = writereadmsg(make_DidCloseTextDocumentNotification(uri))
            @test raw_res isa PublishDiagnosticsNotification
            @test isempty(raw_res.params.diagnostics)

            # reopened at the same version before any scan ran (the cached analysis
            # result is reused, so the open itself publishes nothing)
            writemsg(make_DidOpenTextDocumentNotification(uri, script_code))
            wait_for_file_cache_version(server.state, uri, 1)
            let params = scan_live_diagnostics!(server, readmsg)[uri]
                @test params.version == 1
                @test length(params.diagnostics) == 1
            end
        end
    end
end

@testset "workspace diagnostics push publishes open files first" begin
    pkg_code = """
    module TestWorkspaceDiagnosticOrder
    using Base: sum
    include("util.jl")
    end # module TestWorkspaceDiagnosticOrder
    """
    util_code = "f(x, y) = x\n"
    pkg_setup = function ()
        write(normpath(dirname(Pkg.project().path), "src", "util.jl"), util_code)
    end
    withpackage("TestWorkspaceDiagnosticOrder", pkg_code; pkg_setup) do pkg_path
        util_uri = filepath2uri(normpath(pkg_path, "src", "util.jl"))
        main_uri = filepath2uri(normpath(pkg_path, "src", "TestWorkspaceDiagnosticOrder.jl"))
        rootUri = filepath2uri(pkg_path)
        withserver(; rootUri) do (; server, writereadmsg, readmsg)
            (; raw_res) = writereadmsg(
                make_DidOpenTextDocumentNotification(util_uri, util_code); read = 2)
            @test all(msg -> msg isa PublishDiagnosticsNotification, raw_res)

            # `JETLS/extra` diagnostics of util.jl's testset may land in other files too
            extra = Diagnostic(;
                range = Range(;
                    start = Position(; line = 0, character = 0),
                    var"end" = Position(; line = 0, character = 1)),
                code = JETLS.TESTRUNNER_TEST_FAILURE_CODE,
                message = "extra")
            key = JETLS.TestsetDiagnosticsKey(util_uri, "testset", 1)
            JETLS.store!(server.state.extra_diagnostics) do data
                val = JETLS.URI2Diagnostics(util_uri => [extra], main_uri => [extra])
                JETLS.ExtraDiagnosticsData(data, key => val), nothing
            end

            JETLS.publish_workspace_diagnostics!(server, JETLS.DUMMY_CANCEL_FLAG)
            msgs = Any[]
            while isready(server.callback.sent_queue)
                push!(msgs, readmsg(; check = false).raw_msg)
            end
            @test all(msg -> msg isa PublishDiagnosticsNotification, msgs)
            @test [msg.params.uri for msg in msgs] == [util_uri, main_uri]
            for msg in msgs
                @test any(d -> d.message == "extra", msg.params.diagnostics)
            end

            let uris = Set((util_uri, main_uri))
                selected = JETLS.get_full_diagnostics(server, uris)
                full = JETLS.get_full_diagnostics(server)
                for uri in uris
                    @test selected[uri] == full[uri]
                end
            end
        end
    end
end

@testset "workspace diagnostics push" begin
    pkg_code = """
    module TestWorkspaceDiagnosticPush
    using Base: sum
    include("util.jl")
    end # module TestWorkspaceDiagnosticPush
    """
    util_code_initial = ""

    pkg_setup = function ()
        pkg_dir = dirname(Pkg.project().path)
        write(normpath(pkg_dir, "src", "util.jl"), util_code_initial)
    end
    withpackage("TestWorkspaceDiagnosticPush", pkg_code; pkg_setup) do pkg_path
        util_uri = filepath2uri(normpath(pkg_path, "src", "util.jl"))
        main_path = normpath(pkg_path, "src", "TestWorkspaceDiagnosticPush.jl")
        main_uri = filepath2uri(main_path)
        main_code = read(main_path, String)
        rootUri = filepath2uri(pkg_path)
        has_unused_import(params) =
            any(d -> d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE, params.diagnostics)
        withserver(; rootUri) do (; server, writemsg, writereadmsg, readmsg)
            published = server.state.workspace_diagnostics_worker.published

            # Opening util.jl (not main.jl) analyzes the package, which publishes the
            # `JETLS/save` diagnostics of both files.
            (; raw_res) = writereadmsg(
                make_DidOpenTextDocumentNotification(util_uri, util_code_initial); read = 2)
            @test all(msg -> msg isa PublishDiagnosticsNotification, raw_res)

            # The scan then pushes the unused-import on `sum` for the unopened main.jl,
            # and the live diagnostics of the open util.jl tagged with its version.
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test has_unused_import(scanned[main_uri])
                @test scanned[main_uri].version === nothing
                @test isempty(scanned[util_uri].diagnostics)
                @test scanned[util_uri].version == 1
            end
            @test isempty(scan_live_diagnostics!(server, readmsg))

            # Opening main.jl keeps it pushed, now tagged with the document version
            # (the package is already analyzed, so no `JETLS/save` publish happens).
            writemsg(make_DidOpenTextDocumentNotification(main_uri, main_code))
            wait_for_file_cache_version(server.state, main_uri, 1)
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test keys(scanned) == Set((main_uri,))
                @test has_unused_import(scanned[main_uri])
                @test scanned[main_uri].version == 1
            end

            # Closing it drops the version again; the diagnostics stay. (`didClose`
            # republishes everything so that `all_files=false` clients see it cleared.)
            (; raw_res) = writereadmsg(
                make_DidCloseTextDocumentNotification(main_uri); read = 2)
            let closed = only(filter(msg -> msg.params.uri == main_uri, raw_res))
                @test has_unused_import(closed.params)
            end
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test keys(scanned) == Set((main_uri,))
                @test has_unused_import(scanned[main_uri])
                @test scanned[main_uri].version === nothing
            end

            # Disabling `diagnostic.all_files` clears the unopened main.jl and makes the
            # scan forget it (clearing it once more); the open util.jl is still scanned
            # (and unchanged).
            settings_off = Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("all_files" => false))
            (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                params = DidChangeConfigurationParams(; settings = settings_off)); read = 3)
            @test count(msg -> msg isa ShowMessageNotification, raw_res) == 1
            let cleared = filter(msg -> msg isa PublishDiagnosticsNotification, raw_res)
                @test Set(msg.params.uri for msg in cleared) == Set((main_uri, util_uri))
                @test all(msg -> isempty(msg.params.diagnostics), cleared)
            end
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test keys(scanned) == Set((main_uri,))
                @test isempty(scanned[main_uri].diagnostics)
            end
            @test !haskey(JETLS.load(published), main_uri)
            @test haskey(JETLS.load(published), util_uri)

            # Re-enabling it pushes main.jl again.
            settings_on = Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("all_files" => true))
            (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                params = DidChangeConfigurationParams(; settings = settings_on)); read = 3)
            @test count(msg -> msg isa ShowMessageNotification, raw_res) == 1
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test has_unused_import(scanned[main_uri])
            end

            # Editing the open sibling so that `sum` is used republishes main.jl without
            # re-running full-analysis.
            writemsg(make_DidChangeTextDocumentNotification(
                util_uri, "y = sum([1, 2, 3])\n", #=version=#2))
            wait_for_file_cache_version(server.state, util_uri, 2)
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test isempty(scanned[main_uri].diagnostics)
                @test scanned[util_uri].version == 2
            end

            # A sibling edit that leaves main.jl's diagnostics as they are moves its
            # fingerprint (so the scan recomputes it) but does not republish it.
            main_fingerprint = JETLS.load(published)[main_uri].fingerprint
            writemsg(make_DidChangeTextDocumentNotification(
                util_uri, "y = sum([1, 2, 3]) # edited\n", #=version=#3))
            wait_for_file_cache_version(server.state, util_uri, 3)
            let scanned = scan_live_diagnostics!(server, readmsg)
                @test keys(scanned) == Set((util_uri,))
                @test JETLS.load(published)[main_uri].fingerprint != main_fingerprint
            end
        end
    end
end

@testset "workspace diagnostics scan cancellation" begin
    server = JETLS.Server()
    worker = server.state.workspace_diagnostics_worker
    cancel_flag = JETLS.CancelFlag(false)
    @atomic worker.cancel_flag = cancel_flag
    # a change point abandons the scan in progress without stopping the worker
    JETLS.schedule_workspace_diagnostics!(server)
    @test JETLS.is_cancelled(cancel_flag)
    @test !JETLS.is_cancelled(worker.shutdown_flag)
    # an abandoned scan leaves the cache untouched
    @test JETLS.publish_workspace_diagnostics!(server, cancel_flag) === nothing
    @test isempty(JETLS.load(worker.published))
end

@testset "workspace diagnostics worker" begin
    pkg_code = """
    module TestWorkspaceDiagnosticWorker
    using Base: sum
    include("util.jl")
    end # module TestWorkspaceDiagnosticWorker
    """
    pkg_setup = function ()
        write(normpath(dirname(Pkg.project().path), "src", "util.jl"), "")
    end
    withpackage("TestWorkspaceDiagnosticWorker", pkg_code; pkg_setup) do pkg_path
        util_uri = filepath2uri(normpath(pkg_path, "src", "util.jl"))
        main_path = normpath(pkg_path, "src", "TestWorkspaceDiagnosticWorker.jl")
        main_uri = filepath2uri(main_path)
        rootUri = filepath2uri(pkg_path)
        is_main_publish(msg) =
            msg isa PublishDiagnosticsNotification && msg.params.uri == main_uri
        has_unused_import(msg) =
            any(d -> d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE, msg.params.diagnostics)
        # The worker runs on its own here: every change point wakes it, and it publishes
        # once module contexts are known and again when a sibling edit changes the result.
        withserver(; rootUri, live_diagnostics = true) do (; server, writemsg, readmsg)
            writemsg(make_DidOpenTextDocumentNotification(util_uri, ""); check = false)
            msg = read_until(msg -> is_main_publish(msg) && has_unused_import(msg), readmsg)
            @test msg.params.version === nothing

            writemsg(make_DidChangeTextDocumentNotification(
                util_uri, "y = sum([1, 2, 3])\n", #=version=#2); check = false)
            read_until(readmsg) do msg
                is_main_publish(msg) && isempty(msg.params.diagnostics)
            end
            @test isempty(JETLS.load(
                server.state.workspace_diagnostics_worker.published)[main_uri].diagnostics)

            settle_live_diagnostics!(server, readmsg)
        end
    end
end

function make_test_diagnostic(;
        code::String,
        severity::DiagnosticSeverity.Ty,
        message::String = "Test diagnostic"
    )
    return Diagnostic(;
        range = Range(;
            start = Position(; line=0, character=0),
            var"end" = Position(; line=0, character=10)),
        severity,
        message,
        source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
        code,
        codeDescription = JETLS.diagnostic_code_description(code))
end

function make_test_manager(config_dict::Dict{String,Any})
    lsp_config = JETLS.parse_config_from_dict(JETLS.JETLSConfig, config_dict)
    data = JETLS.ConfigManagerData(JETLS.EMPTY_CONFIG, lsp_config, nothing, true)
    return JETLS.ConfigManager(data)
end

@testset HierarchicalTestSet "diagnostic configuration" begin
    @testset "DiagnosticConfig parsing/validation" begin
        @testset "valid patterns" begin
            let config_raw = Dict{String,Any}()
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === nothing
                @test config.patterns === nothing
            end
            let config_raw = Dict{String,Any}("enabled" => false)
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === false
                @test config.patterns === nothing
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint")
                    ])
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === nothing
                @test config.patterns !== nothing
                @test length(config.patterns) == 1
                pattern = only(config.patterns)
                @test pattern.match_by == "code"
                @test pattern.pattern == "lowering/unused-argument"
                @test pattern.severity == DiagnosticSeverity.Hint
                @test pattern.match_type == "literal"
                @test pattern.path === nothing
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => 4)
                    ])
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.severity == DiagnosticSeverity.Hint
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "inference/.*",
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "off")
                    ])
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.match_type == "regex"
                @test pattern.pattern isa Regex
                @test pattern.pattern.pattern == "inference/.*"
                @test pattern.severity == 0
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `@namespace` not found",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.match_by == "message"
                @test pattern.pattern == "Macro name `@namespace` not found"
                @test pattern.match_type == "literal"
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `.*` not found",
                            "match_by" => "message",
                            "match_type" => "regex",
                            "severity" => "hint")
                    ])
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.match_by == "message"
                @test pattern.pattern isa Regex
                @test pattern.pattern.pattern == "Macro name `.*` not found"
                @test pattern.severity == DiagnosticSeverity.Hint
                @test pattern.match_type == "regex"
            end

            let config_raw = Dict{String,Any}(
                    "enabled" => true,
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test1",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "info"),
                        Dict{String,Any}(
                            "pattern" => "test2",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "hint")
                    ])
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === true
                @test config.patterns !== nothing
                @test length(config.patterns) == 2
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint",
                            "path" => "test/**/*.jl")
                    ])
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.path !== nothing
                @test pattern.path isa Glob.FilenameMatch
                @test occursin(pattern.path, "test/dir/testfile.jl")
                # `**` should also match empty path segments (requires the `d = PATHNAME` flag)
                @test occursin(pattern.path, "test/testfile.jl")
                # `*` and `**` should not match leading dots in path segments (requires the `p = PERIOD` flag)
                @test !occursin(pattern.path, "test/.hidden/testfile.jl")
            end
        end

        @testset "invalid patterns" begin
            let config_raw = Dict{String,Any}(
                    "invalid" => [])
                @test_throws JETLS.InvalidKeyError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `pattern`
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `match_by`
                            "pattern" => "test",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `match_type`
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `severity`
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "literal",)
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "invalid",
                            "severity" => "info",
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => Dict{String,Any}(),
                            "severity" => "info",
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => "invalid",
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => 5,
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => Dict{String,Any}(),
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "invalid",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => Dict{String,Any}(),
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "[invalid", # regex parse failure
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "info",
                            "invalid_key" => "value")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint",
                            "path" => 123)
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
        end
    end

    @testset "apply_diagnostic_config!" begin
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                    severity = DiagnosticSeverity.Information),
                make_test_diagnostic(;
                    code = JETLS.INFERENCE_UNDEF_GLOBAL_VAR_CODE,
                    severity = DiagnosticSeverity.Warning),
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint"),
                        Dict{String,Any}(
                            "pattern" => "inference/.*",
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "off"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).code == JETLS.LOWERING_UNUSED_ARGUMENT_CODE
            @test only(diagnostics).severity == DiagnosticSeverity.Hint
        end

        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                    severity = DiagnosticSeverity.Error,
                    message = "Macro name `@namespace` not found")
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `@namespace` not found",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "info"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Information
        end

        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                    severity = DiagnosticSeverity.Error,
                    message = "Macro name `@interface` not found")
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `.*` not found",
                            "match_by" => "message",
                            "match_type" => "regex",
                            "severity" => "hint"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Hint
        end

        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                    severity = DiagnosticSeverity.Information)
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "enabled" => false)))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test isempty(diagnostics)
        end

        # message-based patterns should have higher priority than code-based patterns
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                    severity = DiagnosticSeverity.Error,
                    message = "Macro name `@interface` not found")
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/macro-expansion-error",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint"),
                        Dict{String,Any}(
                            "pattern" => "Macro name `@interface` not found",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "info"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Information
        end

        # Later rules win when patterns have the same priority.
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                    severity = DiagnosticSeverity.Error)
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/.*",
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "warn"),
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "hint"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Hint
        end

        @testset "path matching" begin
            let diagnostics = [
                    make_test_diagnostic(;
                        code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                        severity = DiagnosticSeverity.Error,
                        message = "Macro name `@namespace` not found")
                ]
                manager = make_test_manager(Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}(
                        "patterns" => [
                            Dict{String,Any}(
                                "pattern" => "Macro name `@namespace` not found",
                                "match_by" => "message",
                                "match_type" => "literal",
                                "severity" => "info",
                                "path" => "LSP/src/**/*.jl")
                        ])))
                uri = filepath2uri("/path/to/LSP/src/subdir/protocol.jl")
                root_path = Sys.iswindows() ? "/PATH/TO" : "/path/to"
                JETLS.apply_diagnostic_config!(diagnostics, manager, uri, root_path)
                @test length(diagnostics) == 1
                @test only(diagnostics).severity == DiagnosticSeverity.Information
            end

            let diagnostics = [
                    make_test_diagnostic(;
                        code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                        severity = DiagnosticSeverity.Error,
                        message = "Macro name `@namespace` not found")
                ]
                manager = make_test_manager(Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}(
                        "patterns" => [
                            Dict{String,Any}(
                                "pattern" => "Macro name `@namespace` not found",
                                "match_by" => "message",
                                "match_type" => "literal",
                                "severity" => "info",
                                "path" => "LSP/src/**/*.jl")
                        ])))
                uri = filepath2uri("/path/to/other/src/protocol.jl")
                JETLS.apply_diagnostic_config!(diagnostics, manager, uri, "/path/to")
                @test length(diagnostics) == 1
                @test only(diagnostics).severity == DiagnosticSeverity.Error
            end

            let diagnostics = [
                    make_test_diagnostic(;
                        code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                        severity = DiagnosticSeverity.Information)
                ]
                manager = make_test_manager(Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}(
                        "patterns" => [
                            Dict{String,Any}(
                                "pattern" => ".*",
                                "match_by" => "code",
                                "match_type" => "regex",
                                "severity" => "off",
                                "path" => "test/**/*.jl")
                        ])))
                uri = filepath2uri("/path/to/test/foo/bar.jl")
                root_path = Sys.iswindows() ? "/PATH/TO" : "/path/to"
                JETLS.apply_diagnostic_config!(diagnostics, manager, uri, root_path)
                @test isempty(diagnostics)
            end
        end

        # diagnostics with severity=0 are filtered out when no pattern enables them
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE,
                    severity = 0)
            ]
            manager = make_test_manager(Dict{String,Any}())
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test isempty(diagnostics)
        end

        # diagnostics with severity=0 can be enabled via patterns
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE,
                    severity = 0)
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unsorted-import-names",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint")
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Hint
        end
    end
end

end # module test_diagnostics
