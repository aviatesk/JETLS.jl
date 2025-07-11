module TrimAnalyzerApp

using ..TrimAnalyzer: report_trim
using JET: JET
using LSP
using LSP.URIs2
using JSON3

function print_usage()
    println("""TrimAnalyzer - Detect dispatch errors in Julia code

    Usage:
      report-trim [options] <file-path>

    Options:
      --project[=<dir>]     Set project/environment (same as Julia's --project)
      --json                Output results in JSON format
      -h, --help            Show this help message

    Examples:
      report-trim example.jl
      report-trim --json example.jl
      report-trim --project=@. example.jl
      report-trim --project=/path/to/project example.jl
    """)
end

# TODO Share code with JETLS.jl

"""
    fix_build_path(path::AbstractString) -> fixed_path::AbstractString

If this Julia is a built one, convert `path` to `fixed_path`, which is a path to the main
files that are editable (or tracked by git).
"""
function fix_build_path end
let build_dir = normpath(Sys.BINDIR, "..", ".."), # with path separator at the end
    share_path = normpath(Sys.BINDIR, Base.DATAROOTDIR, "julia") # without path separator at the end
    global fix_build_path
    if ispath(normpath(build_dir), "base")
        build_path = splitdir(build_dir)[1] # remove the path separator
        fix_build_path(path::AbstractString) = replace(path, share_path => build_path)
    else
        fix_build_path(path::AbstractString) = path
    end
end

to_full_path(file::Symbol) = to_full_path(String(file))
function to_full_path(file::AbstractString)
    file = Base.fixup_stdlib_path(file)
    file = something(Base.find_source_file(file), file)
    # TODO we should probably make this configurable
    return fix_build_path(abspath(file))
end

function jet_frame_to_range(frame)
    line = JET.fixed_line_number(frame)
    return line_range(fixed_line_number(line))
end

fixed_line_number(line) = line == 0 ? line : line - 1

function line_range(line::Int)
    start = Position(; line, character=0)
    var"end" = Position(; line, character=Int(typemax(Int32)))
    return Range(; start, var"end")
end

function jet_inference_error_report_to_diagnostic(@nospecialize report::JET.InferenceErrorReport)
    topframe = report.vst[1]
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report_message(io, report)
    end
    relatedInformation = DiagnosticRelatedInformation[
        let frame = report.vst[i],
            message = sprint(JET.print_frame_sig, frame, JET.PrintConfig())
            DiagnosticRelatedInformation(;
                location = Location(;
                    uri = filepath2uri(to_full_path(frame.file)),
                    range = jet_frame_to_range(frame)),
                message)
        end
        for i = 2:length(report.vst)]
    return Diagnostic(;
        range = jet_frame_to_range(topframe),
        severity = LSP.DiagnosticSeverity.Error,
        message,
        source = "TrimAnalyzer",
        relatedInformation)
end

module MainModule end

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

function (@main)(args::Vector{String})
    json_output = false
    filepath = nothing
    project = nothing

    i = 1
    while i <= length(args)
        arg = args[i]

        if arg == "--json"
            json_output = true
        elseif arg == "-h" || arg == "--help"
            print_usage()
            return 0
        elseif startswith(arg, "--project=")
            project = arg[11:end]
        elseif arg == "--project"
            # Handle --project without equals sign (use current directory)
            project = "."
        elseif startswith(arg, "-")
            println(stderr, "Error: Unknown option: $arg")
            println(stderr, "Run with --help to see available options")
            return 1
        else
            if filepath !== nothing
                println(stderr, "Error: Multiple file paths provided")
                return 1
            end
            filepath = arg
        end
        i += 1
    end

    if filepath === nothing
        println(stderr, "Error: No file path provided")
        println(stderr)
        print_usage()
        return 1
    end

    if !isfile(filepath)
        println(stderr, "Error: File not found: $filepath")
        return 1
    end

    # Set up LOAD_PATH based on project
    if Base.should_use_main_entrypoint()
        empty!(LOAD_PATH)
        push!(LOAD_PATH, "@", "@v$(VERSION.major).$(VERSION.minor)", "@stdlib")
    end

    if project !== nothing
        project_path = parse_project_path(project, filepath)
        pushfirst!(LOAD_PATH, project_path)
    end

    MainModule = Core.eval(Main, :(module MainModule end))
    try
        Base.include(MainModule, filepath)
    catch e
        println(stderr, "Error loading file: ", e)
        return 1
    end

    if !(@invokelatest isdefinedglobal(MainModule, :main))
        println(stderr, "Error: `main` is not defined in $filepath")
        return 1
    end

    result = report_trim(@invokelatest(MainModule.main), (Vector{String},))

    reports = JET.get_reports(result)
    success = isempty(reports)

    if json_output
        diagnostics = LSP.Diagnostic[]
        if !success
            for report in reports
                push!(diagnostics, jet_inference_error_report_to_diagnostic(report))
            end
        end
        JSON3.write(stdout, (;
            filepath,
            success,
            diagnostics))
        println(stdout)
    else
        show(stdout, result)
    end

    return success ? 0 : 1
end

end # module TrimAnalyzerApp
