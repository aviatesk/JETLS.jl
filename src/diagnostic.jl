# configuration
# =============

# parse and validation
# --------------------

struct DiagnosticConfigError <: Exception
    msg::AbstractString
end
Base.showerror(io::IO, e::DiagnosticConfigError) = print(io, "DiagnosticConfigError: ", e.msg)

function parse_diagnostic_severity(
        @nospecialize(severity_value), pattern::AbstractString
    )
    if severity_value isa Int
        if 0 ≤ severity_value ≤ 4
            return severity_value
        else
            throw(DiagnosticConfigError(
                lazy"Invalid severity value \"$severity_value\" for diagnostic pattern \"$pattern\". " *
                "Valid integer values are: 0 (off), 1 (error), 2 (warning), 3 (information), 4 (hint)"))
        end
    elseif severity_value isa String
        severity_str = lowercase(severity_value)
        if severity_str == "off"
            return 0
        elseif severity_str == "error"
            return DiagnosticSeverity.Error
        elseif severity_str == "warning" || severity_str == "warn"
            return DiagnosticSeverity.Warning
        elseif severity_str == "information" || severity_str == "info"
            return DiagnosticSeverity.Information
        elseif severity_str == "hint"
            return DiagnosticSeverity.Hint
        else
            throw(DiagnosticConfigError(
                lazy"Invalid severity value \"$severity_value\" for diagnostic pattern \"$pattern\". " *
                "Valid string values are: \"off\", \"error\", \"warning\"/\"warn\", \"information\"/\"info\", \"hint\""))
        end
    else
        throw(DiagnosticConfigError(
            lazy"Invalid severity value \"$severity_value\" for diagnostic pattern \"$pattern\". " *
            "Severity must be an integer (0-4) or string"))
    end
end

function parse_diagnostic_pattern(x::AbstractDict{String})
    if !haskey(x, "pattern")
        throw(DiagnosticConfigError("Missing required field `pattern` in diagnostic pattern"))
    end
    pattern_value = x["pattern"]
    if !(pattern_value isa String)
        throw(DiagnosticConfigError(
            lazy"Invalid `pattern` value. Must be a string, got $(typeof(pattern_value))"))
    end

    for key in keys(x)
        if key ∉ ("pattern", "match_by", "match_type", "severity", "path")
            throw(DiagnosticConfigError(
                lazy"Unknown field \"$key\" in diagnostic pattern for pattern \"$pattern_value\". " *
                "Valid fields are: pattern, match_by, match_type, severity, path"))
        end
    end

    if !haskey(x, "match_by")
        throw(DiagnosticConfigError(
            lazy"Missing required field `match_by` in diagnostic pattern for pattern \"$pattern_value\""))
    end
    match_by = x["match_by"]
    if !(match_by isa String)
        throw(DiagnosticConfigError(
            lazy"Invalid `match_by` value for pattern \"$pattern_value\". Must be a string, got $(typeof(match_by))"))
    end
    if !(match_by in ("code", "message"))
        throw(DiagnosticConfigError(
            lazy"Invalid `match_by` value \"$match_by\" for pattern \"$pattern_value\". Must be \"code\" or \"message\""))
    end

    if !haskey(x, "match_type")
        throw(DiagnosticConfigError(
            lazy"Missing required field `match_type` in diagnostic pattern for pattern \"$pattern_value\""))
    end
    match_type = x["match_type"]
    if !(match_type isa String)
        throw(DiagnosticConfigError(
            lazy"Invalid `match_type` value for pattern \"$pattern_value\". Must be a string, got $(typeof(match_type))"))
    end
    if !(match_type in ("literal", "regex"))
        throw(DiagnosticConfigError(
            lazy"Invalid `match_type` value \"$match_type\" for pattern \"$pattern_value\". Must be \"literal\" or \"regex\""))
    end

    pattern = if match_type == "regex"
        try
            Regex(pattern_value)
        catch e
            throw(DiagnosticConfigError(
                lazy"Invalid regex pattern \"$pattern_value\": $(sprint(showerror, e))"))
        end
    else
        pattern_value
    end

    if !haskey(x, "severity")
        throw(DiagnosticConfigError(
            lazy"Missing required field `severity` in diagnostic pattern for pattern \"$pattern_value\""))
    end
    severity = parse_diagnostic_severity(x["severity"], pattern_value)

    path_glob = if haskey(x, "path")
        path_value = x["path"]
        if !(path_value isa String)
            throw(DiagnosticConfigError(
                lazy"Invalid `path` value for pattern \"$pattern_value\". Must be a string, got $(typeof(path_value))"))
        end
        try
            Glob.FilenameMatch(path_value, "dp")
        catch e
            throw(DiagnosticConfigError(
                lazy"Invalid glob pattern \"$path_value\" for pattern \"$pattern_value\": $(sprint(showerror, e))"))
        end
    else
        nothing
    end

    return DiagnosticPattern(pattern, match_by, match_type, severity, path_glob, pattern_value)
end

# application
# -----------

"""
    calculate_match_specificity(pattern, target, is_message_match) -> UInt

Calculate the specificity score for a diagnostic pattern match.

# Priority Strategy
Higher specificity scores indicate more specific matches that should take precedence.
The scoring follows this priority order (highest to lowest):

1. **Message literal match**: `4`
2. **Message regex match**: `3`
3. **Code literal match**: `2`
4. **Code regex match**: `1`

Message-based patterns receive a priority bonus because they allow more fine-grained
control over specific diagnostic instances, whereas code-based patterns are more
categorical.

# Returns
- `0` if the pattern does not match the target
- An unsigned integer representing the match specificity if the pattern matches
"""
function calculate_match_specificity(
        pattern::Union{Regex,String},
        target::String,
        is_message_match::Bool
    )
    local specificity::UInt8 = 0
    if pattern isa String
        specificity = pattern == target ? 2 : 0
    else
        specificity = occursin(pattern, target) ? 1 : 0
    end
    specificity == 0 && return specificity
    if is_message_match
        specificity += 2
    end
    return specificity
end

function _apply_diagnostic_config(
        diagnostic::Diagnostic, manager::ConfigManager, uri::URI,
        root_path::Union{Nothing,String}
    )
    code = diagnostic.code
    if !(code isa String)
        if JETLS_DEV_MODE
            @warn "Unexpected diagnostic code type" code
        elseif JETLS_TEST_MODE
            error(lazy"Unexpected diagnostic code type: $code")
        end
        return diagnostic
    elseif code ∉ ALL_DIAGNOSTIC_CODES
        if JETLS_DEV_MODE
            @warn "Unknown diagnostic code" code
        elseif JETLS_TEST_MODE
            error(lazy"Unknown diagnostic code: $code")
        end
        return diagnostic
    end

    patterns = get_config(manager, :diagnostic, :patterns)
    if isempty(patterns)
        # Diagnostics with severity=0 are off by default; filter them out
        return diagnostic.severity == 0 ? missing : diagnostic
    end

    filepath = uri2filename(uri)
    if root_path !== nothing && startswith(filepath, root_path)
        path_for_glob = relpath(filepath, root_path)
    else
        path_for_glob = filepath
    end
    message = diagnostic.message
    severity = nothing
    best_specificity = 0
    for pattern_config in patterns
        globpath = pattern_config.path
        if globpath !== nothing && !occursin(globpath, path_for_glob)
            continue
        end
        target = pattern_config.match_by == "message" ? message : code
        is_message_match = pattern_config.match_by == "message"
        specificity = calculate_match_specificity(
            pattern_config.pattern, target, is_message_match)
        if specificity > best_specificity
            best_specificity = specificity
            severity = pattern_config.severity
        end
    end

    if severity === nothing
        return diagnostic.severity == 0 ? missing : diagnostic
    elseif severity == 0
        return missing
    elseif severity == diagnostic.severity
        return nothing
    else
        return Diagnostic(diagnostic; severity)
    end
end

function apply_diagnostic_config!(
        diagnostics::Vector{Diagnostic}, manager::ConfigManager, uri::URI,
        root_path::Union{Nothing,String}
    )
    get_config(manager, :diagnostic, :enabled) || return empty!(diagnostics)
    i = 1
    while i <= length(diagnostics)
        applied = _apply_diagnostic_config(diagnostics[i], manager, uri, root_path)
        if applied === missing
            deleteat!(diagnostics, i)
            continue
        end
        if applied !== nothing
            diagnostics[i] = applied
        end
        i += 1
    end
    return diagnostics
end

function diagnostic_code_description(code::AbstractString)
    return CodeDescription(;
        href = URI("https://aviatesk.github.io/JETLS.jl/release/diagnostic/#diagnostic/reference/$code"))
end

# utilities
# =========

function jet_frame_to_location(frame)
    frame.file === :none && return nothing
    return Location(;
        uri = something(jet_frame_to_uri(frame)),
        range = jet_frame_to_range(frame))
end

function jet_frame_to_uri(frame)
    frame.file === :none && return nothing
    filename = String(frame.file)
    # TODO Clean this up and make we can always use `filename2uri` here.
    if startswith(filename, "Untitled")
        return filename2uri(filename)
    else
        return filepath2uri(to_full_path(filename))
    end
end

function jet_frame_to_range(frame)
    line = JET.fixed_line_number(frame)
    return line_range(line)
end

# 1 based line to LSP-compatible line range
function line_range(line::Int)
    line = line < 1 ? 0 : line - 1
    start = Position(; line, character=0)
    var"end" = Position(; line, character=Int(typemax(Int32)))
    return Range(; start, var"end")
end
function lines_range((start_line, end_line)::Pair{Int,Int})
    start_line = start_line < 1 ? 0 : start_line - 1
    end_line = end_line < 1 ? 0 : end_line - 1
    start = Position(; line=start_line, character=0)
    var"end" = Position(; line=end_line, character=Int(typemax(Int32)))
    return Range(; start, var"end")
end

# syntax diagnostics
# ==================

function parsed_stream_to_diagnostics(fi::FileInfo)
    diagnostics = Diagnostic[]
    for diagnostic in fi.parsed_stream.diagnostics
        push!(diagnostics, jsdiag_to_lspdiag(diagnostic, fi))
    end
    return diagnostics
end

function jsdiag_to_lspdiag(diagnostic::JS.Diagnostic, fi::FileInfo)
    return Diagnostic(;
        range = jsobj_to_range(diagnostic, fi),
        severity =
            diagnostic.level === :error ? DiagnosticSeverity.Error :
            diagnostic.level === :warning ? DiagnosticSeverity.Warning :
            diagnostic.level === :note ? DiagnosticSeverity.Information :
            DiagnosticSeverity.Hint,
        message = diagnostic.message,
        source = DIAGNOSTIC_SOURCE_LIVE,
        code = SYNTAX_DIAGNOSTIC_CODE,
        codeDescription = diagnostic_code_description(SYNTAX_DIAGNOSTIC_CODE))
end

# JET diagnostics
# ===============

function jet_result_to_diagnostics!(uri2diagnostics::URI2Diagnostics, result::JET.JETToplevelResult, postprocessor::JET.PostProcessor)
    for report in result.res.toplevel_error_reports
        if report isa JET.LoweringErrorReport || report isa JET.MacroExpansionErrorReport
            # the equivalent report should have been reported by `lowering_diagnostics!`
            # with more precise location information
            continue
        end
        diagnostic = jet_toplevel_error_report_to_diagnostic(report, postprocessor)
        filename = report.file
        filename === :none && continue
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(to_full_path(filename))
        end
        push!(uri2diagnostics[uri], diagnostic)
    end
    displayable_reports = collect_displayable_reports(result.res.inference_error_reports, keys(uri2diagnostics))
    jet_inference_error_reports_to_diagnostics!(uri2diagnostics, displayable_reports, postprocessor)
    return uri2diagnostics
end

# toplevel diagnostic
# -------------------

function jet_toplevel_error_report_to_diagnostic(
        @nospecialize(report::JET.ToplevelErrorReport), postprocessor::JET.PostProcessor
    )
    if report isa JET.ParseErrorReport
        # TODO: Pass correct encoding here
        fi = FileInfo(#=version=#0, report.source.code, JS.filename(report.source), PositionEncodingKind.UTF16)
        return jsdiag_to_lspdiag(report.diagnostic, fi)
    end
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report(io, report)
    end |> postprocessor
    return Diagnostic(;
        range = line_range(report.line),
        severity = DiagnosticSeverity.Error,
        message,
        source = DIAGNOSTIC_SOURCE_SAVE,
        code = TOPLEVEL_ERROR_CODE,
        codeDescription = diagnostic_code_description(TOPLEVEL_ERROR_CODE))
end

# inference diagnostic
# --------------------

function jet_inference_error_reports_to_diagnostics!(
        uri2diagnostics::URI2Diagnostics, reports::Vector{JET.InferenceErrorReport},
        postprocessor::JET.PostProcessor
    )
    for report in reports
        diagnostic = jet_inference_error_report_to_diagnostic(report, postprocessor)
        topframeidx = first(inference_error_report_stack(report))
        topframe = report.vst[topframeidx]
        topframe.file === :none && continue # TODO Figure out why this is necessary
        uri = jet_frame_to_uri(topframe)
        push!(uri2diagnostics[uri], diagnostic) # collect_displayable_reports asserts that this `uri` key exists for `uri2diagnostics`
    end
    return uri2diagnostics
end

function jet_inference_error_report_to_diagnostic(@nospecialize(report::JET.InferenceErrorReport), postprocessor::JET.PostProcessor)
    rstack = inference_error_report_stack(report)
    topframe = report.vst[first(rstack)]
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report_message(io, report)
    end |> postprocessor
    relatedInformation = DiagnosticRelatedInformation[]
    for i = 2:length(rstack)
        frame = report.vst[rstack[i]]
        location = @something jet_frame_to_location(frame) continue
        local message = postprocessor(sprint(JET.print_frame_sig, frame, JET.PrintConfig()))
        push!(relatedInformation, DiagnosticRelatedInformation(; location, message))
    end
    code = inference_error_report_code(report)
    return Diagnostic(;
        range = jet_frame_to_range(topframe),
        severity = inference_error_report_severity(report),
        message,
        source = DIAGNOSTIC_SOURCE_SAVE,
        code,
        codeDescription = diagnostic_code_description(code),
        relatedInformation)
end

function inference_error_report_code(@nospecialize report::JET.InferenceErrorReport)
    if report isa UndefVarErrorReport
        if report.var isa GlobalRef
            return INFERENCE_UNDEF_GLOBAL_VAR_CODE
        else
            return INFERENCE_UNDEF_STATIC_PARAM_CODE
        end
    elseif report isa FieldErrorReport
        return INFERENCE_FIELD_ERROR_CODE
    elseif report isa BoundsErrorReport
        return INFERENCE_BOUNDS_ERROR_CODE
    end
    error(lazy"Diagnostic code is not defined for this report: $report")
end

# toplevel warning diagnostic
# ===========================

abstract type ToplevelWarningReport end

toplevel_warning_report_to_uri(report::ToplevelWarningReport) = toplevel_warning_report_to_uri_impl(report)::URI
toplevel_warning_report_to_uri_impl(::ToplevelWarningReport) =
    error("Missing `toplevel_warning_report_to_uri_impl(::ToplevelWarningReport)` interface")

toplevel_warning_report_to_diagnostic(report::ToplevelWarningReport, sfi::SavedFileInfo, postprocessor::JET.PostProcessor) =
    toplevel_warning_report_to_diagnostic_impl(report, sfi, postprocessor)::Diagnostic
toplevel_warning_report_to_diagnostic_impl(::ToplevelWarningReport, ::SavedFileInfo, ::JET.PostProcessor) =
    error("Missing `toplevel_warning_report_to_diagnostic_impl(::ToplevelWarningReport, ::SavedFileInfo, ::JET.PostProcessor)` interface")

function toplevel_warning_reports_to_diagnostics!(
        uri2diagnostics::URI2Diagnostics, reports::Vector{ToplevelWarningReport},
        server::Server, postprocessor::JET.PostProcessor
    )
    for report in reports
        uri = toplevel_warning_report_to_uri(report)
        haskey(uri2diagnostics, uri) || continue
        sfi = @something get_saved_file_info(server.state, uri) continue
        diagnostic = toplevel_warning_report_to_diagnostic(report, sfi, postprocessor)
        push!(uri2diagnostics[uri], diagnostic)
    end
    return uri2diagnostics
end

struct MethodOverwriteReport <: ToplevelWarningReport
    mod::Module
    sig::Type
    filepath::String
    lines::Pair{Int,Int}
    original_filepath::String
    original_lines::Pair{Int,Int}
    MethodOverwriteReport(
        mod::Module, @nospecialize(sig::Type), filepath::AbstractString, lines::Pair{Int,Int},
        original_filepath::AbstractString, original_lines::Pair{Int,Int}
    ) = new(mod, sig, filepath, lines, original_filepath, original_lines)
end

toplevel_warning_report_to_uri_impl(report::MethodOverwriteReport) = filepath2uri(report.filepath)

function toplevel_warning_report_to_diagnostic_impl(report::MethodOverwriteReport, ::SavedFileInfo, postprocessor::JET.PostProcessor)
    sig_str = postprocessor(sprint(Base.show_tuple_as_call, Symbol(""), report.sig))
    mod_str = postprocessor(sprint(show, report.mod))
    message = "Method definition $sig_str in module $mod_str overwritten"
    relatedInformation = DiagnosticRelatedInformation[
        DiagnosticRelatedInformation(;
            location = Location(;
                uri = filepath2uri(report.original_filepath),
                range = lines_range(report.original_lines)),
            message = "The first method definition $sig_str")
    ]
    return Diagnostic(;
        range = lines_range(report.lines),
        severity = DiagnosticSeverity.Warning,
        message,
        source = DIAGNOSTIC_SOURCE_SAVE,
        code = TOPLEVEL_METHOD_OVERWRITE_CODE,
        codeDescription = diagnostic_code_description(TOPLEVEL_METHOD_OVERWRITE_CODE),
        relatedInformation)
end

struct AbstractFieldReport <: ToplevelWarningReport
    filepath::String
    fieldline::Union{Int,JS.SyntaxNode}
    typ::Type
    fname::Symbol
    ft
    AbstractFieldReport(
        filepath::AbstractString, fieldline::Union{Int,JS.SyntaxNode}, @nospecialize(typ::Type), fname::Symbol, @nospecialize(ft)
    ) = new(filepath, fieldline, typ, fname, ft)
end

toplevel_warning_report_to_uri_impl(report::AbstractFieldReport) = filepath2uri(report.filepath)

function toplevel_warning_report_to_diagnostic_impl(report::AbstractFieldReport, sfi::SavedFileInfo, postprocessor::JET.PostProcessor)
    typ_str = postprocessor(sprint(show, report.typ))
    ft_str = postprocessor(sprint(show, report.ft))
    message = "`$typ_str` has abstract field `$(report.fname)::$ft_str`"
    fieldline = report.fieldline
    range = fieldline isa Int ? line_range(fieldline) : jsobj_to_range(fieldline, sfi)
    return Diagnostic(;
        range,
        severity = DiagnosticSeverity.Information,
        message,
        source = DIAGNOSTIC_SOURCE_SAVE,
        code = TOPLEVEL_ABSTRACT_FIELD_CODE,
        codeDescription = diagnostic_code_description(TOPLEVEL_ABSTRACT_FIELD_CODE))
end

# lowering diagnostic
# ===================

const JL_MACRO_FILE = only(methods(JL.expand_macro, (JL.MacroExpansionContext,JS.SyntaxTree))).file
function scrub_expand_macro_stacktrace(stacktrace::Vector{Base.StackTraces.StackFrame})
    idx = @something findfirst(stacktrace) do stackframe::Base.StackTraces.StackFrame
        stackframe.func === :expand_macro && stackframe.file === JL_MACRO_FILE
    end return stacktrace
    return stacktrace[1:idx-1]
end

function stacktrace_to_related_information(stacktrace::Vector{Base.StackTraces.StackFrame})
    relatedInformation = DiagnosticRelatedInformation[]
    for stackframe in stacktrace
        stackframe.file === :none && continue
        uri = filepath2uri(to_full_path(stackframe.file))
        range = line_range(stackframe.line)
        location = Location(; uri, range)
        message = let linfo = stackframe.linfo
            linfo isa Core.CodeInstance && (linfo = linfo.def)
            if linfo isa Core.MethodInstance
                sprint(Base.show_tuple_as_call, Symbol(""), linfo.specTypes)
            else
                String(stackframe.func)
            end
        end
        push!(relatedInformation, DiagnosticRelatedInformation(; location, message))
    end
    return relatedInformation
end

# TODO Use actual file cache (with proper character encoding)
function provenances_to_related_information!(relatedInformation::Vector{DiagnosticRelatedInformation}, provs, msg)
    for prov in provs
        filename = JS.filename(prov)
        uri = filepath2uri(to_full_path(filename))
        sr = JS.sourceref(prov)
        if sr isa JS.SourceRef
            # use precise location information if available
            sf = JS.sourcefile(sr)
            code = JS.sourcetext(sf)
            location = Location(;
                uri,
                range = Range(;
                    start = offset_to_xy(code, JS.first_byte(sr), filename),
                    var"end" = offset_to_xy(code, JS.last_byte(sr), filename)))
            message = JS.sourcetext(sr)
        else
            location = Location(;
                uri,
                range = line_range(first(JS.source_location(prov))))
            message = msg
        end
        push!(relatedInformation, DiagnosticRelatedInformation(; location, message))
    end
    return relatedInformation
end

struct LoweringDiagnosticKey
    range::Range
    kind::Symbol
    name::String
end

function analyze_unused_bindings!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, st0::JS.SyntaxTree, ctx3::JL.VariableAnalysisContext,
        binding_occurrences, ismacro, reported::Set{LoweringDiagnosticKey};
        allow_unused_underscore::Bool
    )
    for (binfo, occurrences) in binding_occurrences
        bk = binfo.kind
        bk === :global && continue
        if any(occurrence::BindingOccurrence->occurrence.kind===:use, occurrences)
            continue
        end
        bn = binfo.name
        if ismacro[] && (bn == "__module__" || bn == "__source__")
            continue
        end
        if allow_unused_underscore && startswith(bn, '_')
            continue
        end
        provs = JS.flattened_provenance(JL.binding_ex(ctx3, binfo.id))
        prov = first(provs)
        range = jsobj_to_range(prov, fi)
        key = LoweringDiagnosticKey(range, bk, bn)
        key in reported ? continue : push!(reported, key)
        if bk === :argument
            message = "Unused argument `$bn`"
            code = LOWERING_UNUSED_ARGUMENT_CODE
            data = nothing
        else
            message = "Unused local binding `$bn`"
            code = LOWERING_UNUSED_LOCAL_CODE
            data = compute_unused_variable_data(st0, prov, fi)
        end
        push!(diagnostics, Diagnostic(;
            range,
            severity = DiagnosticSeverity.Information,
            message,
            source = DIAGNOSTIC_SOURCE_LIVE,
            code,
            codeDescription = diagnostic_code_description(code),
            tags = DiagnosticTag.Ty[DiagnosticTag.Unnecessary],
            data))
    end
end

# This analysis reports `lowering/undef-global-var` on a change basis, utilizing an already
# analyzed analysis context. Full-analysis also reports similar diagnostics as
# `inference/undef-global-var`. These two diagnostics have the following differences:
# - `inference/undef-global-var` (full-analysis): Triggered on a save basis. Since it's not
#   integrated with JuliaLowering, position information can only be reported on a line basis.
#   On the other hand, it can also report cases like `Base.undefvar` and generally is more correct.
# - `lowering/undef-global-var` (lowering analysis): Triggered on a change basis, so feedback is
#   faster. Since it's based on JuliaLowering, position information is accurate. However, it
#   cannot analyze cases like `Base.undefvar`, so it basically detects a subset of what
#   full-analysis reports.
function analyze_undefined_global_bindings!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, ctx3::JL.VariableAnalysisContext,
        binding_occurrences, reported::Set{LoweringDiagnosticKey};
        analyzer::Union{Nothing,LSAnalyzer} = nothing,
        postprocessor::LSPostProcessor = LSPostProcessor()
    )
    world = Base.get_world_counter()
    for (binfo, occurrences) in binding_occurrences
        bk = binfo.kind
        bk === :global || continue
        binfo.is_internal && continue
        startswith(binfo.name, '#') && continue
        any(o->o.kind===:def, occurrences) && continue
        Base.invoke_in_world(world, isdefinedglobal, binfo.mod, Symbol(binfo.name))::Bool && continue
        if !isnothing(analyzer)
            bp = Base.lookup_binding_partition(world, GlobalRef(binfo.mod, Symbol(binfo.name)))
            haskey(JET.AnalyzerState(analyzer).binding_states, bp) && continue
        end
        bn = binfo.name
        provs = JS.flattened_provenance(JL.binding_ex(ctx3, binfo.id))
        range = jsobj_to_range(first(provs), fi)
        key = LoweringDiagnosticKey(range, bk, bn)
        key in reported ? continue : push!(reported, key)
        code = LOWERING_UNDEF_GLOBAL_VAR_CODE
        push!(diagnostics, Diagnostic(;
            range,
            severity = DiagnosticSeverity.Warning,
            message = postprocessor("`$(binfo.mod).$(binfo.name)` is not defined"),
            source = DIAGNOSTIC_SOURCE_LIVE,
            code,
            codeDescription = diagnostic_code_description(code)))
    end
end

# This analysis reports `lowering/undef-local-var` on a change basis, based on
# `analyze_undef_all_lambdas`, which analyzes local binding definedness with the event
# based binding assignment reachability analysis.
# Severity levels:
# - Warning: `undef===true` → strict undef (guaranteed UndefVarError on some path)
# - Information: `undef===nothing` → maybe undef (possible UndefVarError)
function analyze_undefined_local_bindings!(
        diagnostics::Vector{Diagnostic}, uri::URI, fi::FileInfo,
        undef_info::Dict{JL.BindingInfo, UndefInfo},
        reported::Set{LoweringDiagnosticKey}
    )
    for (binfo, uinfo) in undef_info
        binfo.kind === :local || continue # defensive check (already filtered in analyze_undef)
        binfo.is_read || continue # optimization: skip expensive checks below if not read
        binfo.is_internal && continue
        startswith(binfo.name, '#') && continue
        undef_status = uinfo.undef
        undef_status === false && continue
        first_use_tree = first(uinfo.uses)
        provs = JL.flattened_provenance(first_use_tree)
        isempty(provs) && continue
        if length(provs) > 1 # From macro expanded code, ignore it for now
            continue
        end
        range = jsobj_to_range(first(provs), fi)
        key = LoweringDiagnosticKey(range, binfo.kind, binfo.name)
        key in reported ? continue : push!(reported, key)
        relatedInformation = DiagnosticRelatedInformation[]
        for def_tree in uinfo.defs
            def_provs = JL.flattened_provenance(def_tree)
            isempty(def_provs) && continue
            innermost = last(def_provs)
            uri2filename(uri) == JS.filename(innermost) || continue
            def_range = jsobj_to_range(innermost, fi)
            push!(relatedInformation, DiagnosticRelatedInformation(;
                location = Location(uri, def_range),
                message = "`$(binfo.name)` is defined here"))
        end
        push!(diagnostics, Diagnostic(;
            range,
            # Determine severity based on whether this is strict undef or maybe undef
            severity = undef_status === true ? DiagnosticSeverity.Warning : DiagnosticSeverity.Information,
            message = undef_status === true ?
                "Variable `$(binfo.name)` is used before it is defined" :
                "Variable `$(binfo.name)` may be used before it is defined",
            source = DIAGNOSTIC_SOURCE_LIVE,
            code = LOWERING_UNDEF_LOCAL_VAR_CODE,
            codeDescription = diagnostic_code_description(LOWERING_UNDEF_LOCAL_VAR_CODE),
            relatedInformation = @somereal relatedInformation Some(nothing)))
    end
end

function compute_unused_variable_data(
        st0::JS.SyntaxTree,
        prov::JS.SyntaxTree,
        fi::FileInfo
    )
    # Find parent K"=" node using byte_ancestors
    ancestors = byte_ancestors(st::JS.SyntaxTree->JS.kind(st)===JS.K"=", st0, JS.byte_range(prov))
    isempty(ancestors) && return nothing

    assignment = first(ancestors)
    JS.numchildren(assignment) ≥ 2 || return nothing

    lhs, rhs = assignment[1], assignment[2]

    # Check for destructuring patterns (tuple unpacking)
    is_tuple = JS.kind(lhs) === JS.K"tuple"
    if is_tuple
        return UnusedVariableData(true, nothing, nothing)
    end

    # lhs_eq_range: from LHS start to RHS start (exclusive)
    assignment_range = jsobj_to_range(assignment, fi)
    lhs_start = offset_to_xy(fi, JS.first_byte(lhs))
    rhs_start = offset_to_xy(fi, JS.first_byte(rhs))
    lhs_eq_range = Range(; start=lhs_start, var"end"=rhs_start)
    return UnusedVariableData(false, assignment_range, lhs_eq_range)
end

function analyze_captured_boxes!(
        diagnostics::Vector{Diagnostic}, uri::URI, fi::FileInfo,
        ctx4::JL.ClosureConversionCtx, st3::JL.SyntaxTree,
        reported::Set{LoweringDiagnosticKey}
    )
    for binfo in ctx4.bindings.info
        JL.is_boxed(binfo) || continue
        binfo.is_internal && continue
        startswith(binfo.name, '#') && continue
        bn = binfo.name
        provs = JL.flattened_provenance(JL.binding_ex(ctx4, binfo.id))
        range = jsobj_to_range(first(provs), fi)
        key = LoweringDiagnosticKey(range, :boxed, bn)
        key in reported ? continue : push!(reported, key)
        code = LOWERING_CAPTURED_BOXED_VARIABLE_CODE
        relatedInformation = find_capture_sites(st3, binfo, ctx4, uri, fi)
        push!(diagnostics, Diagnostic(;
            range,
            severity = DiagnosticSeverity.Information,
            message = "`$bn` is captured and boxed",
            source = DIAGNOSTIC_SOURCE_LIVE,
            code,
            codeDescription = diagnostic_code_description(code),
            relatedInformation))
    end
end

function find_capture_sites(
        st3::JL.SyntaxTree, binfo::JL.BindingInfo, ctx4::JL.ClosureConversionCtx,
        uri::URI, fi::FileInfo
    )
    relatedInformation = DiagnosticRelatedInformation[]
    for (_, closure_bindings) in ctx4.closure_bindings
        for lambda in closure_bindings.lambdas
            haskey(lambda.locals_capt, binfo.id) || continue
            lambda.locals_capt[binfo.id] || continue
            # Find the lambda in st3 that has matching lambda_bindings.self
            traverse(st3) do node::JL.SyntaxTree
                JS.kind(node) === JS.K"lambda" || return nothing
                hasproperty(node, :lambda_bindings) || return nothing
                lambda_bindings = node.lambda_bindings::JL.LambdaBindings
                lambda_bindings.self == lambda.self || return nothing
                # Find references to binfo.id inside this lambda
                traverse(node) do inner::JL.SyntaxTree
                    if JS.kind(inner) === JS.K"BindingId" && JL._binding_id(inner) == binfo.id
                        varprov = first(JL.flattened_provenance(inner))
                        push!(relatedInformation, DiagnosticRelatedInformation(;
                            location = Location(; uri, range = jsobj_to_range(varprov, fi)),
                            message = "Captured by closure"))
                    end
                end
                return TraversalNoRecurse()
            end
        end
    end
    return @somereal relatedInformation Some(nothing)
end

const SORT_IMPORTS_MAX_LINE_LENGTH = 92
const SORT_IMPORTS_INDENT = "    "

function analyze_unsorted_imports!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, st0::JS.SyntaxTree
    )
    traverse(st0) do st0′::JS.SyntaxTree
        kind = JS.kind(st0′)
        if kind ∉ JS.KSet"import using export public"
            return nothing
        end
        names = collect_import_names(st0′)
        if !is_sorted_imports(names)
            range = jsobj_to_range(st0′, fi)
            sorted_names = sort!(names; by=get_import_sort_key)
            base_indent = get_line_indent(fi, JS.first_byte(st0′))
            new_text = generate_sorted_import_text(st0′, sorted_names, base_indent)
            push!(diagnostics, Diagnostic(;
                range,
                severity = DiagnosticSeverity.Hint,
                message = "Names are not sorted alphabetically",
                source = DIAGNOSTIC_SOURCE_LIVE,
                code = LOWERING_UNSORTED_IMPORT_NAMES_CODE,
                codeDescription = diagnostic_code_description(LOWERING_UNSORTED_IMPORT_NAMES_CODE),
                data = UnsortedImportData(new_text)))
        end
        return TraversalNoRecurse()
    end
    return diagnostics
end

function generate_sorted_import_text(
        node::JS.SyntaxTree, sorted_names::Vector{JS.SyntaxTree},
        base_indent::Union{String,Nothing}
    )
    kind = JS.kind(node)
    keyword = kind === JS.K"import" ? "import" :
              kind === JS.K"using" ? "using" :
              kind === JS.K"export" ? "export" : "public"
    if kind === JS.K"import" || kind === JS.K"using"
        nchildren = JS.numchildren(node)
        if nchildren == 1 && JS.kind(node[1]) === JS.K":"
            module_path = lstrip(JS.sourcetext(node[1][1]))
            prefix = "$keyword $module_path: "
        else
            prefix = "$keyword "
        end
    else
        prefix = "$keyword "
    end
    name_texts = String[lstrip(JS.sourcetext(n)) for n in sorted_names]
    single_line = prefix * join(name_texts, ", ")
    if base_indent === nothing
        return single_line
    end
    if length(base_indent) + length(single_line) <= SORT_IMPORTS_MAX_LINE_LENGTH
        return single_line
    end
    continuation_indent = base_indent * SORT_IMPORTS_INDENT
    lines = String[prefix * name_texts[1]]
    current_line_idx = 1
    for i = 2:length(name_texts)
        name = name_texts[i]
        current_indent = current_line_idx == 1 ? base_indent : continuation_indent
        potential_line = lines[current_line_idx] * ", " * name
        if length(current_indent) + length(potential_line) <= SORT_IMPORTS_MAX_LINE_LENGTH
            lines[current_line_idx] = potential_line
        else
            lines[current_line_idx] *= ","
            push!(lines, continuation_indent * name)
            current_line_idx += 1
        end
    end
    return join(lines, "\n")
end

function collect_import_names(st0::JS.SyntaxTree)
    kind = JS.kind(st0)
    names = JS.SyntaxTree[]
    if kind === JS.K"import" || kind === JS.K"using"
        nchildren = JS.numchildren(st0)
        if nchildren == 1
            child = st0[1]
            if JS.kind(child) === JS.K":"
                for i = 2:JS.numchildren(child)
                    push!(names, child[i])
                end
            end
        elseif nchildren > 1
            for i = 1:nchildren
                push!(names, st0[i])
            end
        end
    elseif kind === JS.K"export" || kind === JS.K"public"
        for i = 1:JS.numchildren(st0)
            push!(names, st0[i])
        end
    end
    return names
end

function is_sorted_imports(names::Vector{JS.SyntaxTree})
    length(names) < 2 && return true
    for i = 1:length(names)-1
        key1 = get_import_sort_key(names[i])
        key2 = get_import_sort_key(names[i+1])
        if key1 > key2
            return false
        end
    end
    return true
end

function get_import_sort_key(st0::JS.SyntaxTree)
    kind = JS.kind(st0)
    if kind === JS.K"as"
        return get_import_sort_key(st0[1])
    elseif kind === JS.K"importpath"
        parts = String[]
        for i = 1:JS.numchildren(st0)
            child = st0[i]
            ckind = JS.kind(child)
            if ckind === JS.K"."
                push!(parts, ".")
            elseif ckind === JS.K"Identifier"
                push!(parts, JS.sourcetext(child))
            end
        end
        return join(parts)
    elseif kind === JS.K"Identifier"
        return JS.sourcetext(st0)
    else
        return JS.sourcetext(st0)
    end
end

function analyze_lowered_code!(
        diagnostics::Vector{Diagnostic}, uri::URI, fi::FileInfo, res::NamedTuple;
        skip_analysis_requiring_context::Bool = false,
        allow_unused_underscore::Bool = true,
        allow_throw_optimization::Bool = false,
        analyzer::Union{Nothing,LSAnalyzer} = nothing,
        postprocessor::LSPostProcessor = LSPostProcessor()
    )
    (; ctx3, ctx4, st0, st3) = res
    ismacro = Ref(false)
    binding_occurrences = compute_binding_occurrences(ctx3, st3; ismacro, include_global_bindings=true)
    reported = Set{LoweringDiagnosticKey}() # to prevent duplicate reports for unused default or keyword arguments

    analyze_unused_bindings!(diagnostics, fi, st0, ctx3, binding_occurrences, ismacro, reported; allow_unused_underscore)

    skip_analysis_requiring_context ||
        analyze_undefined_global_bindings!(diagnostics, fi, ctx3, binding_occurrences, reported; analyzer, postprocessor)

    undef_info = analyze_undef_all_lambdas(ctx3, st3; allow_throw_optimization)
    analyze_undefined_local_bindings!(diagnostics, uri, fi, undef_info, reported)

    analyze_captured_boxes!(diagnostics, uri, fi, ctx4, st3, reported)

    return diagnostics
end

function lowering_diagnostics!(
        diagnostics::Vector{Diagnostic}, uri::URI, fi::FileInfo, mod::Module, st0::JS.SyntaxTree;
        skip_analysis_requiring_context::Bool = false, kwargs...
    )
    @assert JS.kind(st0) ∉ JS.KSet"toplevel module"

    analyze_unsorted_imports!(diagnostics, fi, st0)

    world = Base.get_world_counter()
    res = try
        jl_lower_for_scope_resolution(mod, st0, world; recover_from_macro_errors=false, convert_closures=true)
    catch err
        if err isa JL.LoweringError
            push!(diagnostics, Diagnostic(;
                range = jsobj_to_range(err.ex, fi),
                severity = DiagnosticSeverity.Error,
                message = err.msg,
                source = DIAGNOSTIC_SOURCE_LIVE,
                code = LOWERING_ERROR_CODE,
                codeDescription = diagnostic_code_description(LOWERING_ERROR_CODE)))
        elseif err isa JL.MacroExpansionError
            if !skip_analysis_requiring_context
                st = scrub_expand_macro_stacktrace(stacktrace(catch_backtrace()))
                msg = err.msg
                inner = err.err
                if msg == "Macro not found" && inner isa UndefVarError
                    msg = "Macro name `$(inner.var)` not found"
                    relatedInformation = nothing
                else
                    msg *= "\n" * sprint(Base.showerror, inner)
                    relatedInformation = stacktrace_to_related_information(st)
                end
                provs = JS.flattened_provenance(err.ex)
                provs′ = @view provs[2:end]
                if !isempty(provs′)
                    relatedInformation = @something relatedInformation DiagnosticRelatedInformation[]
                    provenances_to_related_information!(relatedInformation, provs′, msg)
                end
                push!(diagnostics, Diagnostic(;
                    range = jsobj_to_range(first(provs), fi),
                    severity = DiagnosticSeverity.Error,
                    message = msg,
                    source = DIAGNOSTIC_SOURCE_LIVE,
                    code = LOWERING_MACRO_EXPANSION_ERROR_CODE,
                    codeDescription = diagnostic_code_description(LOWERING_MACRO_EXPANSION_ERROR_CODE),
                    relatedInformation))
            end
        else
            JETLS_DEBUG_LOWERING && @warn "Error in lowering (with macrocall nodes)"
            JETLS_DEBUG_LOWERING && showerror(stderr, err)
            JETLS_DEBUG_LOWERING && Base.show_backtrace(stderr, catch_backtrace())
        end

        st0 = without_kinds(st0, JS.KSet"error macrocall")
        try
            ctx1, st1 = JL.expand_forms_1(mod, st0, true, world)
            _jl_lower_for_scope_resolution(ctx1, st0, st1; convert_closures=true)
        catch
            # The same error has probably already been handled above
            return diagnostics
        end
    end

    allow_throw_optimization =
        Base.invoke_in_world(world, isdefinedglobal, mod, :throw)::Bool &&
        Base.invoke_in_world(world, getglobal, mod, :throw) === Core.throw

    return analyze_lowered_code!(diagnostics, uri, fi, res;
        skip_analysis_requiring_context, allow_throw_optimization, kwargs...)
end
lowering_diagnostics(args...; kwargs...) = lowering_diagnostics!(Diagnostic[], args...; kwargs...) # used by tests

# TODO use something like `JuliaInterpreter.ExprSplitter`

function toplevel_lowering_diagnostics(server::Server, uri::URI, file_info::FileInfo)
    diagnostics = Diagnostic[]
    st0_top = build_syntax_tree(file_info)
    skip_analysis_requiring_context = !has_analyzed_context(server.state, uri)
    allow_unused_underscore = get_config(server.state.config_manager, :diagnostic, :allow_unused_underscore)
    iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        pos = offset_to_xy(file_info, JS.first_byte(st0))
        (; mod, analyzer, postprocessor) = get_context_info(server.state, uri, pos)
        lowering_diagnostics!(diagnostics, uri, file_info, mod, st0; skip_analysis_requiring_context, allow_unused_underscore, analyzer, postprocessor)
    end
    return diagnostics
end

function iterate_toplevel_tree(callback, st0_top::JS.SyntaxTree)
    sl = JS.SyntaxList(st0_top)
    push!(sl, st0_top)
    while !isempty(sl)
        st0 = pop!(sl)
        if JS.kind(st0) === JS.K"toplevel"
            for i = JS.numchildren(st0):-1:1 # reversed since we use `pop!`
                push!(sl, st0[i])
            end
        elseif JS.kind(st0) === JS.K"module"
            stblk = st0[end]
            JS.kind(stblk) === JS.K"block" || continue
            for i = JS.numchildren(stblk):-1:1 # reversed since we use `pop!`
                push!(sl, stblk[i])
            end
        elseif JS.kind(st0) === JS.K"doc"
            # skip docstring expressions for now
            for i = JS.numchildren(st0):-1:1 # reversed since we use `pop!`
                if JS.kind(st0[i]) !== JS.K"string"
                    push!(sl, st0[i])
                end
            end
        else # st0 is lowerable tree
            callback(st0)
        end
    end
end

# textDocument/publishDiagnostics
# ===============================

function get_full_diagnostics(server::Server; ensure_cleared::Union{Bool,URI} = false)
    state = server.state
    uri2diagnostics = URI2Diagnostics()
    for (uri, analysis_info) in load(state.analysis_manager.cache)
        if analysis_info isa OutOfScope
            continue
        end
        diagnostics = get!(Vector{Diagnostic}, uri2diagnostics, uri)
        analysis_result = analysis_info
        full_diagnostics = get(analysis_result.uri2diagnostics, uri, nothing)
        if full_diagnostics !== nothing
            append!(diagnostics, full_diagnostics)
        end
    end
    merge_extra_diagnostics!(uri2diagnostics, server)
    if ensure_cleared isa URI && !haskey(uri2diagnostics, ensure_cleared)
        uri2diagnostics[ensure_cleared] = Diagnostic[]
    end
    map_notebook_diagnostics!(uri2diagnostics, state)
    return uri2diagnostics
end

function merge_extra_diagnostics!(uri2diagnostics::URI2Diagnostics, server::Server)
    for (_, extra_uri2diagnostics) in load(server.state.extra_diagnostics)
        merge_diagnostics!(uri2diagnostics, extra_uri2diagnostics)
    end
    return uri2diagnostics
end

function merge_diagnostics!(uri2diagnostics::URI2Diagnostics, other_uri2diagnostics::URI2Diagnostics)
    for (uri, diagnostics) in other_uri2diagnostics
        append!(get!(Vector{Diagnostic}, uri2diagnostics, uri), diagnostics)
    end
    return uri2diagnostics
end

"""
    notify_diagnostics!(server::Server; ensure_cleared::Union{Nothing,URI} = nothing)

Send `textDocument/publishDiagnostics` notifications to the client. This combines
diagnostics from full-analysis with extra diagnostics provided by sources like the
test runner.

When `ensure_cleared` is specified, guarantees that a notification is sent for that URI
even if it no longer has any diagnostics, ensuring the client clears any previously
displayed diagnostics for that URI.
"""
function notify_diagnostics!(server::Server; ensure_cleared::Union{Bool,URI} = false)
    notify_diagnostics!(server, get_full_diagnostics(server; ensure_cleared); ensure_cleared)
end

function notify_diagnostics!(server::Server, uri2diagnostics::URI2Diagnostics; ensure_cleared::Union{Bool,URI} = false)
    state = server.state
    all_files = get_config(state.config_manager, :diagnostic, :all_files)
    root_path = isdefined(state, :root_path) ? state.root_path : nothing
    for (uri, diagnostics) in uri2diagnostics
        if !all_files && !is_synchronized(state, uri)
            if ((ensure_cleared isa URI && uri == ensure_cleared) ||
                ensure_cleared === true) && !isempty(diagnostics)
                send(server, PublishDiagnosticsNotification(;
                    params = PublishDiagnosticsParams(;
                        uri,
                        diagnostics = Diagnostic[])))
            end
            continue
        end
        apply_diagnostic_config!(diagnostics, state.config_manager, uri, root_path)
        send(server, PublishDiagnosticsNotification(;
            params = PublishDiagnosticsParams(;
                uri,
                diagnostics)))
    end
end

function notify_temporary_diagnostics!(server::Server, temp_uri2diagnostics::URI2Diagnostics)
    uri2diagnostics = get_full_diagnostics(server)
    merge_diagnostics!(uri2diagnostics, temp_uri2diagnostics)
    notify_diagnostics!(server, uri2diagnostics)
end

clear_extra_diagnostics!(server::Server, args...) = clear_extra_diagnostics!(server.state, args...)
clear_extra_diagnostics!(state::ServerState, args...) = clear_extra_diagnostics!(state.extra_diagnostics, args...)
function clear_extra_diagnostics!(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey)
    return store!(extra_diagnostics) do data
        if haskey(data, key)
            new_data = copy(data)
            delete!(new_data, key)
            return new_data, true
        end
        return data, false
    end
end
function clear_extra_diagnostics!(extra_diagnostics::ExtraDiagnostics, uri::URI) # bulk deletion
    return store!(extra_diagnostics) do data
        any_deleted = false
        new_data = nothing
        for key in keys(data)
            if to_uri(key) == uri
                if new_data === nothing
                    new_data = copy(data)
                end
                delete!(new_data, key)
                any_deleted |= true
            end
        end
        return something(new_data, data), any_deleted
    end
end

# textDocument/diagnostic
# =======================

const DIAGNOSTIC_REGISTRATION_ID = "jetls-diagnostic"
const DIAGNOSTIC_REGISTRATION_METHOD = "textDocument/diagnostic"

function diagnostic_options()
    return DiagnosticOptions(;
        identifier = "JETLS/diagnostic",
        interFileDependencies = false,
        workspaceDiagnostics = true)
end

function diagnostic_registration()
    (; identifier, interFileDependencies, workspaceDiagnostics) = diagnostic_options()
    return Registration(;
        id = DIAGNOSTIC_REGISTRATION_ID,
        method = DIAGNOSTIC_REGISTRATION_METHOD,
        registerOptions = DiagnosticRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            identifier,
            interFileDependencies,
            workspaceDiagnostics)
    )
end

# # For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = DIAGNOSTIC_REGISTRATION_ID,
#     method = DIAGNOSTIC_REGISTRATION_METHOD))
# register(currently_running, diagnostic_registration())

function handle_DocumentDiagnosticRequest(
        server::Server, msg::DocumentDiagnosticRequest, cancel_flag::CancelFlag)
    uri = msg.params.textDocument.uri

    # This `previousResultId` calculation is mostly meaningless, but it might help the
    # client accurately update these diagnostics.
    # In particular, there seem to be cases where syntax error diagnostics remain in Zed
    # when this field is not set.
    previousResultid = msg.params.previousResultId
    if isnothing(previousResultid)
        resultId = "1"
    else
        resultId = @something tryparse(Int, previousResultid) begin
            return send(server,
                DocumentDiagnosticResponse(;
                    id = msg.id,
                    result = nothing,
                    error = request_failed_error("Invalid previousResultId given")))
        end
        resultId = string(resultId+1)
    end

    result = get_file_info(server.state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DocumentDiagnosticResponse(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(; resultId, items = Diagnostic[])))
    elseif result isa ResponseError
        return send(server, DocumentDiagnosticResponse(; id = msg.id, result = nothing, error = result))
    end
    file_info = result

    parsed_stream = file_info.parsed_stream
    if isempty(parsed_stream.diagnostics)
        diagnostics = toplevel_lowering_diagnostics(server, uri, file_info)
    else
        diagnostics = parsed_stream_to_diagnostics(file_info)
    end
    root_path = isdefined(server.state, :root_path) ? server.state.root_path : nothing
    apply_diagnostic_config!(diagnostics, server.state.config_manager, uri, root_path)
    notebook_uri = get_notebook_uri_for_cell(server.state, uri)
    if notebook_uri !== nothing
        diagnostics = map_cell_diagnostics(server.state, notebook_uri, uri, diagnostics)
    end
    return send(server,
        DocumentDiagnosticResponse(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(;
                resultId,
                items = diagnostics)))
end

# workspace/diagnostic
# ====================

function handle_WorkspaceDiagnosticRequest(
        server::Server, msg::WorkspaceDiagnosticRequest, cancel_flag::CancelFlag
    )
    uris_to_search = collect_workspace_uris(server)
    if get_config(server.state.config_manager, :diagnostic, :all_files)
        return send_workspace_diagnostics(server, msg, uris_to_search, cancel_flag)
    else
        return send_empty_workspace_diagnostics(server, msg, uris_to_search, cancel_flag)
    end
end

function send_workspace_diagnostics(
        server::Server, msg::WorkspaceDiagnosticRequest, uris_to_search::Set{URI},
        cancel_flag::CancelFlag
    )
    state = server.state
    previous_result_ids = Dict{URI,String}()
    for prev in msg.params.previousResultIds
        previous_result_ids[prev.uri] = prev.value
    end
    partial_token = msg.params.partialResultToken
    items = WorkspaceDocumentDiagnosticReport[]
    root_path = isdefined(state, :root_path) ? state.root_path : nothing
    debuginfo = nothing
    # debuginfo = (; synced = URI[], analyzed = URI[], skipped = URI[], failed = URI[])
    for uri in uris_to_search
        is_cancelled(cancel_flag) && return send(server,
            WorkspaceDiagnosticResponse(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))

        if is_synchronized(state, uri)
            isnothing(debuginfo) || push!(debuginfo.synced, uri)
            continue # should now be reported via `textDocument/diagnostic`
        end

        fi = @something get_unsynced_file_info!(state, uri) begin
            isnothing(debuginfo) || push!(debuginfo.failed, uri)
            continue
        end

        version = fi.version
        result_id = string(version)
        prev_result_id = get(previous_result_ids, uri, nothing)
        if prev_result_id !== nothing && prev_result_id == result_id
            item = WorkspaceUnchangedDocumentDiagnosticReport(;
                uri,
                version = null,
                resultId = result_id)
            if partial_token !== nothing
                send_partial_result(server, partial_token,
                    WorkspaceDiagnosticReportPartialResult(; items = WorkspaceDocumentDiagnosticReport[item]))
            else
                push!(items, item)
            end
            isnothing(debuginfo) || push!(debuginfo.skipped, uri)
            continue
        end

        if isempty(fi.parsed_stream.diagnostics)
            diagnostics = toplevel_lowering_diagnostics(server, uri, fi)
        else
            diagnostics = parsed_stream_to_diagnostics(fi)
        end
        apply_diagnostic_config!(diagnostics, state.config_manager, uri, root_path)
        notebook_uri = get_notebook_uri_for_cell(state, uri)
        if notebook_uri !== nothing
            diagnostics = map_cell_diagnostics(state, notebook_uri, uri, diagnostics)
        end

        item = WorkspaceFullDocumentDiagnosticReport(;
            uri,
            version = null,
            resultId = result_id,
            items = diagnostics)
        if partial_token !== nothing
            send_partial_result(server, partial_token,
                WorkspaceDiagnosticReportPartialResult(; items = WorkspaceDocumentDiagnosticReport[item]))
        else
            push!(items, item)
        end
        isnothing(debuginfo) || push!(debuginfo.analyzed, uri)
    end

    partial_token === nothing ||
        @assert isempty(items) "The final result should be empty when using partial token"
    if !isnothing(debuginfo)
        debugshow = (x) -> Text(sprint(show, MIME("text/plain"), x; context=:limit=>true))
        @info "workspace/diagnostic" analyzed=debugshow(debuginfo.analyzed) synced=debugshow(debuginfo.synced) skipped=debugshow(debuginfo.skipped) failed=debugshow(debuginfo.failed)
    end
    return send(server,
        WorkspaceDiagnosticResponse(;
            id = msg.id,
            result = WorkspaceDiagnosticReport(; items)))
end

const ALL_FILES_DISABLED_RESULT_ID = "workspace/diagnostic-disabled"
const empty_diagnostics = Diagnostic[]

function send_empty_workspace_diagnostics(
        server::Server, msg::WorkspaceDiagnosticRequest, uris_to_search::Set{URI},
        cancel_flag::CancelFlag
    )
    partial_token = msg.params.partialResultToken
    items = WorkspaceDocumentDiagnosticReport[]
    for uri in uris_to_search
        is_cancelled(cancel_flag) && return send(server,
            WorkspaceDiagnosticResponse(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
        is_synchronized(server.state, uri) && continue
        item = WorkspaceFullDocumentDiagnosticReport(;
            uri,
            version = null,
            resultId = ALL_FILES_DISABLED_RESULT_ID,
            items = empty_diagnostics)
        if partial_token !== nothing
            send_partial_result(server, partial_token,
                WorkspaceDiagnosticReportPartialResult(; items = WorkspaceDocumentDiagnosticReport[item]))
        else
            push!(items, item)
        end
    end
    partial_token === nothing ||
        @assert isempty(items) "The final result should be empty when using partial token"
    return send(server,
        WorkspaceDiagnosticResponse(;
            id = msg.id,
            result = WorkspaceDiagnosticReport(; items)))
end

# workspace/diagnostic/refresh
# ============================

struct DiagnosticRefreshRequestCaller <: RequestCaller end

# This function is currently used to refresh `textDocument/diagnostic`.
# The LSP specification states that clients receiving `workspace/diagnostic/refresh`
# should refresh both document and workspace diagnostics, but client implementations
# vary. As of now (2025-12-19), VSCode refreshes `textDocument/diagnostic` when it
# receives `workspace/diagnostic/refresh`, but Zed handles this request without
# refreshing `textDocument/diagnostic`.
function request_diagnostic_refresh!(server::Server)
    id = String(gensym(:WorkspaceDiagnosticRefreshRequest))
    addrequest!(server, id=>DiagnosticRefreshRequestCaller())
    return send(server, WorkspaceDiagnosticRefreshRequest(; id))
end

function handle_diagnostic_refresh_response(
        server::Server, msg::Dict{Symbol,Any}, ::DiagnosticRefreshRequestCaller
    )
    if handle_response_error(server, msg, "refresh diagnostics")
    else
        # just valid request response cycle
    end
end
