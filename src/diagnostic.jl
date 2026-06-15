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
        if key::String ∉ ("pattern", "match_by", "match_type", "severity", "path")
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
    local specificity::UInt8
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
            @warn "Diagnostic code must be a string" code code_type = typeof(code)
        elseif JETLS_TEST_MODE
            error(lazy"Diagnostic code must be a string, got $(typeof(code)): $code")
        end
        return diagnostic
    elseif code ∉ ALL_DIAGNOSTIC_CODES
        if JETLS_DEV_MODE
            @warn "Diagnostic code is not registered" code
        elseif JETLS_TEST_MODE
            error(lazy"Diagnostic code is not registered: $code")
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
    severity = nothing
    best_specificity = 0
    for pattern_config in patterns
        globpath = pattern_config.path
        if globpath !== nothing && !occursin(globpath, path_for_glob)
            continue
        end
        target = pattern_config.match_by == "message" ? get_raw_message(diagnostic) : code
        is_message_match = pattern_config.match_by == "message"
        specificity = calculate_match_specificity(
            pattern_config.pattern, target, is_message_match)
        if specificity != 0 && specificity >= best_specificity
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

function apply_markdown_message!(diagnostics::Vector{Diagnostic})
    for i = 1:length(diagnostics)
        diagnostic = diagnostics[i]
        if diagnostic.message isa String
            diagnostics[i] = Diagnostic(diagnostic; message = MarkupContent(; kind = MarkupKind.Markdown, value = diagnostic.message))
        end
    end
end

# utilities
# =========

# TODO Move this logic to `filename2uri`?
function to_valid_uri(filename::AbstractString)
    if isunsavedfile(filename)
        return filename2uri(filename)
    else
        return filepath2uri(to_full_path(filename))
    end
end

function jet_frame_to_location(frame)
    frame.file === :none && return nothing
    return Location(;
        uri = something(jet_frame_to_uri(frame)),
        range = jet_frame_to_range(frame))
end

function jet_frame_to_uri(frame)
    frame.file === :none && return nothing
    return to_valid_uri(String(frame.file))
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

get_raw_message(diagnostic::Diagnostic) = diagnostic.message isa String ? diagnostic.message : diagnostic.message.value

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

function jet_result_to_diagnostics!(
        uri2diagnostics::URI2Diagnostics, result::JET.JETToplevelResult,
        world::UInt, postprocessor::JET.PostProcessor
    )
    for report in result.res.toplevel_error_reports
        if report isa JET.LoweringErrorReport || report isa JET.MacroExpansionErrorReport
            # the equivalent report should have been reported by `per_stmt_diagnostics!`
            # with more precise location information
            continue
        end
        diagnostic = @something jet_toplevel_error_report_to_diagnostic(report, postprocessor) continue
        filename = report.file
        filename === :none && continue
        uri = to_valid_uri(filename)
        push!(uri2diagnostics[uri], diagnostic)
    end
    displayable_reports = collect_displayable_reports(result.res.inference_error_reports, keys(uri2diagnostics))
    jet_inference_error_reports_to_diagnostics!(uri2diagnostics, displayable_reports, world, postprocessor)
    return uri2diagnostics
end

# toplevel diagnostic
# -------------------

function jet_toplevel_error_report_to_diagnostic(
        @nospecialize(report::JET.ToplevelErrorReport), postprocessor::JET.PostProcessor
    )
    report isa JET.ParseErrorReport && return nothing # Syntax errors should be reported via `textDocument/diagnostic` or `workspace/diangostic`
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
        world::UInt, postprocessor::JET.PostProcessor
    )
    for report in reports
        diagnostic = jet_inference_error_report_to_diagnostic(report, world, postprocessor)
        topframeidx = first(inference_error_report_stack(report))
        topframe = report.vst[topframeidx]
        topframe.file === :none && continue # TODO Figure out why this is necessary
        uri = jet_frame_to_uri(topframe)
        push!(uri2diagnostics[uri], diagnostic) # collect_displayable_reports asserts that this `uri` key exists for `uri2diagnostics`
    end
    return uri2diagnostics
end

function jet_inference_error_report_to_diagnostic(
        @nospecialize(report::JET.InferenceErrorReport),
        world::UInt, postprocessor::JET.PostProcessor
    )
    rstack = inference_error_report_stack(report)
    topframe = report.vst[first(rstack)]
    message = JET.with_bufferring(:limit=>true) do io
        Base.invoke_in_world(world, JET.print_report_message, io, report)
    end |> postprocessor
    relatedInformation = DiagnosticRelatedInformation[]
    for i = 2:length(rstack)
        frame = report.vst[rstack[i]]
        location = @something jet_frame_to_location(frame) continue
        local message = postprocessor(Base.invoke_in_world(world,
            sprint, JET.print_frame_sig, frame, JET.PrintConfig())::String)
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
    elseif report isa MethodErrorReport
        return INFERENCE_METHOD_ERROR_CODE
    elseif report isa NonBooleanCondErrorReport
        return INFERENCE_NON_BOOLEAN_COND_CODE
    end
    error(lazy"No diagnostic code is defined for report: $report")
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

toplevel_warning_report_to_uri_impl(report::MethodOverwriteReport) = to_valid_uri(report.filepath)

function toplevel_warning_report_to_diagnostic_impl(report::MethodOverwriteReport, ::SavedFileInfo, postprocessor::JET.PostProcessor)
    sig_str = postprocessor(@invokelatest sprint(Base.show_tuple_as_call, Symbol(""), report.sig))
    mod_str = postprocessor(sprint(show, report.mod))
    message = "Method definition $sig_str in module $mod_str overwritten"
    relatedInformation = DiagnosticRelatedInformation[
        DiagnosticRelatedInformation(;
            location = Location(;
                uri = to_valid_uri(report.original_filepath),
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

toplevel_warning_report_to_uri_impl(report::AbstractFieldReport) = to_valid_uri(report.filepath)

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

const JL_MACRO_FILE = only(methods(JL.expand_macro, (JL.MacroExpansionContext,SyntaxTreeC,SyntaxListC))).file
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
        uri = to_valid_uri(String(stackframe.file))
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

function emit_macro_diagnostics!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, macro_diags::Vector{MacroDiagnostic}
    )
    isempty(macro_diags) && return diagnostics
    for d in macro_diags
        push!(diagnostics, Diagnostic(;
            range = jsobj_to_range(d.node, fi),
            severity = d.severity,
            message = d.msg,
            source = DIAGNOSTIC_SOURCE_LIVE,
            code = d.code,
            codeDescription = diagnostic_code_description(d.code),
            tags = d.code == LOWERING_INACTIVE_CODE ?
                DiagnosticTag.Ty[DiagnosticTag.Unnecessary] : nothing))
    end
    return diagnostics
end

# TODO Use actual file cache (with proper character encoding)
function provenances_to_related_information!(relatedInformation::Vector{DiagnosticRelatedInformation}, provs, msg)
    for prov in provs
        filename = JS.filename(prov)
        uri = to_valid_uri(filename)
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

# Compute a mapping from source locations to the set of identifier names found in keyword
# argument type annotations.
# `K"kw"` nodes are produced by JuliaSyntax for both true keyword arguments
# (`f(; y=1)`) and positional arguments with default values (`f(y=1)`); only the former
# sit under a `K"parameters"` node, so we track that during the walk.
# An explicit stack is used (instead of recursion) so we don't risk overflowing
# the C stack on pathologically deep user input.
function compute_kwarg_type_annotation_names(st0::SyntaxTreeC)
    type_names = Dict{Tuple{Int,Int},Set{String}}()
    locations = Set{Tuple{Int,Int}}()
    stack = Tuple{SyntaxTreeC,Bool}[(st0, false)]
    while !isempty(stack)
        (node, in_parameters) = pop!(stack)
        k = JS.kind(node)
        if k === JS.K"kw" && in_parameters
            JS.numchildren(node) >= 1 || continue
            child = node[1]
            push!(locations, JS.source_location(child))
            if JS.kind(child) === JS.K"::" && JS.numchildren(child) >= 2
                names = Set{String}()
                collect_identifier_names!(names, child[2])
                isempty(names) || (type_names[JS.source_location(child)] = names)
            end
            continue
        end
        next_in_parameters = k === JS.K"parameters"
        for i = JS.numchildren(node):-1:1
            push!(stack, (node[i], next_in_parameters))
        end
    end
    return type_names, locations
end

# Check if a keyword argument's type annotation constrains a `where`-clause static parameter
# that is actually used in the function body.
# For example, in `f(; dtype::Type{T}=Float32) where {T} = T.(xs)`, `dtype` is not directly
# used in the body but it constrains `T` which is used, so `dtype` should not be reported.
# NOTE: This exception is only for keyword arguments. Positional arguments can be replaced with
# `_::Type{T}` or `::Type{T}` to suppress the unused warning.
function is_kwarg_constraining_used_sparam(
        kwarg_type_names::Dict{Tuple{Int,Int},Set{String}},
        prov_loc::Tuple{Int,Int},
        ctx3::JL.VariableAnalysisContext
    )
    names = @something get(kwarg_type_names, prov_loc, nothing) return false
    for binfo in ctx3.bindings.info
        binfo.kind === :static_parameter || continue
        binfo.is_read || continue
        binfo.name in names && return true
    end
    return false
end

function has_matching_argument_binding(
        binding_occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        name::String, range::Range, fi::FileInfo, ctx3::JL.VariableAnalysisContext
    )
    for (binfo2, _) in binding_occurrences
        binfo2.kind === :argument || continue
        binfo2.name == name || continue
        provs2 = JS.flattened_provenance(JL.binding_ex(ctx3, binfo2.id))
        is_from_user_ast(provs2) || continue
        jsobj_to_range(last(provs2), fi) == range && return true
    end
    return false
end

function is_assignment_expression(st::SyntaxTreeC)
    k = JS.kind(st)
    k === JS.K"=" && return true
    if k === JS.K"unknown_head"
        name = get_name_val(st)
        return name !== nothing && endswith(name, "=")
    end
    return false
end

same_syntax_range(a::SyntaxTreeC, b::SyntaxTreeC) =
    JS.kind(a) === JS.kind(b) && JS.byte_range(a) == JS.byte_range(b)

function is_last_child(parent::SyntaxTreeC, child::SyntaxTreeC)
    n = JS.numchildren(parent)
    n == 0 && return false
    return same_syntax_range(parent[n], child)
end

function is_tail_branch_child(parent::SyntaxTreeC, child::SyntaxTreeC)
    for i in 2:JS.numchildren(parent)
        same_syntax_range(parent[i], child) && return true
    end
    return false
end

function assignment_expression_for_prov(st0::SyntaxTreeC, prov::SyntaxTreeC)
    assignments = byte_ancestors(is_assignment_expression, st0, JS.byte_range(prov))
    isempty(assignments) && return nothing
    return first(assignments)
end

function tail_returned_assignment_kind(
        st0::SyntaxTreeC, assignment::Union{Nothing,SyntaxTreeC}
    )
    isnothing(assignment) && return :none
    ancestors = byte_ancestors(st0, JS.byte_range(assignment))
    simple = true
    for i in 1:length(ancestors)-1
        child = ancestors[i]
        parent = ancestors[i+1]
        pk = JS.kind(parent)
        if pk === JS.K"return"
            return :tail
        elseif pk === JS.K"block"
            is_last_child(parent, child) || return :none
        elseif pk === JS.K"function"
            is_last_child(parent, child) || return :none
            return simple ? :simple : :tail
        elseif pk === JS.K"if" || pk === JS.K"elseif" || pk === JS.K"?"
            is_tail_branch_child(parent, child) || return :none
            simple = false
        else
            return :none
        end
    end
    return :none
end

function unused_local_binding_message(bn::String, tail_kind::Symbol)
    if tail_kind !== :none
        return "Local binding `$bn` is not read; consider `return $bn` to return it explicitly"
    end
    return "Unused local binding `$bn`"
end

function unused_assignment_message(bn::String, tail_kind::Symbol)
    if tail_kind !== :none
        return "Value assigned to `$bn` is returned implicitly; consider `return $bn` to return the binding explicitly"
    end
    return "Value assigned to `$bn` is never used"
end

function return_insert_data(
        assignment::SyntaxTreeC, fi::FileInfo, bn::String, tail_kind::Symbol
    )
    tail_kind === :simple || return nothing, nothing
    range = jsobj_to_range(assignment, fi)
    indent = get_line_indent(fi, range.start.line)
    return range.var"end", "\n$(indent)return $bn"
end

# `JL.method_def_expr` packages each lowered method's signature metadata as
# `svec(svec(arg_types...), svec(static_parameters...), source_location)`, where the
# static parameters are the locals `JL.assign_sparams` binds via `core.TypeVar` calls.
# Matching that shape covers every method definition form — named, anonymous, callable
# struct, macro-generated — while quoted code stays inert and never produces it.
function method_signature_metadata(node::SyntaxTreeC)
    JS.numchildren(node) == 4 && is_core_svec_call(node) || return nothing
    arg_types = node[2]
    sparams = node[3]
    JS.kind(arg_types) === JS.K"call" && is_core_svec_call(arg_types) || return nothing
    JS.kind(sparams) === JS.K"call" && is_core_svec_call(sparams) || return nothing
    JS.kind(node[4]) === JS.K"SourceLocation" || return nothing
    return arg_types, sparams
end

function collect_binding_ids!(ids::Set{JL.IdTag}, st::SyntaxTreeC)
    traverse(st) do node::SyntaxTreeC
        JS.kind(node) === JS.K"BindingId" && push!(ids, JL._binding_id(node))
        return nothing
    end
    return ids
end

function analyze_unconstrained_static_parameters!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, ctx3::JL.VariableAnalysisContext,
        st3::SyntaxTreeC, reported::Set{LoweringDiagnosticKey}
    )
    typevar_assignments = Dict{JL.IdTag,SyntaxTreeC}()
    signature_metadatas = Tuple{SyntaxTreeC,SyntaxTreeC}[]
    traverse(st3) do node::SyntaxTreeC
        k = JS.kind(node)
        if k === JS.K"=" && JS.numchildren(node) == 2 &&
                JS.kind(node[1]) === JS.K"BindingId"
            rhs = node[2]
            if JS.kind(rhs) === JS.K"call" && JS.numchildren(rhs) >= 2 &&
                    is_core_ref(rhs[1], "TypeVar")
                typevar_assignments[JL._binding_id(node[1])] = rhs
            end
        elseif k === JS.K"call"
            metadata = method_signature_metadata(node)
            metadata === nothing || push!(signature_metadatas, metadata)
        end
        return nothing
    end
    for (arg_types, sparams) in signature_metadatas
        sparam_ids = JL.IdTag[]
        for i = 2:JS.numchildren(sparams)
            sparam = sparams[i]
            # non-`BindingId` entries are e.g. the placeholder in `where {T,_}`
            JS.kind(sparam) === JS.K"BindingId" || continue
            id = JL._binding_id(sparam)
            haskey(typevar_assignments, id) && push!(sparam_ids, id)
        end
        isempty(sparam_ids) && continue
        arg_type_ids = collect_binding_ids!(Set{JL.IdTag}(), arg_types)
        constrained = Bool[id in arg_type_ids for id in sparam_ids]
        # A constrained type variable's bounds also constrain the type variables they
        # reference, but only those declared earlier: in `f(::T) where {T<:S, S}` the
        # `S` bound of `T` resolves to the later declaration without constraining it
        # (mirroring `JL.select_used_typevars`)
        todo = findall(constrained)
        while !isempty(todo)
            i = pop!(todo)
            bound_ids = collect_binding_ids!(Set{JL.IdTag}(), typevar_assignments[sparam_ids[i]])
            for j = 1:i-1
                constrained[j] && continue
                sparam_ids[j] in bound_ids || continue
                constrained[j] = true
                push!(todo, j)
            end
        end
        for i = eachindex(sparam_ids)
            constrained[i] && continue
            binfo = JL.get_binding(ctx3, sparam_ids[i])
            binfo.is_internal && continue
            bn = binfo.name
            startswith(bn, "#") && continue
            provs = JS.flattened_provenance(JL.binding_ex(ctx3, binfo.id))
            is_from_user_ast(provs) || continue
            range = jsobj_to_range(last(provs), fi)
            key = LoweringDiagnosticKey(range, :static_parameter, bn)
            key in reported ? continue : push!(reported, key)
            push!(diagnostics, Diagnostic(;
                range,
                severity = DiagnosticSeverity.Warning,
                message = "Method definition declares type variable `$bn` but does not use it in the type of any function parameter",
                source = DIAGNOSTIC_SOURCE_LIVE,
                code = LOWERING_UNCONSTRAINED_STATIC_PARAMETER_CODE,
                codeDescription = diagnostic_code_description(
                    LOWERING_UNCONSTRAINED_STATIC_PARAMETER_CODE)))
        end
    end
    return diagnostics
end

function analyze_unused_bindings!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, st0::SyntaxTreeC, ctx3::JL.VariableAnalysisContext,
        binding_occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        has_implicit_args::Bool, reported::Set{LoweringDiagnosticKey},
        kwarg_type_names::Dict{Tuple{Int,Int},Set{String}},
        kwarg_locations::Set{Tuple{Int,Int}};
        allow_unused_underscore::Bool
    )
    for (binfo, occurrences) in binding_occurrences
        bk = binfo.kind
        bk === :global && continue
        if any(occurrence::BindingOccurrence->occurrence.kind===:use, occurrences)
            continue
        end
        bn = binfo.name
        if has_implicit_args && bn in _IMPLICIT_BINDING_NAMES
            continue
        end
        if allow_unused_underscore && startswith(bn, '_')
            continue
        end
        provs = JS.flattened_provenance(JL.binding_ex(ctx3, binfo.id))
        is_from_user_ast(provs) || continue
        prov = last(provs)
        is_argument = bk === :argument
        if is_argument
            prov_loc = JS.source_location(prov)
            if is_kwarg_constraining_used_sparam(kwarg_type_names, prov_loc, ctx3)
                continue
            end
        end
        range = jsobj_to_range(prov, fi)
        key = LoweringDiagnosticKey(range, bk, bn)
        key in reported ? continue : push!(reported, key)
        if bk === :local && has_matching_argument_binding(binding_occurrences, bn, range, fi, ctx3)
            # When `:argument` and `:local` bindings are merged at the same
            # location (keyword dependent defaults), only the `:argument`
            # diagnostic should be reported.
            continue
        end
        if is_argument
            message = "Unused argument `$bn`"
            code = LOWERING_UNUSED_ARGUMENT_CODE
            data = UnusedArgumentData(prov_loc in kwarg_locations)
        else
            assignment = assignment_expression_for_prov(st0, prov)
            tail_kind = tail_returned_assignment_kind(st0, assignment)
            message = unused_local_binding_message(bn, tail_kind)
            code = LOWERING_UNUSED_LOCAL_CODE
            data = assignment === nothing ? nothing :
                compute_unused_variable_data(assignment, fi, bn, tail_kind)
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

function analyze_unused_assignments!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, st0::SyntaxTreeC,
        dead_store_info::Dict{JL.BindingInfo, DeadStoreInfo},
        reported::Set{LoweringDiagnosticKey};
        allow_unused_underscore::Bool
    )
    for (binfo, dsinfo) in dead_store_info
        binfo.kind === :local || continue
        binfo.is_internal && continue
        startswith(binfo.name, '#') && continue
        bn = binfo.name
        if allow_unused_underscore && startswith(bn, '_')
            continue
        end
        for dead_def_tree in dsinfo.dead_defs
            provs = JL.flattened_provenance(dead_def_tree)
            is_from_user_ast(provs) || continue
            prov = last(provs)
            range = jsobj_to_range(prov, fi)
            key = LoweringDiagnosticKey(range, binfo.kind, bn)
            key in reported ? continue : push!(reported, key)
            assignment = assignment_expression_for_prov(st0, prov)
            tail_kind = tail_returned_assignment_kind(st0, assignment)
            push!(diagnostics, Diagnostic(;
                range,
                severity = DiagnosticSeverity.Information,
                message = unused_assignment_message(bn, tail_kind),
                source = DIAGNOSTIC_SOURCE_LIVE,
                code = LOWERING_UNUSED_ASSIGNMENT_CODE,
                codeDescription = diagnostic_code_description(
                    LOWERING_UNUSED_ASSIGNMENT_CODE),
                tags = DiagnosticTag.Ty[DiagnosticTag.Unnecessary],
                data = assignment === nothing ? nothing :
                    compute_unused_variable_data(assignment, fi, bn, tail_kind)))
        end
    end
end

const DefUsedNamesCacheData = Base.PersistentDict{UInt,Dict{Module,DefUsedNames}}
const DefUsedNamesCache = LWContainer{DefUsedNamesCacheData, LWStats}

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
# Per-file phase: collect undef-global candidates while `ctx3` is alive. Filters
# against `world`/`analyzer` here so the cached candidates need no link back to
# the lowering context. The cross-file phase consumes these via
# `emit_undef_global_diagnostics!` with a unit-wide def-name set.
function collect_undef_global_candidates!(
        candidates::Vector{UndefGlobalCandidate}, fi::FileInfo, ctx3::JL.VariableAnalysisContext,
        binding_occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        world::UInt, analyzer::Union{Nothing,LSAnalyzer}, postprocessor::LSPostProcessor,
        reported::Set{LoweringDiagnosticKey}
    )
    for (binfo, occurrences) in binding_occurrences
        bk = binfo.kind
        bk === :global || continue
        binfo.is_internal && continue
        startswith(binfo.name, '#') && continue
        any(o->o.kind===:def, occurrences) && continue
        bmod = binfo.mod
        isnothing(bmod) && continue
        Base.invoke_in_world(world, isdefinedglobal, bmod, Symbol(binfo.name))::Bool && continue
        if !isnothing(analyzer)
            bp = Base.lookup_binding_partition(world, GlobalRef(bmod, Symbol(binfo.name)))
            haskey(JET.AnalyzerState(analyzer).binding_states, bp) && continue
        end
        bn = binfo.name
        provs = JS.flattened_provenance(JL.binding_ex(ctx3, binfo.id))
        is_from_user_ast(provs) || continue
        range = jsobj_to_range(last(provs), fi)
        key = LoweringDiagnosticKey(range, bk, bn)
        key in reported ? continue : push!(reported, key)
        message = postprocessor("`$(bmod).$(bn)` is not defined")
        push!(candidates, UndefGlobalCandidate(bmod, bn, range, message))
    end
end

# Cross-file phase: emit a `Diagnostic` for each candidate whose name isn't defined
# elsewhere in the analysis unit. Pure Set lookup — no re-lowering.
function emit_undef_global_diagnostics!(
        diagnostics::Vector{Diagnostic}, candidates::Vector{UndefGlobalCandidate},
        mod_def_used_names::Dict{Module,DefUsedNames},
    )
    code = LOWERING_UNDEF_GLOBAL_VAR_CODE
    cdesc = diagnostic_code_description(code)
    for c in candidates
        def_used_names = get(mod_def_used_names, c.bmod, nothing)
        if def_used_names !== nothing && c.name in def_used_names.def
            continue
        end
        push!(diagnostics, Diagnostic(;
            range = c.range,
            severity = DiagnosticSeverity.Warning,
            message = c.message,
            source = DIAGNOSTIC_SOURCE_LIVE,
            code,
            codeDescription = cdesc))
    end
end

# This analysis reports `lowering/undef-local-var` on a change basis, based on
# `analyze_all_lambdas`, which analyzes local binding definedness with the event
# based binding assignment reachability analysis.
# Severity levels (encoded in each entry of `UndefInfo.undef_uses`):
# - Warning: `true => tree` → strict undef (guaranteed UndefVarError on some path)
# - Information: `false => tree` → maybe undef (possible UndefVarError)
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
        isempty(uinfo.undef_uses) && continue
        # Compute relatedInformation once per variable (shared across all undef uses)
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
        related = @somereal relatedInformation Some(nothing)
        for (is_strict_undef, undef_use_tree) in uinfo.undef_uses
            provs = JL.flattened_provenance(undef_use_tree)
            is_from_user_ast(provs) || continue
            range = jsobj_to_range(last(provs), fi)
            key = LoweringDiagnosticKey(range, binfo.kind, binfo.name)
            key in reported ? continue : push!(reported, key)
            push!(diagnostics, Diagnostic(;
                range,
                severity = is_strict_undef ?
                    DiagnosticSeverity.Warning :
                    DiagnosticSeverity.Information,
                message = is_strict_undef ?
                    "Variable `$(binfo.name)` is used before it is defined" :
                    "Variable `$(binfo.name)` may be used before it is defined",
                source = DIAGNOSTIC_SOURCE_LIVE,
                code = LOWERING_UNDEF_LOCAL_VAR_CODE,
                codeDescription = diagnostic_code_description(
                    LOWERING_UNDEF_LOCAL_VAR_CODE),
                relatedInformation = related))
        end
    end
end

function compute_unused_variable_data(
        assignment::SyntaxTreeC, fi::FileInfo, bn::String, tail_kind::Symbol
    )
    JS.numchildren(assignment) ≥ 2 || return nothing

    lhs = assignment[1]

    # Check for destructuring patterns (tuple unpacking)
    is_tuple = JS.kind(lhs) === JS.K"tuple"
    if is_tuple
        return UnusedVariableData(true, nothing, nothing, nothing, nothing)
    end

    # lhs_eq_range: from LHS start to actual RHS start in source (exclusive).
    # We scan forward from after the LHS to find the `=` sign and any
    # following whitespace.  This is needed because some node kinds (e.g.
    # K"String") have a byte range that excludes delimiters, so
    # `first_byte(rhs)` may point past the opening delimiter.
    assignment_range = jsobj_to_range(assignment, fi)
    lhs_eq_range = if JS.kind(assignment) === JS.K"="
        lhs_start = offset_to_xy(fi, JS.first_byte(lhs))
        textbuf = fi.parsed_stream.textbuf
        eq_byte = @something findnext(==(UInt8('=')), textbuf, JS.last_byte(lhs) + 1) return nothing
        rhs_byte = eq_byte + 1
        while rhs_byte ≤ length(textbuf) && textbuf[rhs_byte] in (UInt8(' '), UInt8('\t'))
            rhs_byte += 1
        end
        rhs_start = offset_to_xy(fi, rhs_byte)
        Range(; start=lhs_start, var"end"=rhs_start)
    else
        nothing
    end
    return_insert_position, return_insert_text = return_insert_data(
        assignment, fi, bn, tail_kind)
    return UnusedVariableData(
        false, assignment_range, lhs_eq_range, return_insert_position, return_insert_text)
end

function analyze_captured_boxes!(
        diagnostics::Vector{Diagnostic}, uri::URI, fi::FileInfo,
        ctx4::JL.ClosureConversionCtx, st3::SyntaxTreeC,
        reported::Set{LoweringDiagnosticKey}
    )
    for binfo in ctx4.bindings.info
        JL.is_boxed(binfo) || continue
        binfo.is_internal && continue
        startswith(binfo.name, '#') && continue
        is_captured_binding(binfo, ctx4) || continue
        bn = binfo.name
        provs = JL.flattened_provenance(JL.binding_ex(ctx4, binfo.id))
        is_from_user_ast(provs) || continue
        range = jsobj_to_range(last(provs), fi)
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

# Normally JuliaLowering only applies binding analysis to variables that are actually captured,
# but currently there are some edge cases where incorrect bindings are introduced, resulting
# in false positive captured boxes being reported.
# This check is basically a band-aid, and the fundamental issue should be resolved on the
# JuliaLowering side.
function is_captured_binding(binfo::JL.BindingInfo, ctx4::JL.ClosureConversionCtx)
    for (_, closure_bindings) in ctx4.closure_bindings
        for lambda in closure_bindings.lambdas
            haskey(lambda.locals_capt, binfo.id) && return true
        end
    end
    return false
end

function find_capture_sites(
        st3::SyntaxTreeC, binfo::JL.BindingInfo, ctx4::JL.ClosureConversionCtx,
        uri::URI, fi::FileInfo
    )
    relatedInformation = DiagnosticRelatedInformation[]
    for (_, closure_bindings) in ctx4.closure_bindings
        for lambda in closure_bindings.lambdas
            haskey(lambda.locals_capt, binfo.id) || continue
            lambda.locals_capt[binfo.id] || continue
            # Find the lambda in st3 that has matching lambda_bindings.self
            traverse(st3) do node3::SyntaxTreeC
                JS.kind(node3) === JS.K"lambda" || return nothing
                hasproperty(node3, :lambda_bindings) || return nothing
                lambda_bindings = node3.lambda_bindings::JL.LambdaBindings
                lambda_bindings.self == lambda.self || return nothing
                # Find references to binfo.id inside this lambda
                traverse(node3) do inner::SyntaxTreeC
                    if JS.kind(inner) === JS.K"BindingId" && JL._binding_id(inner) == binfo.id
                        varprov = last(JL.flattened_provenance(inner))
                        push!(relatedInformation, DiagnosticRelatedInformation(;
                            location = Location(; uri, range = jsobj_to_range(varprov, fi)),
                            message = "Captured by closure"))
                    end
                end
                return traversal_no_recurse
            end
        end
    end
    return @somereal relatedInformation Some(nothing)
end

function analyze_ambiguous_soft_scope!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, ctx3::JL.VariableAnalysisContext,
        reported::Set{LoweringDiagnosticKey}
    )
    for binfo in ctx3.bindings.info
        binfo.is_ambiguous_local || continue
        binfo.is_internal && continue
        bn = binfo.name
        startswith(bn, '#') && continue
        provs = JS.flattened_provenance(JL.binding_ex(ctx3, binfo.id))
        is_from_user_ast(provs) || continue
        prov = last(provs)
        range = jsobj_to_range(prov, fi)
        key = LoweringDiagnosticKey(range, :ambiguous, bn)
        key in reported ? continue : push!(reported, key)
        indent = get_line_indent(fi, range.start.line)
        push!(diagnostics, Diagnostic(;
            range,
            severity = DiagnosticSeverity.Warning,
            message = "Assignment to `$bn` in soft scope is ambiguous " *
                      "because a global variable by the same name exists: " *
                      "`$bn` will be treated as a new local. " *
                      "Disambiguate by using `local $bn` to suppress this " *
                      "warning or `global $bn` to assign to the existing " *
                      "global variable.",
            source = DIAGNOSTIC_SOURCE_LIVE,
            code = LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE,
            codeDescription = diagnostic_code_description(LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE),
            data = AmbiguousSoftScopeData(bn, indent)))
    end
end

const SORT_IMPORTS_MAX_LINE_LENGTH = 92
const SORT_IMPORTS_INDENT = "    "

function analyze_unsorted_imports!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, st0::SyntaxTreeC
    )
    traverse(st0) do st0′::SyntaxTreeC
        kind = JS.kind(st0′)
        if kind ∉ JS.KSet"import using export public"
            return nothing
        end
        name_keys = collect_import_names(st0′)
        if !issorted(name_keys; by=last)
            range = jsobj_to_range(st0′, fi)
            sorted_name_keys = sort!(name_keys; by=last)
            base_indent = get_line_indent(fi, range.start.line)
            new_text = generate_sorted_import_text(st0′, sorted_name_keys, base_indent)
            push!(diagnostics, Diagnostic(;
                range,
                severity = DiagnosticSeverity.Hint,
                message = "Names are not sorted alphabetically",
                source = DIAGNOSTIC_SOURCE_LIVE,
                code = LOWERING_UNSORTED_IMPORT_NAMES_CODE,
                codeDescription = diagnostic_code_description(LOWERING_UNSORTED_IMPORT_NAMES_CODE),
                data = UnsortedImportData(new_text)))
        end
        return traversal_no_recurse
    end
    return diagnostics
end

function generate_sorted_import_text(
        node::SyntaxTreeC, sorted_name_keys::Vector{Pair{SyntaxTreeC,String}},
        base_indent::String
    )
    kind = JS.kind(node)
    keyword = kind === JS.K"import" ? "import" :
              kind === JS.K"using" ? "using" :
              kind === JS.K"export" ? "export" : "public"
    if kind in JS.KSet"import using"
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
    name_texts = String[lstrip(JS.sourcetext(n)) for (n,_) in sorted_name_keys]
    single_line = prefix * join(name_texts, ", ")
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

# Reachability-based unreachable-code detection. `unreachable_statements`
# is the set of `K"block"` children that the per-lambda CFG built in
# `analyze_all_lambdas` determined to be in unreachable blocks.
#
# Walking `K"block"` nodes here only serves to (a) locate consecutive runs
# of unreachable statements that came from the same source position and
# (b) recover the "transition point" — the last reachable sibling — to
# anchor the auto-fix delete range. The reachability decision itself is
# entirely the CFG's, which means cases like
# `return f(@goto label); @label label; ...` are correctly recognized as
# reachable via the goto edge.
function analyze_unreachable_code!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, st3::SyntaxTreeC,
        unreachable_statements::Set{SyntaxTreeC}
    )
    isempty(unreachable_statements) && return
    traverse(st3) do st3′::SyntaxTreeC
        JS.kind(st3′) === JS.K"block" || return nothing
        nchildren = JS.numchildren(st3′)
        first_unreach_idx = 0
        for i in 1:nchildren
            if st3′[i] in unreachable_statements
                first_unreach_idx = i
                break
            end
        end
        first_unreach_idx == 0 && return nothing
        # When the entire block is unreachable from its first child, the block itself is
        # unreachable in the parent's iteration; let the parent handle the report so we do
        # not double-count.
        first_unreach_idx == 1 && return nothing
        terminator = st3′[first_unreach_idx - 1]
        terminator_end = last(JS.byte_range(terminator))

        first_range = last_range = nothing
        for j in first_unreach_idx:nchildren
            child = st3′[j]
            # `break` (not `continue`): a reachable sibling marks the end of the unreachable
            # run; subsequent unreachable runs in the same block are intentionally not
            # folded into this diagnostic's range.
            child in unreachable_statements || break
            # `continue` (not `break`): filter out lowering-introduced sibling statements
            # whose source position is not strictly after the terminator (e.g. a loop's
            # iterate-step assignment whose source provenance points back to the loop
            # header, or a macro-introduced wrapper whose range encompasses the user-written
            # terminator-bearing argument), but keep iterating — genuine user-visible
            # unreachable code may still follow the artifact.
            first(JS.byte_range(child)) > terminator_end || continue
            provs = JL.flattened_provenance(child)
            is_from_user_ast(provs) || continue
            range = jsobj_to_range(last(provs), fi)
            if isnothing(first_range)
                first_range = range
            end
            last_range = range
        end
        if !isnothing(first_range) && !isnothing(last_range)
            merged_range = Range(;
                start = first_range.start,
                var"end" = last_range.var"end")
            terminator_lsp_range = jsobj_to_range(terminator, fi)
            delete_range = Range(;
                start = terminator_lsp_range.var"end",
                var"end" = last_range.var"end")
            push!(diagnostics, Diagnostic(;
                range = merged_range,
                severity = DiagnosticSeverity.Information,
                message = "Unreachable code",
                source = DIAGNOSTIC_SOURCE_LIVE,
                code = LOWERING_UNREACHABLE_CODE,
                codeDescription = diagnostic_code_description(LOWERING_UNREACHABLE_CODE),
                tags = DiagnosticTag.Ty[DiagnosticTag.Unnecessary],
                data = DeleteRangeData(:unreachable_code, delete_range)))
        end
        return nothing
    end
end

# `@goto`/`@label` resolution is normally validated by JuliaLowering's
# `compile_body` (linear IR pass), which JETLS doesn't run. Mirror that
# check against `st3` so unresolved gotos still surface as diagnostics.
function analyze_unresolved_gotos!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, st3::SyntaxTreeC
    )
    traverse(st3) do st3′::SyntaxTreeC
        JS.kind(st3′) === JS.K"lambda" || return nothing
        JS.numchildren(st3′) >= 3 || return nothing
        check_lambda_gotos!(diagnostics, fi, st3′[3])
        return nothing
    end
end

function check_lambda_gotos!(
        diagnostics::Vector{Diagnostic}, fi::FileInfo, body3::SyntaxTreeC
    )
    gotos, labels = collect_gotos_labels(body3)
    label_names = Set{String}(name for (name, _) in labels)
    referenced = Set{String}()
    for (name, st) in gotos
        if name in label_names
            push!(referenced, name)
            continue
        end
        push!(diagnostics, Diagnostic(;
            range = jsobj_to_range(st, fi),
            severity = DiagnosticSeverity.Error,
            message = "label `$name` referenced but not defined",
            source = DIAGNOSTIC_SOURCE_LIVE,
            code = LOWERING_ERROR_CODE,
            codeDescription = diagnostic_code_description(LOWERING_ERROR_CODE)))
    end
    for (name, st) in labels
        name in referenced && continue
        # Skip macro-generated labels — only report user-written ones.
        provs = JL.flattened_provenance(st)
        is_from_user_ast(provs) || continue
        # The provenance chain ends with the label-name identifier; the
        # entry immediately above it (`provs[end-1]`) is the user-written
        # `@label name` macrocall, which is what we want to delete.
        # Using `first(provs)` would instead pick the outermost source —
        # and for a `@label` nested inside another macrocall (e.g.
        # `@testset begin; @label foo; end`) that is the entire enclosing
        # macrocall, not the `@label` line.
        delete_obj = length(provs) >= 2 ? provs[end-1] : first(provs)
        delete_range = line_absorbing_delete_range(delete_obj, fi)
        push!(diagnostics, Diagnostic(;
            range = jsobj_to_range(st, fi),
            severity = DiagnosticSeverity.Information,
            message = "Unused label `$name`",
            source = DIAGNOSTIC_SOURCE_LIVE,
            code = LOWERING_UNUSED_LABEL_CODE,
            codeDescription = diagnostic_code_description(LOWERING_UNUSED_LABEL_CODE),
            tags = DiagnosticTag.Ty[DiagnosticTag.Unnecessary],
            data = DeleteRangeData(:unused_label, delete_range)))
    end
end

function collect_gotos_labels(st3::SyntaxTreeC)
    gotos = Tuple{String,SyntaxTreeC}[]
    labels = Tuple{String,SyntaxTreeC}[]
    collect_gotos_labels!(gotos, labels, st3)
    return gotos, labels
end
function collect_gotos_labels!(
        gotos::Vector{Tuple{String,SyntaxTreeC}}, labels::Vector{Tuple{String,SyntaxTreeC}},
        st3::SyntaxTreeC
    )
    traverse(st3) do node
        k = JS.kind(node)
        if k === JS.K"lambda"
            # Nested lambdas have their own goto/label scope; handled separately.
            return traversal_no_recurse
        elseif k === JS.K"symboliclabel"
            push!(labels, (name_val(node), node))
            return traversal_no_recurse
        elseif k === JS.K"symbolicgoto" || k === JS.K"oldsymbolicgoto"
            push!(gotos, (name_val(node), node))
            return traversal_no_recurse
        elseif k === JS.K"symbolicblock" || k === JS.K"break"
            # `K"symbolicblock"`'s first child is a lowering-internal label
            # (e.g. `loop-exit`) used by `K"break"`, not reachable via `@goto`;
            # `K"break"`'s first child is a label name reference, not a declaration.
            # In both cases recurse only into the body (the second child).
            if JS.numchildren(node) >= 2
                collect_gotos_labels!(gotos, labels, node[2])
            end
            return traversal_no_recurse
        end
        return
    end
    return
end

function analyze_lowered_code!(
        diagnostics::Vector{Diagnostic}, candidates::Vector{UndefGlobalCandidate},
        uri::URI, fi::FileInfo, res::NamedTuple, world::UInt,
        analyzer::Union{Nothing,LSAnalyzer}, postprocessor::LSPostProcessor;
        skip_analysis_requiring_context::Bool = false,
        allow_unused_underscore::Bool = true,
        allow_noreturn_optimization::Vector{Symbol} = Symbol[]
    )
    (; ctx3, ctx4, st0, st3) = res
    binding_occurrences = compute_binding_occurrences(ctx3, st3;
        include_global_bindings=true)

    reported = Set{LoweringDiagnosticKey}() # to prevent duplicate reports for unused default or keyword arguments
    (kwarg_type_names, kwarg_locations) = compute_kwarg_type_annotation_names(st0)

    analyze_unconstrained_static_parameters!(diagnostics, fi, ctx3, st3, reported)

    has_implicit_args = is_macro0(st0) || is_generated0(st0)
    analyze_unused_bindings!(
        diagnostics, fi, st0, ctx3, binding_occurrences, has_implicit_args, reported,
        kwarg_type_names, kwarg_locations;
        allow_unused_underscore)

    (; undef_info, dead_store_info, unreachable_statements) =
        analyze_all_lambdas(ctx3, st3; allow_noreturn_optimization)
    analyze_undefined_local_bindings!(diagnostics, uri, fi, undef_info, reported)
    analyze_unused_assignments!(diagnostics, fi, st0, dead_store_info, reported; allow_unused_underscore)

    analyze_captured_boxes!(diagnostics, uri, fi, ctx4, st3, reported)
    analyze_unreachable_code!(diagnostics, fi, st3, unreachable_statements)
    analyze_unresolved_gotos!(diagnostics, fi, st3)

    if !skip_analysis_requiring_context
        collect_undef_global_candidates!(candidates, fi, ctx3, binding_occurrences,
            world, analyzer, postprocessor, reported)
        analyze_ambiguous_soft_scope!(diagnostics, fi, ctx3, reported)
    end

    return diagnostics
end

function per_stmt_diagnostics!(
        diagnostics::Vector{Diagnostic}, candidates::Vector{UndefGlobalCandidate},
        uri::URI, fi::FileInfo, st0::SyntaxTreeC, context_module::Module, world::UInt,
        analyzer::Union{Nothing,LSAnalyzer}, postprocessor::LSPostProcessor;
        skip_analysis_requiring_context::Bool = false,
        allow_unused_underscore::Bool = true,
        soft_scope::Bool = false
    )
    @assert JS.kind(st0) ∉ JS.KSet"toplevel module"

    analyze_unsorted_imports!(diagnostics, fi, st0)

    (st0, _) = desugar_main_macrocall(st0)
    macro_diags = MacroDiagnostic[]
    res = Base.ScopedValues.@with MACRO_DIAGNOSTIC_SINK => macro_diags try
        jl_lower_for_scope_resolution(context_module, st0; world,
            recover_from_macro_errors=false, convert_closures=true, soft_scope)
    catch err
        if err isa JL.LoweringError
            if !err.internal
                for (st, msg) in zip(err.sts, err.msgs)
                    push!(diagnostics, Diagnostic(;
                        range = jsobj_to_range(st, fi),
                        severity = DiagnosticSeverity.Error,
                        message = msg,
                        source = DIAGNOSTIC_SOURCE_LIVE,
                        code = LOWERING_ERROR_CODE,
                        codeDescription = diagnostic_code_description(LOWERING_ERROR_CODE)))
                end
            end
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
        nothing # signal primary-attempt failure to the fallback path
    end
    emit_macro_diagnostics!(diagnostics, fi, macro_diags)

    if res === nothing
        # Fallback expansion runs *outside* the sink scope: `remove_macrocalls`
        # only strips old-style macrocalls, so any new-style stub that reported via
        # the sink during the primary attempt would push the same entry again here
        # — emitting twice. With the sink unbound, those `push_macro_*!` calls
        # become no-ops, and stubs that genuinely throw simply re-throw and we bail.
        st0 = remove_macrocalls(st0)
        res = try
            jl_lower_for_scope_resolution(context_module, st0; world,
                recover_from_macro_errors=false, convert_closures=true, soft_scope)
        catch
            return diagnostics
        end
    end

    allow_noreturn_optimization = Symbol[]
    noreturn_globals = (
        (:throw, Core.throw),
        (:error, Base.error),
        (:rethrow, Base.rethrow),
        (:exit,  Base.exit),
    )
    for (name, expected) in noreturn_globals
        if (Base.invoke_in_world(world, isdefinedglobal, context_module, name)::Bool &&
            Base.invoke_in_world(world, getglobal, context_module, name) === expected)
            push!(allow_noreturn_optimization, name)
        end
    end

    return analyze_lowered_code!(
        diagnostics, candidates, uri, fi, res, world, analyzer, postprocessor;
        skip_analysis_requiring_context, allow_unused_underscore, allow_noreturn_optimization)
end

function compute_unit_def_used_names(
        server::Server, search_uris::Set{URI};
        skip_context_check::Bool = false # used by tests only
    )
    state = server.state
    mod_def_used_names = Dict{Module,DefUsedNames}()
    for search_uri in search_uris
        skip_context_check || has_analyzed_context(state, search_uri) || continue
        search_fi = @something begin
            get_file_info(state, search_uri)
        end begin
            get_unsynced_file_info!(state, search_uri)
        end continue
        cached = get(load(state.per_file_diagnostics_cache),
            canonical_cache_uri(state, search_uri), nothing)
        if cached !== nothing
            merge_def_used_names!(mod_def_used_names, cached.def_used_names)
            continue
        end
        search_st0_top = build_syntax_tree(search_fi)

        iterate_toplevel_tree(search_st0_top) do st0::SyntaxTreeC
            binding_occurrences = @something get_binding_occurrences!(
                state, search_uri, search_fi, st0) return
            context_module = get_context_module(state, search_uri, offset_to_xy(search_fi, JS.first_byte(st0)))
            update_def_used_names!(mod_def_used_names, context_module, binding_occurrences)
        end
    end
    return mod_def_used_names
end

function merge_def_used_names!(
        dst::Dict{Module,DefUsedNames}, src::Dict{Module,DefUsedNames}
    )
    for (context_module, names) in src
        dst_names = get!(DefUsedNames, dst, context_module)
        union!(dst_names.def, names.def)
        union!(dst_names.used, names.used)
    end
    return dst
end

function update_def_used_names!(
        mod_def_used_names::Dict{Module,DefUsedNames}, context_module::Module,
        binding_occurrences::BindingOccurrencesResult
    )
    for (binfo_key, occurrences) in binding_occurrences
        binfo_key.kind === :global || continue
        if any(o -> o.kind === :use, occurrences)
            def_used_names = get!(DefUsedNames, mod_def_used_names, context_module)
            push!(def_used_names.used, binfo_key.name)
        elseif any(o -> o.kind === :def, occurrences)
            def_used_names = get!(DefUsedNames, mod_def_used_names, context_module)
            push!(def_used_names.def, binfo_key.name)
        end
    end
    return mod_def_used_names
end

# Memoizes `compute_unit_def_used_names` per analysis-unit key. Lock-serialized writes
# from `LWContainer` make the cache safe to share across worker threads (e.g.
# `run_per_file_diagnostics!` in cli-check).
function compute_def_used_names!(
        cache::DefUsedNamesCache, server::Server, search_uris::Set{URI};
        skip_context_check::Bool = false # used by tests only
    )
    # `Base.PersistentDict` uses `===` to compare keys (HAMT looks up via object identity),
    # so a `Set{URI}` key would never hit the cache across calls even when the elements
    # match. Hash the URI set up-front to get an immutable key that `===`-equates by value.
    key = hash(search_uris)
    return store!(cache) do data::DefUsedNamesCacheData
        if haskey(data, key)
            return data, data[key]
        end
        result = compute_unit_def_used_names(server, search_uris; skip_context_check)
        return DefUsedNamesCacheData(data, key => result), result
    end
end

# Detects unused imports by scanning all workspace files for usages of imported names.
# This analysis can be slow if implemented naively, but achieves practical performance through:
# - Early return for files without import/using statements (~1ms depending on file size)
# - Per-file diagnostic summaries for cached files
# - Binding occurrences caching (see `BindingOccurrencesCache`)
# - Per-unit used-name memoization via `used_names_cache`, which lets a single
#   `workspace/diagnostic` pull reuse the expensive `mod_used_names` aggregation
#   across every import-bearing file in the same analysis unit
# - Unchanged file skipping in workspace/diagnostic
function analyze_unused_imports!(
        diagnostics::Vector{Diagnostic}, def_used_names_cache::DefUsedNamesCache,
        server::Server, uri::URI,
        mod_imported_names::Dict{Module,Dict{String,Vector{ImportInfo}}};
        skip_context_check::Bool = false # used by tests only
    )
    isempty(mod_imported_names) && return diagnostics

    search_uris = collect_search_uris(server, uri)
    mod_def_used_names = compute_def_used_names!(def_used_names_cache, server, search_uris; skip_context_check)

    for (context_module, imported_names) in mod_imported_names
        def_used_names = get(mod_def_used_names, context_module, nothing)
        for (name, infos) in imported_names
            def_used_names !== nothing && name in def_used_names.used && continue
            for info in infos
                push!(diagnostics, Diagnostic(;
                    range = info.name_range,
                    severity = DiagnosticSeverity.Information,
                    message = "Unused import `$name`",
                    source = DIAGNOSTIC_SOURCE_LIVE,
                    code = LOWERING_UNUSED_IMPORT_CODE,
                    codeDescription = diagnostic_code_description(LOWERING_UNUSED_IMPORT_CODE),
                    tags = DiagnosticTag.Ty[DiagnosticTag.Unnecessary],
                    data = DeleteRangeData(:unused_import, info.delete_range)))
            end
        end
    end

    return diagnostics
end

function analyze_unused_imports!(
        diagnostics::Vector{Diagnostic}, def_used_names_cache::DefUsedNamesCache,
        server::Server, uri::URI, fi::FileInfo, st0_top::SyntaxTreeC;
        skip_context_check::Bool = false # used by tests only
    )
    mod_imported_names = collect_explicit_imports_by_module(server.state, uri, fi, st0_top)
    return analyze_unused_imports!(
        diagnostics, def_used_names_cache, server, uri, mod_imported_names;
        skip_context_check)
end

function collect_explicit_imports_by_module(
        state::ServerState, uri::URI, fi::FileInfo, st0_top::SyntaxTreeC
    )
    mod_imported_names = Dict{Module,Dict{String,Vector{ImportInfo}}}()
    traverse(st0_top) do st0::SyntaxTreeC
        JS.kind(st0) ∈ JS.KSet"import using" || return nothing
        context_module = get_context_module(state, uri, offset_to_xy(fi, JS.first_byte(st0)))
        for (name, name_range, delete_range) in collect_explicit_import_names(st0, fi)
            imported_names =
                get!(Dict{String,Vector{ImportInfo}}, mod_imported_names, context_module)
            push!(get!(Vector{ImportInfo}, imported_names, name),
                ImportInfo(uri, name_range, delete_range))
        end
        return TraversalNoRecurse()
    end
    return mod_imported_names
end

# Returns tuples of (name, name_range, delete_range).
# For single imports like `using M: x`, delete_range covers the entire import statement.
# For multiple imports like `using M: x, y`, delete_range covers the name plus comma/whitespace.
function collect_explicit_import_names(st0::SyntaxTreeC, fi::FileInfo)
    kind = JS.kind(st0)
    names = Tuple{String,Range,Range}[]
    kind ∈ JS.KSet"import using" || return names
    if JS.numchildren(st0) == 1
        child = st0[1]
        ckind = JS.kind(child)
        if ckind === JS.K":"
            # `using M: a, b` or `import M: a, b`
            nnames = JS.numchildren(child) - 1
            for i = 2:JS.numchildren(child)
                name_child = child[i]
                id_st = @something get_local_import_identifier(name_child) continue
                name = JS.sourcetext(id_st)
                name_range = jsobj_to_range(id_st, fi)
                if nnames == 1
                    # Single import: delete entire statement
                    delete_range = line_absorbing_delete_range(st0, fi)
                else
                    # Multiple imports: delete name with comma
                    idx = i - 1  # 1-based index among names
                    if idx == nnames
                        # Last name: delete ", name" (previous comma to end of name)
                        prev_child = child[i - 1]
                        delete_first = JS.last_byte(prev_child) + 1
                        delete_last = JS.last_byte(name_child)
                    else
                        # Not last: delete "name, " (name to before next name)
                        # Use identifier positions, not importpath, since importpath
                        # includes leading whitespace
                        next_child = child[i + 1]
                        next_id = @something get_local_import_identifier(next_child) continue
                        delete_first = JS.first_byte(id_st)
                        delete_last = JS.first_byte(next_id) - 1
                    end
                    delete_range = Range(;
                        start = offset_to_xy(fi, delete_first),
                        var"end" = offset_to_xy(fi, delete_last + 1))
                end
                push!(names, (name, name_range, delete_range))
            end
        elseif ckind === JS.K"." && kind === JS.K"import"
            # `import M.a` or `import M.a.b` - last component is the imported name
            # Note: `using M.a` brings all exports from module M.a, so it's not explicit
            npath = JS.numchildren(child)
            if npath >= 2
                last_st = child[npath]
                if JS.kind(last_st) === JS.K"Identifier"
                    # Single import: delete entire statement
                    name_range = jsobj_to_range(last_st, fi)
                    delete_range = line_absorbing_delete_range(st0, fi)
                    push!(names, (JS.sourcetext(last_st), name_range, delete_range))
                end
            end
            # `import M` (single identifier) - skip (no explicit names)
        end
    end
    return names
end

# Runs `per_stmt_diagnostics!` over every top-level statement of `file_info`, returning
# the per-file diagnostics together with the undef-global candidates collected while
# `ctx3` is alive. `analyze_unused_imports!` and the cross-file emit step run later in
# `toplevel_lowering_diagnostics!` because they depend on sibling files in the unit.
function compute_per_file_diagnostics(
        server::Server, uri::URI, file_info::FileInfo, st0_top::SyntaxTreeC,
        cancel_flag::CancelFlag;
        lookup_func = nothing
    )
    diagnostics = Diagnostic[]
    candidates = UndefGlobalCandidate[]
    skip_analysis_requiring_context = !has_analyzed_context(server.state, uri; lookup_func)
    def_used_names = Dict{Module,DefUsedNames}()
    explicit_imports = skip_analysis_requiring_context ?
        Dict{Module,Dict{String,Vector{ImportInfo}}}() :
        collect_explicit_imports_by_module(server.state, uri, file_info, st0_top)
    allow_unused_underscore = get_config(server, :diagnostic, :allow_unused_underscore)
    soft_scope = is_notebook_cell_uri(server.state, uri)
    iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        is_cancelled(cancel_flag) && return traversal_terminator
        pos = offset_to_xy(file_info, JS.first_byte(st0))
        (; context_module, world, analyzer, postprocessor) =
            get_context_info(server.state, uri, pos; lookup_func)
        per_stmt_diagnostics!(diagnostics, candidates, uri, file_info, st0,
            context_module, world, analyzer, postprocessor;
            skip_analysis_requiring_context, allow_unused_underscore, soft_scope)
        if !skip_analysis_requiring_context
            binding_occurrences = if lookup_func === nothing
                get_binding_occurrences!(server.state, uri, file_info, st0)
            else
                get_binding_occurrences!(server.state, uri, file_info, st0; lookup_func)
            end
            binding_occurrences !== nothing &&
                update_def_used_names!(def_used_names, context_module, binding_occurrences)
        end
    end
    return PerFileDiagnosticsResult(diagnostics, candidates, def_used_names, explicit_imports)
end

# Cached accessor for the per-file `PerFileDiagnosticsResult`. The cached `diagnostics`
# vector is treated as read-only; callers must copy before mutating (e.g. before appending
# cross-file diagnostics). The cached `undef_global_candidates` are pre-filtered against
# the lowering-time world + analyzer state, so the cross-file phase only needs to filter
# them against the unit's `DefUsedNames` set. Cache misses and cancelled computations
# both return without caching; only a fully computed result is stored.
function get_per_file_diagnostics!(
        server::Server, uri::URI, file_info::FileInfo, cancel_flag::CancelFlag;
        lookup_func = nothing
    )
    cache_uri = canonical_cache_uri(server.state, uri)
    return store!(server.state.per_file_diagnostics_cache) do cache::PerFileDiagnosticsCacheData
        if haskey(cache, cache_uri)
            return cache, cache[cache_uri]
        end
        st0_top = build_syntax_tree(file_info)
        result = compute_per_file_diagnostics(
            server, uri, file_info, st0_top, cancel_flag; lookup_func)
        if is_cancelled(cancel_flag)
            return cache, result
        end
        return PerFileDiagnosticsCacheData(cache, cache_uri => result), result
    end
end

function get_per_file_diagnostics!(
        server::Server, uri::URI, file_info::FileInfo, st0_top::SyntaxTreeC,
        cancel_flag::CancelFlag;
        lookup_func = nothing
    )
    cache_uri = canonical_cache_uri(server.state, uri)
    return store!(server.state.per_file_diagnostics_cache) do cache::PerFileDiagnosticsCacheData
        if haskey(cache, cache_uri)
            return cache, cache[cache_uri]
        end
        result = compute_per_file_diagnostics(
            server, uri, file_info, st0_top, cancel_flag; lookup_func)
        if is_cancelled(cancel_flag)
            return cache, result
        end
        return PerFileDiagnosticsCacheData(cache, cache_uri => result), result
    end
end

function invalidate_per_file_diagnostics_cache!(state::ServerState, uri::URI)
    cache_uri = canonical_cache_uri(state, uri)
    store!(state.per_file_diagnostics_cache) do cache::PerFileDiagnosticsCacheData
        if haskey(cache, cache_uri)
            Base.delete(cache, cache_uri), nothing
        else
            cache, nothing
        end
    end
end

function clear_per_file_diagnostics_cache!(state::ServerState)
    store!(state.per_file_diagnostics_cache) do _::PerFileDiagnosticsCacheData
        PerFileDiagnosticsCacheData(), nothing
    end
end

# Runs the cross-file phase of lowering diagnostics: emits undef-global diagnostics
# from cached candidates filtered against the unit's def names, and detects unused
# imports against the unit's used names. Both consult `compute_def_used_names!`
# which is memoized per-unit on `def_used_names_cache`.
function cross_file_diagnostics!(
        diagnostics::Vector{Diagnostic}, def_used_names_cache::DefUsedNamesCache,
        server::Server, uri::URI, per_file::PerFileDiagnosticsResult;
        skip_context_check::Bool = false # used by tests only
    )
    search_uris = collect_search_uris(server, uri)
    mod_def_used_names = compute_def_used_names!(def_used_names_cache, server, search_uris; skip_context_check)
    emit_undef_global_diagnostics!(diagnostics, per_file.undef_global_candidates, mod_def_used_names)
    analyze_unused_imports!(
        diagnostics, def_used_names_cache, server, uri, per_file.explicit_imports;
        skip_context_check)
    return diagnostics
end

function toplevel_lowering_diagnostics!(
        def_used_names_cache::DefUsedNamesCache, server::Server, uri::URI,
        file_info::FileInfo, cancel_flag::CancelFlag=DUMMY_CANCEL_FLAG;
        lookup_func = nothing
    )
    cached = get_per_file_diagnostics!(server, uri, file_info, cancel_flag; lookup_func)
    is_cancelled(cancel_flag) && return cached.diagnostics
    diagnostics = copy(cached.diagnostics)
    if has_analyzed_context(server.state, uri; lookup_func)
        cross_file_diagnostics!(diagnostics, def_used_names_cache, server, uri, cached)
    end
    return diagnostics
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
    localize_notebook_diagnostics!(uri2diagnostics, state)
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
    all_files = get_config(state, :diagnostic, :all_files)
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
        if supports(server, :textDocument, :diagnostic, :markupMessageSupport)
            apply_markdown_message!(diagnostics)
        end
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
#
# Algorithmically a subset of `workspace/diagnostic`: both share the same result-ID
# derivation (`compute_diagnostic_result_id`) and emit the same diagnostics for
# synchronized files. We still provide this endpoint, rather than only exposing
# workspace pull, because some clients do not implement `workspace/diagnostic`, and
# even when they do, clients are allowed to request both `textDocument/diagnostic`
# and `workspace/diagnostic` at different times. Even if a client declares the
# `workspace/diagnostic` capability, there is no mechanism in LSP to declare "this
# client does not send `textDocument/diagnostic`", so we need to support both.

const DIAGNOSTIC_REGISTRATION_ID = "jetls-diagnostic"
const DIAGNOSTIC_REGISTRATION_METHOD = "textDocument/diagnostic"

function diagnostic_options()
    return DiagnosticOptions(;
        identifier = "JETLS/diagnostic",
        interFileDependencies = true,
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
    result = get_file_info(server.state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DocumentDiagnosticResponse(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(; items = Diagnostic[])))
    elseif result isa ResponseError
        return send(server, DocumentDiagnosticResponse(; id = msg.id, result = nothing, error = result))
    end
    file_info = result
    resultId = compute_diagnostic_result_id(server, uri)
    if msg.params.previousResultId == resultId
        return send(server,
            DocumentDiagnosticResponse(;
                id = msg.id,
                result = RelatedUnchangedDocumentDiagnosticReport(; resultId)))
    end
    def_used_names_cache = DefUsedNamesCache()
    diagnostics = compute_pull_diagnostics!(def_used_names_cache, server, uri, file_info, cancel_flag)
    if is_cancelled(cancel_flag)
        return send(server, DocumentDiagnosticResponse(; id = msg.id, result = nothing, error = request_cancelled_error()))
    end
    root_path = isdefined(server.state, :root_path) ? server.state.root_path : nothing
    diagnostics = postprocess_pull_diagnostics(server, uri, diagnostics, root_path)
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
    try
        if get_config(server, :diagnostic, :all_files)
            send_workspace_diagnostics(server, msg, uris_to_search, cancel_flag)
        else
            send_empty_workspace_diagnostics(server, msg, uris_to_search, cancel_flag)
        end
    catch err
        send(server,
            WorkspaceDiagnosticResponse(;
                id = msg.id,
                result = nothing,
                error = ResponseError(;
                    code = ErrorCodes.ServerCancelled,
                    message = "workspace/diagnostic handling failed",
                    data = DiagnosticServerCancellationData(; retriggerRequest = true))))
        rethrow(err)
    end
end

# Derives the `resultId` sent back for `textDocument/diagnostic` and `workspace/diagnostic`.
# Every unit member's version is folded into the key so a sibling edit invalidates this
# file's cached diagnostics and the cross-file analyses (`analyze_undefined_global_uses_for_file!`,
# `analyze_unused_imports!`) rerun.
# `ConfigManagerData.diagnostic_settings_hash` is folded in so the resultId flips when
# `[diagnostic]` config changes — otherwise the equality check below would still match the
# client's `previousResultId` and the `request_diagnostic_refresh!` from
# `handle_lsp_config_change!` would be a no-op.
function compute_diagnostic_result_id(server::Server, uri::URI)
    state = server.state
    config_hash = hash(get_config(state, :diagnostic))
    file_hash = zero(UInt)
    for search_uri in collect_search_uris(server, uri)
        search_fi = @something begin
            get_file_info(state, search_uri)
        end begin
            get_unsynced_file_info!(state, search_uri)
        end continue
        file_hash ⊻= hash((search_uri, search_fi.version))
    end
    return string(hash((file_hash, config_hash)))
end

# Computes raw per-file diagnostics for both `textDocument/diagnostic` and
# `workspace/diagnostic`. Falls back to parsed-stream diagnostics when the file does
# not parse cleanly, otherwise runs the lowering-based analyses.
function compute_pull_diagnostics!(
        def_used_names_cache::DefUsedNamesCache, server::Server, uri::URI, fi::FileInfo,
        cancel_flag::CancelFlag = DUMMY_CANCEL_FLAG;
    )
    if isempty(fi.parsed_stream.diagnostics)
        return toplevel_lowering_diagnostics!(def_used_names_cache, server, uri, fi, cancel_flag)
    else
        return parsed_stream_to_diagnostics(fi)
    end
end

# Applies config-based filtering, notebook localization, and markdown rendering
# shared between `textDocument/diagnostic` and `workspace/diagnostic`.
function postprocess_pull_diagnostics(
        server::Server, uri::URI, diagnostics::Vector{Diagnostic},
        root_path::Union{Nothing,String},
    )
    state = server.state
    apply_diagnostic_config!(diagnostics, state.config_manager, uri, root_path)
    notebook_uri = get_notebook_uri_for_cell(state, uri)
    if notebook_uri !== nothing
        diagnostics = localize_notebook_diagnostics(state, notebook_uri, uri, diagnostics)
    end
    if supports(server, :textDocument, :diagnostic, :markupMessageSupport)
        apply_markdown_message!(diagnostics)
    end
    return diagnostics
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
    def_used_names_cache = DefUsedNamesCache()
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

        result_id = compute_diagnostic_result_id(server, uri)
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

        diagnostics = compute_pull_diagnostics!(def_used_names_cache, server, uri, fi, cancel_flag)
        is_cancelled(cancel_flag) && return send(server,
            WorkspaceDiagnosticResponse(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
        diagnostics = postprocess_pull_diagnostics(server, uri, diagnostics, root_path)

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
    previous_result_ids = Dict{URI,String}()
    for prev in msg.params.previousResultIds
        previous_result_ids[prev.uri] = prev.value
    end
    partial_token = msg.params.partialResultToken
    items = WorkspaceDocumentDiagnosticReport[]
    for uri in uris_to_search
        is_cancelled(cancel_flag) && return send(server,
            WorkspaceDiagnosticResponse(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
        is_synchronized(server.state, uri) && continue
        if get(previous_result_ids, uri, nothing) == ALL_FILES_DISABLED_RESULT_ID
            item = WorkspaceUnchangedDocumentDiagnosticReport(;
                uri,
                version = null,
                resultId = ALL_FILES_DISABLED_RESULT_ID)
        else
            item = WorkspaceFullDocumentDiagnosticReport(;
                uri,
                version = null,
                resultId = ALL_FILES_DISABLED_RESULT_ID,
                items = empty_diagnostics)
        end
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
    supports(server, :workspace, :diagnostics, :refreshSupport) || return nothing
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
