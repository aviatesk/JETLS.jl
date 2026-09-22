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
        withserver() do (; writereadmsg, id_counter)
            # `textDocument/publishDiagnostics` is notified, but the diagnostics of syntax errors wouldn't be published
            writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))

            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri)
                    )))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport

                found_diagnostic = false
                for diag in raw_res.result.items
                    if diag.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
                        found_diagnostic = true
                        break
                    end
                end
                @test found_diagnostic
            end
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

@testset "File cache error handling" begin
    # Test requesting diagnostics for a file whose cache has not been populated yet
    withscript("# some code") do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
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
        withserver() do (; writereadmsg, id_counter)
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
        withserver() do (; server, writemsg, writereadmsg, id_counter)
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

# Reads server messages one at a time until `pred` accepts one and returns it; messages
# arriving in between (other publishes, configuration notices) are discarded.
function read_until(pred, readmsg; limit::Int = 50)
    for _ in 1:limit
        msg = readmsg(; check = false).raw_msg
        pred(msg) && return msg
    end
    error("Gave up waiting for a matching server message")
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
        is_main_publish(msg) =
            msg isa PublishDiagnosticsNotification && msg.params.uri == main_uri
        has_unused_import(msg) =
            any(d -> d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE, msg.params.diagnostics)
        withserver(; rootUri) do (; server, writemsg, readmsg)
            published = server.state.workspace_diagnostics_worker.published

            # Opening util.jl (not main.jl) analyzes the package; the unopened main.jl
            # then gets its unused-import on `sum` pushed once module contexts are known.
            writemsg(make_DidOpenTextDocumentNotification(util_uri, util_code_initial);
                check = false)
            read_until(msg -> is_main_publish(msg) && has_unused_import(msg), readmsg)
            @test haskey(JETLS.load(published), main_uri)

            # Opening main.jl hands it over to `textDocument/diagnostic`: the pushed live
            # diagnostics are forgotten and cleared on the client.
            writemsg(make_DidOpenTextDocumentNotification(main_uri, main_code);
                check = false)
            read_until(msg -> is_main_publish(msg) && !has_unused_import(msg), readmsg)
            @test !haskey(JETLS.load(published), main_uri)

            # Closing it brings the push back.
            writemsg(make_DidCloseTextDocumentNotification(main_uri); check = false)
            read_until(msg -> is_main_publish(msg) && has_unused_import(msg), readmsg)
            @test haskey(JETLS.load(published), main_uri)

            # Disabling `diagnostic.all_files` clears the pushed diagnostics, and
            # re-enabling it pushes them again.
            settings_off = Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("all_files" => false))
            writemsg(DidChangeConfigurationNotification(;
                params = DidChangeConfigurationParams(; settings = settings_off));
                check = false)
            read_until(readmsg) do msg
                is_main_publish(msg) && isempty(msg.params.diagnostics)
            end
            settings_on = Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("all_files" => true))
            writemsg(DidChangeConfigurationNotification(;
                params = DidChangeConfigurationParams(; settings = settings_on));
                check = false)
            read_until(msg -> is_main_publish(msg) && has_unused_import(msg), readmsg)

            # Editing the synchronized sibling so that `sum` is used republishes main.jl
            # without re-running full-analysis.
            writemsg(make_DidChangeTextDocumentNotification(
                util_uri, "y = sum([1, 2, 3])\n", #=version=#2); check = false)
            read_until(readmsg) do msg
                is_main_publish(msg) && isempty(msg.params.diagnostics)
            end

            # A sibling edit that leaves main.jl's diagnostics as they are moves its
            # result id (so the scan recomputes it) but publishes nothing.
            main_id = JETLS.load(published)[main_uri].result_id
            writemsg(make_DidChangeTextDocumentNotification(
                util_uri, "y = sum([1, 2, 3]) # edited\n", #=version=#3); check = false)
            @test timedwait(10.0) do
                JETLS.load(published)[main_uri].result_id != main_id
            end === :ok
            sleep(JETLS.WORKSPACE_DIAGNOSTICS_MIN_INTERVAL)
            while isready(server.callback.sent_queue)
                @test !is_main_publish(readmsg(; check = false).raw_msg)
            end

            # Let a possible trailing scan settle before the shutdown handshake.
            sleep(2 * JETLS.WORKSPACE_DIAGNOSTICS_MIN_INTERVAL)
            while isready(server.callback.sent_queue)
                readmsg(; check = false)
            end
        end
    end
end

@testset "workspace diagnostics push for clients without pull support" begin
    pkg_code = """
    module TestWorkspaceDiagnosticPushOnly
    using Base: sum
    include("util.jl")
    end # module TestWorkspaceDiagnosticPushOnly
    """
    pkg_setup = function ()
        write(normpath(dirname(Pkg.project().path), "src", "util.jl"), "")
    end
    withpackage("TestWorkspaceDiagnosticPushOnly", pkg_code; pkg_setup) do pkg_path
        util_uri = filepath2uri(normpath(pkg_path, "src", "util.jl"))
        main_path = normpath(pkg_path, "src", "TestWorkspaceDiagnosticPushOnly.jl")
        main_uri = filepath2uri(main_path)
        main_code = read(main_path, String)
        rootUri = filepath2uri(pkg_path)
        is_main_publish(msg) =
            msg isa PublishDiagnosticsNotification && msg.params.uri == main_uri
        has_unused_import(msg) =
            any(d -> d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE, msg.params.diagnostics)
        withserver(; rootUri, pull_diagnostics = false) do (; server, writemsg, readmsg)
            published = server.state.workspace_diagnostics_worker.published
            writemsg(make_DidOpenTextDocumentNotification(util_uri, ""); check = false)
            read_until(msg -> is_main_publish(msg) && has_unused_import(msg), readmsg)

            # Opening main.jl keeps its live diagnostics pushed: the scan re-keys the
            # entry on the open document, and no clearing publish is sent.
            main_id = JETLS.load(published)[main_uri].result_id
            writemsg(make_DidOpenTextDocumentNotification(main_uri, main_code); check = false)
            @test timedwait(10.0) do
                entry = get(JETLS.load(published), main_uri, nothing)
                entry !== nothing && entry.result_id != main_id
            end === :ok
            sleep(JETLS.WORKSPACE_DIAGNOSTICS_MIN_INTERVAL)
            while isready(server.callback.sent_queue)
                msg = readmsg(; check = false).raw_msg
                is_main_publish(msg) && @test has_unused_import(msg)
            end

            # Editing the open file republishes it, tagged with the document version.
            edited = replace(main_code, "using Base: sum\n" => "")
            writemsg(make_DidChangeTextDocumentNotification(main_uri, edited, #=version=#2); check = false)
            read_until(readmsg) do msg
                is_main_publish(msg) && !has_unused_import(msg) && msg.params.version == 2
            end

            # An edit that leaves the diagnostics as they are still republishes under the
            # new version: the client may have discarded the previous publish as stale.
            writemsg(make_DidChangeTextDocumentNotification(
                main_uri, edited * "# edited\n", #=version=#3);
                check = false)
            read_until(readmsg) do msg
                is_main_publish(msg) && !has_unused_import(msg) && msg.params.version == 3
            end

            # `diagnostic.all_files=false` silences unopened files only: the open file
            # keeps getting its live diagnostics pushed on edit.
            settings_off = Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("all_files" => false))
            writemsg(DidChangeConfigurationNotification(;
                params = DidChangeConfigurationParams(; settings = settings_off));
                check = false)
            writemsg(make_DidChangeTextDocumentNotification(
                main_uri, main_code, #=version=#4);
                check = false)
            read_until(readmsg) do msg
                is_main_publish(msg) && has_unused_import(msg) && msg.params.version == 4
            end

            # Closing it turns main.jl into an unopened file, whose diagnostics are cleared.
            writemsg(make_DidCloseTextDocumentNotification(main_uri); check = false)
            read_until(readmsg) do msg
                is_main_publish(msg) && isempty(msg.params.diagnostics)
            end
            @test timedwait(10.0) do
                !haskey(JETLS.load(published), main_uri)
            end === :ok

            sleep(2 * JETLS.WORKSPACE_DIAGNOSTICS_MIN_INTERVAL)
            while isready(server.callback.sent_queue)
                readmsg(; check = false)
            end
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
