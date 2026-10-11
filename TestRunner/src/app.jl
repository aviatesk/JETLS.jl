module App

# Import necessary modules
using Test: Test
using ..TestRunner: JS, TestRunnerTestSet, errors_and_fails, last_toplevel_testset, runtest
using JSON3: JSON3

include("testrunner-types.jl")
include("testset-results.jl")

# to support precompilation
const app_runner_module = Ref{Union{Module,Nothing}}(nothing)

# Helper functions for colored output
function error_print(msg::AbstractString)
    printstyled(stderr, "Error:", bold=true, color=:red)
    println(stderr, " $msg")
end

function error_print(msg::AbstractString, highlight::AbstractString)
    printstyled(stderr, "Error:", bold=true, color=:red)
    print(stderr, " $msg ")
    printstyled(stderr, highlight, bold=true)
    println(stderr)
end

function warning_print(msg::AbstractString)
    printstyled(stderr, "Warning:", bold=true, color=:yellow)
    println(stderr, " $msg")
end

function info_print(msg::AbstractString)
    printstyled("Info:", bold=true, color=:blue)
    println(" $msg")
end

function info_print(msg::AbstractString, highlight::AbstractString)
    printstyled("Info:", bold=true, color=:blue)
    print(" $msg ")
    printstyled(highlight, bold=true)
    println()
end

function header_print(msg::AbstractString)
    println()
    printstyled("═══ $msg ═══", bold=true, color=:cyan)
    println()
end

function detail_print(msg::AbstractString)
    printstyled("  $msg", color=:light_black)
    println()
end

function error_detail_print(msg::AbstractString)
    printstyled(stderr, "  $msg", color=:light_black)
    println(stderr)
end

function show_error_trace(@nospecialize e)
    error_detail_print("")
    Base.showerror(stderr, e)
    println(stderr)
end

function (@main)(args::Vector{String})
    if isempty(args)
        print_usage()
        return 1
    end

    # Handle help at any position
    if any(arg -> arg == "--help" || arg == "-h", args)
        print_usage()
        return 0
    end

    patterns = String[]
    filename = filter_lines = project = root_path = nothing
    verbose = json_output = read_stdin = false

    i = 1
    while i <= length(args)
        arg = args[i]

        if startswith(arg, "--filter-lines=")
            filter_str = arg[16:end]
            parsed_lines = parse_filter_lines(filter_str)
            if parsed_lines === nothing
                return 1
            end
            filter_lines = parsed_lines
        elseif startswith(arg, "-f=")
            filter_str = arg[4:end]
            parsed_lines = parse_filter_lines(filter_str)
            if parsed_lines === nothing
                return 1
            end
            filter_lines = parsed_lines
        elseif startswith(arg, "--project=")
            project = arg[11:end]
        elseif arg == "--project"
            # Handle --project without equals sign (use current directory)
            project = "."
        elseif startswith(arg, "--root-path=")
            root_path = arg[13:end]
        elseif arg == "--verbose" || arg == "-v"
            verbose = true
        elseif arg == "--json"
            json_output = true
        elseif arg == "--read-stdin"
            read_stdin = true
        elseif startswith(arg, "-") && arg != "-"
            error_print("Unknown option:", arg)
            error_detail_print("Run with --help to see available options")
            return 1
        else
            # Not an option, it's either filename or pattern
            if filename === nothing
                filename = arg
            else
                push!(patterns, arg)
            end
        end
        i += 1
    end

    if project !== nothing
        warning_print("The `--project` option of testrunner is deprecated. " *
            "Pass `--project` to Julia before `--` instead, " *
            "e.g. `testrunner --project=test -- test/runtests.jl`. " *
            "With `julia -m TestRunner`, pass `--project` to Julia before `-m`; " *
            "if TestRunner lives in another environment, add that environment to " *
            "`JULIA_LOAD_PATH` so that `-m` can find it.")
    end

    # Check if filename was provided
    if filename === nothing
        error_print("No file path provided")
        println()
        print_usage()
        return 1
    end

    # Parse patterns
    parsed_patterns = parse_patterns(patterns)

    # Check if any pattern was invalid
    if parsed_patterns === nothing
        return 1
    end

    # Run tests
    return runtest_app(filename, parsed_patterns, filter_lines, verbose, project, json_output, read_stdin, root_path)
end

function print_usage()
    printstyled("TestRunner", bold=true)
    println(" - Julia test runner with selective execution")
    println("""

    Usage:
      testrunner [options] <path> [patterns...]
      testrunner [julia options] -- [options] <path> [patterns...]

    Julia options such as `--project` go before `--`, e.g.:
      testrunner --project=test -- test/runtests.jl

    Pattern formats:
      L10         - Run tests on line 10
      L10:20      - Run tests on lines 10-20
      :(expr)     - Match expression pattern (e.g., ':(@test foo(x_) == y_)')
      r"^test.*"  - Match testset names with regex
      "my tests"  - Match testset by exact name (default)

    Options:
      --project[=<dir>]         Deprecated: pass `--project` to Julia before `--`
      --filter-lines=1,5,10:20  Filter to specific lines
      -f=1,5,10:20              Short form of --filter-lines
      --verbose, -v             Show verbose output
      --json                    Output results in JSON format
      --read-stdin              Read source for <path> from stdin instead of disk
                                (<path> is still used for `@__FILE__`, error
                                messages, and resolving `include`d files)
      --root-path=<dir>         Fallback base directory for relative `include`
                                paths when <path>'s `dirname` is empty (typical
                                with stdin sources whose <path> is a virtual
                                identifier such as an unsaved buffer name).
                                Once an include is resolved into a real file,
                                its own directory is used for nested includes
      -h, --help                Show this help message

    Examples:
      testrunner test/runtests.jl
      testrunner test/runtests.jl "basic tests"
      testrunner test/runtests.jl L15:25
      testrunner test/runtests.jl ':(@test length(xs) == 1)'
      testrunner test/runtests.jl r"^test.*" --filter-lines=10:50
      testrunner --project=test -- test/runtests.jl "my tests"
      testrunner --project=/path/to/project -- test/runtests.jl L10:20
      testrunner test/runtests.jl --json
    """)
end

function parse_patterns(patterns::Vector{String})
    parsed = Any[]
    for pattern in patterns
        pat = @something parse_pattern(pattern) return nothing # Invalid pattern, return nothing to indicate failure
        push!(parsed, pat)
    end
    return parsed
end

function parse_pattern(pattern::String)
    # Line number pattern: L10 or L10:20
    # Only treat as line pattern if it matches the exact format (L followed by digits, optionally with :digits)
    line_pattern_match = match(r"^L(\d+)(?::(\d+))?$", pattern)
    if line_pattern_match !== nothing
        start_line = parse(Int, line_pattern_match.captures[1]::AbstractString)
        if line_pattern_match.captures[2] !== nothing
            end_line = parse(Int, line_pattern_match.captures[2]::AbstractString)
            if start_line > end_line
                error_print("Invalid line range (start > end):", pattern)
                error_detail_print("Start line ($start_line) must be less than or equal to end line ($end_line)")
                return nothing
            end
            return start_line:end_line
        else
            return start_line
        end
    # Expression pattern: :(expr)
    elseif startswith(pattern, ":")
        # Parse the expression - require parentheses
        expr_str = pattern[2:end]
        if !startswith(expr_str, "(") || !endswith(expr_str, ")")
            error_print("Expression pattern must be surrounded by parentheses:", pattern)
            error_detail_print("Expected format: :(expression)")
            error_detail_print("Example: :(@test foo(x) == y)")
            return nothing
        end

        # Parse the content inside parentheses
        inner_expr = expr_str[2:end-1]
        try
            parsed = Meta.parse(inner_expr; filename="pattern")
            if isa(parsed, Expr) && parsed.head == :incomplete
                error_print("Incomplete expression pattern:", pattern)
                error_detail_print("The expression appears to be incomplete (missing closing parenthesis, etc.)")
                return nothing
            end
            return parsed
        catch e
            error_print("Invalid expression pattern:", pattern)
            error_detail_print("Failed to parse Julia expression:")
            show_error_trace(e)
            return nothing
        end
    # Regex pattern: r"pattern"
    elseif startswith(pattern, "r\"") && endswith(pattern, "\"")
        # Extract content between quotes (skip 'r"' at start and '"' at end)
        regex_content = pattern[3:end-1]

        # Unescape escaped quotes
        regex_content = replace(regex_content, "\\\"" => "\"")

        try
            return Regex(regex_content)
        catch e
            error_print("Invalid regex pattern:", pattern)
            error_detail_print("Failed to compile regular expression:")
            show_error_trace(e)
            return nothing
        end
    # String pattern (default)
    else
        return pattern
    end
end

function parse_filter_lines(filter_str::String)
    lines = Set{Int}()
    for part in split(filter_str, ",")
        part = strip(part)
        if isempty(part)
            continue
        end

        if contains(part, ":")
            # Range: 10:20
            range_parts = split(part, ":", limit=2)
            start_line = tryparse(Int, strip(range_parts[1]))
            end_line = tryparse(Int, strip(range_parts[2]))
            if start_line === nothing || end_line === nothing
                error_print("Invalid line range in filter:", part)
                error_detail_print("Expected format: <start>:<end> where start and end are integers")
                return nothing
            end
            if start_line > end_line
                error_print("Invalid line range (start > end) in filter:", part)
                error_detail_print("Start line ($start_line) must be less than or equal to end line ($end_line)")
                return nothing
            end
            for line in start_line:end_line
                push!(lines, line)
            end
        else
            # Single line: 10
            line_num = @something tryparse(Int, part) begin
                error_print("Invalid line number in filter:", part)
                error_detail_print("Expected an integer value")
                return nothing
            end
            push!(lines, line_num)
        end
    end
    return lines
end

function parse_project_path(project::String, filename::String)
    if project == "@temp"
        return mktempdir()
    elseif project == "@." || project == "."
        # Search for Project.toml in parent directories
        dir = dirname(abspath(filename))
        while true
            if isfile(joinpath(dir, "Project.toml")) || isfile(joinpath(dir, "JuliaProject.toml"))
                return dir
            end
            parent = dirname(dir)
            if parent == dir  # Reached root
                error("No Project.toml or JuliaProject.toml found in parent directories")
            end
            dir = parent
        end
    elseif startswith(project, "@script")
        # Handle @script or @script<rel> format
        scriptdir = dirname(abspath(filename))
        if project == "@script"
            search_dir = scriptdir
        else
            # Extract relative path from @script<rel>
            rel_path = project[8:end]  # Remove "@script" prefix
            search_dir = normpath(joinpath(scriptdir, rel_path))
        end

        # Search up from script directory
        dir = search_dir
        while true
            if isfile(joinpath(dir, "Project.toml")) || isfile(joinpath(dir, "JuliaProject.toml"))
                return dir
            end
            parent = dirname(dir)
            if parent == dir  # Reached root
                error("No Project.toml or JuliaProject.toml found searching from $search_dir")
            end
            dir = parent
        end
    else
        # Regular directory path
        return project
    end
end

function extract_test_stats_from_exception(ex::Test.TestSetException, duration::Float64)
    return TestRunnerStats(;
        n_passed = ex.pass,
        n_failed = ex.fail,
        n_errored = ex.error,
        n_broken = ex.broken,
        duration)
end

function extract_diagnostics_from_exception(ex::Test.TestSetException)
    return TestRunnerDiagnostic[testrunner_diagnostic(result) for result in ex.errors_and_fails]
end

function testrunner_diagnostic(result::Union{Test.Fail,Test.Error})
    source = result.source
    filename = string(source.file)
    line = source.line
    relatedInformation = nothing
    if haskey(errors_and_fails, result)
        excs = errors_and_fails[result]
        if !isempty(excs)
            exc = first(excs)
            if hasproperty(exc, :backtrace)
                st = stacktrace(exc.backtrace)
                relatedInformation = TestRunnerDiagnosticRelatedInformation[]
                for sf in st
                    linfo = sf.linfo
                    if linfo isa Core.CodeInstance
                        linfo = linfo.def
                    end
                    local message = linfo isa Core.MethodInstance ?
                        sprint(Base.show_tuple_as_call, Symbol(""), linfo.specTypes) :
                        string(sf.func)
                    push!(relatedInformation, TestRunnerDiagnosticRelatedInformation(
                        string(sf.file), sf.line, message))
                end
            end
        end
    end
    message = sprint(show, result)
    return TestRunnerDiagnostic(filename, line, message, relatedInformation)
end

function runtest_internal(filename::String, patterns::Vector{Any}, filter_lines, verbose::Bool, project,
                          source::Union{Nothing,String}=nothing,
                          root_path::Union{Nothing,String}=nothing)
    # Set `LOAD_PATH` manually: app shim sets limits it by default
    if Base.should_use_main_entrypoint()
        empty!(LOAD_PATH)
        push!(LOAD_PATH, "@", "@v$(VERSION.major).$(VERSION.minor)", "@stdlib")
    else
        # for precompilation
    end

    if verbose
        header_print("Test Setup")
        info_print("Julia version:", string(VERSION))
        info_print("Julia executable:", Sys.BINDIR)
    end

    if project !== nothing
        project_path = parse_project_path(project, filename)
        if verbose
            info_print("Active environment:", project)
            detail_print("Project path: $project_path")
        end
        Base.set_active_project(project_path)
    end

    bname = basename(filename)

    if verbose
        header_print("Test Configuration")
        info_print("File:", filename)

        if !isempty(patterns)
            info_print("Patterns:")
            for (i, pattern) in enumerate(patterns)
                pattern_str = if isa(pattern, Regex)
                    "Regex: $(pattern.pattern)"
                elseif isa(pattern, AbstractRange)
                    "Lines: $(first(pattern))-$(last(pattern))"
                elseif isa(pattern, Integer)
                    "Line: $pattern"
                elseif isa(pattern, Expr)
                    "Expression: $(pattern)"
                else
                    "String: \"$pattern\""
                end
                detail_print("[$i] $pattern_str")
            end
        end

        if filter_lines !== nothing
            sorted_lines = sort(collect(filter_lines))
            info_print("Filter lines: $(join(sorted_lines, ", "))")
        end

        if isempty(patterns)
            info_print("No patterns specified, running all tests with `include`")
        end

        header_print("Running Tests")
    end

    topmodule = @something app_runner_module[] Main
    if isempty(patterns)
        if source === nothing
            return Test.@testset "$bname" verbose=verbose Base.IncludeInto(topmodule)(filename)
        else
            # Resolve `filename` against `root_path` so relative `include` calls in `source`
            # can find workspace files. We mirror `runtest`'s rule (see `handle_include`):
            # only apply `root_path` when `filename` carries no directory component, so
            # callers passing real paths keep their `dirname`-based resolution.
            resolved_filename =
                root_path !== nothing && isempty(dirname(filename)) ?
                    joinpath(root_path, filename) : filename
            return Test.@testset "$bname" verbose=verbose include_string_with_source_path(topmodule, source, resolved_filename)
        end
    else
        return Test.@testset TestRunnerTestSet "$bname" verbose=verbose runtest(filename, patterns; filter_lines, topmodule, source, root_path)
    end
end

# Wrap `Base.include_string` so nested `include` calls inside `source` resolve relative to
# `filename`'s directory. `Base.include` does this via `task_local_storage[:SOURCE_PATH]`,
# but `Base.include_string` does not, so we set it ourselves around the call.
function include_string_with_source_path(mod::Module, source::AbstractString, filename::AbstractString)
    tls = task_local_storage()
    prev = get(tls, :SOURCE_PATH, nothing)
    tls[:SOURCE_PATH] = filename
    try
        return Base.include_string(mod, source, filename)
    finally
        if prev === nothing
            delete!(tls, :SOURCE_PATH)
        else
            tls[:SOURCE_PATH] = prev
        end
    end
end

function runtest_json(
        filename::String, patterns::Vector{Any}, filter_lines, verbose::Bool, project,
        source::Union{Nothing,String}=nothing, root_path::Union{Nothing,String}=nothing
    )
    # Redirect stdout to capture ALL output (including info_print, header_print, etc.)
    original_stdout = stdout
    (rd, wr) = redirect_stdout()

    local stats::TestRunnerStats = TestRunnerStats()
    local diagnostics::Vector{TestRunnerDiagnostic} = TestRunnerDiagnostic[]
    last_toplevel_testset[] = nothing
    start_time = time()
    try
        result = runtest_internal(filename, patterns, filter_lines, verbose, project, source, root_path)
        stats = testset_stats(result)
        return 0
    catch e # Any test failures/errors cause TestSetException to be thrown
        e isa Test.TestSetException || rethrow(e)
        duration = time() - start_time
        stats = extract_test_stats_from_exception(e, duration)
        diagnostics = extract_diagnostics_from_exception(e)
        return 1
    finally
        redirect_stdout(original_stdout)
        close(wr)
        logs = read(rd, String)
        close(rd)
        patterns = isempty(patterns) ? nothing : patterns
        testsets = testset_results(filename, source)
        result = TestRunnerResult(;
            filename,
            patterns,
            stats,
            logs,
            diagnostics,
            testsets)
        JSON3.write(stdout, result)
    end
end

function runtest_app(
        filename::String, patterns::Vector{Any}, filter_lines, verbose::Bool, project, json_output::Bool,
        read_stdin::Bool=false, root_path::Union{Nothing,String}=nothing
    )
    source = read_stdin ? read(stdin, String) : nothing
    if source === nothing && !isfile(filename)
        error_print("File not found:", filename)
        return 1
    end
    if json_output
        return runtest_json(filename, patterns, filter_lines, verbose, project, source, root_path)
    else
        runtest_internal(filename, patterns, filter_lines, verbose, project, source, root_path)
        return 0
    end
end

end # module App
