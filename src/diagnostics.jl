const SYNTAX_DIAGNOSTIC_SOURCE = "JETLS - syntax"
const LOWERING_DIAGNOSTIC_SOURCE = "JETLS - lowering"
const TOPLEVEL_DIAGNOSTIC_SOURCE = "JETLS - top-level"
const INFERENCE_DIAGNOSTIC_SOURCE = "JETLS - inference"

function parsed_stream_to_diagnostics(parsed_stream::JS.ParseStream, filename::String)
    diagnostics = Diagnostic[]
    parsed_stream_to_diagnostics!(diagnostics, parsed_stream, filename)
    return diagnostics
end
function parsed_stream_to_diagnostics!(diagnostics::Vector{Diagnostic}, parsed_stream::JS.ParseStream, filename::String)
    source = JS.SourceFile(parsed_stream; filename)
    for diagnostic in parsed_stream.diagnostics
        push!(diagnostics, juliasyntax_diagnostic_to_diagnostic(diagnostic, source))
    end
end
function juliasyntax_diagnostic_to_diagnostic(diagnostic::JS.Diagnostic, sourcefile::JS.SourceFile)
    severity =
        diagnostic.level === :error ? DiagnosticSeverity.Error :
        diagnostic.level === :warning ? DiagnosticSeverity.Warning :
        diagnostic.level === :note ? DiagnosticSeverity.Information :
        DiagnosticSeverity.Hint
    source = SYNTAX_DIAGNOSTIC_SOURCE
    return jsobj_to_diagnostic(diagnostic, sourcefile, diagnostic.message, severity, source)
end

function jsobj_to_diagnostic(obj, sourcefile::JS.SourceFile,
                             message::AbstractString,
                             severity::DiagnosticSeverity.Ty,
                             source::String;
                             tags::Union{Nothing,Vector{DiagnosticTag.Ty}}=nothing)
    sline, scol = JS.source_location(sourcefile, JS.first_byte(obj))
    eline, ecol = JS.source_location(sourcefile, JS.last_byte(obj))
    range = Range(;
        start = Position(; line = sline-1, character = scol-1),
        var"end" = Position(; line = eline-1, character = ecol))
    return Diagnostic(;
        range,
        severity,
        message,
        source,
        tags)
end

# TODO severity
function jet_result_to_diagnostics(file_uris, result::JET.JETToplevelResult)
    uri2diagnostics = URI2Diagnostics(uri => Diagnostic[] for uri in file_uris)
    jet_result_to_diagnostics!(uri2diagnostics, result)
    return uri2diagnostics
end

function jet_result_to_diagnostics!(uri2diagnostics::URI2Diagnostics, result::JET.JETToplevelResult)
    postprocessor = JET.PostProcessor(result.res.actual2virtual)
    for report in result.res.toplevel_error_reports
        diagnostic = jet_toplevel_error_report_to_diagnostic(postprocessor, report)
        filename = report.file
        filename === :none && continue
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(to_full_path(filename))
        end
        push!(uri2diagnostics[uri], diagnostic)
    end
    for report in result.res.inference_error_reports
        diagnostic = jet_inference_error_report_to_diagnostic(postprocessor, report)
        topframeidx = first(inference_error_report_stack(report))
        topframe = report.vst[topframeidx]
        topframe.file === :none && continue # TODO Figure out why this is necessary
        filename = String(topframe.file)
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(to_full_path(filename))
        end
        push!(uri2diagnostics[uri], diagnostic)
    end
    return uri2diagnostics
end

frame_module(frame) = let def = frame.linfo.def
    if def isa Method
        def = def.module
    end
    return def
end

function jet_toplevel_error_report_to_diagnostic(postprocessor::JET.PostProcessor, @nospecialize report::JET.ToplevelErrorReport)
    if report isa JET.ParseErrorReport
        return juliasyntax_diagnostic_to_diagnostic(report.diagnostic, report.source)
    end
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report(io, report)
    end |> postprocessor
    return Diagnostic(;
        range = line_range(fixed_line_number(report.line)),
        severity = DiagnosticSeverity.Error,
        message,
        source = TOPLEVEL_DIAGNOSTIC_SOURCE)
end

function jet_inference_error_report_to_diagnostic(postprocessor::JET.PostProcessor, @nospecialize report::JET.InferenceErrorReport)
    rstack = inference_error_report_stack(report)
    topframe = report.vst[first(rstack)]
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report_message(io, report)
    end |> postprocessor
    relatedInformation = DiagnosticRelatedInformation[
        let frame = report.vst[rstack[i]],
            message = postprocessor(sprint(JET.print_frame_sig, frame, JET.PrintConfig()))
            DiagnosticRelatedInformation(;
                location = Location(;
                    uri = filepath2uri(to_full_path(frame.file)),
                    range = jet_frame_to_range(frame)),
                message)
        end
        for i = 2:length(rstack)]
    return Diagnostic(;
        range = jet_frame_to_range(topframe),
        severity = inference_error_report_severity(report),
        message,
        source = INFERENCE_DIAGNOSTIC_SOURCE,
        relatedInformation)
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

function lowering_diagnostics!(diagnostics::Vector{Diagnostic}, st0::JL.SyntaxTree, mod::Module, sourcefile::JS.SourceFile)
    @assert !in(JS.kind(st0), JS.KSet"toplevel module")
    (; ctx3, st3) = try
        jl_lower_for_scope_resolution(st0, mod)
    catch err
        JETLS_DEBUG_LOWERING && @warn "Error in lowering" err
        JETLS_DEBUG_LOWERING && Base.show_backtrace(stderr, catch_backtrace())
        return diagnostics
    end
    return analyze_lowered_code!(diagnostics, ctx3, st3, sourcefile)
end
lowering_diagnostics(args...) = lowering_diagnostics!(Diagnostic[], args...) # used by tests

# TODO use something like `JuliaInterpreter.ExprSplitter`

function toplevel_lowering_diagnostics(server::Server, uri::URI, filename::AbstractString)
    diagnostics = Diagnostic[]
    file_info = get_file_info(server.state, uri)
    st0_top = build_tree!(JL.SyntaxTree, file_info)
    sourcefile = JS.SourceFile(file_info.parsed_stream; filename)
    sl = JL.SyntaxList(st0_top)
    push!(sl, st0_top)
    while !isempty(sl)
        st0 = pop!(sl)
        if JS.kind(st0) in JS.KSet"toplevel module"
            for cl0 in JS.children(st0)
                push!(sl, cl0)
            end
        else
            pos = offset_to_xy(file_info, JS.first_byte(st0))
            (; mod) = get_context_info(server.state, uri, pos)
            lowering_diagnostics!(diagnostics, st0, mod, sourcefile)
        end
    end
    return diagnostics
end

# textDocument/publishDiagnostics
# -------------------------------

function get_full_diagnostics(server::Server)
    uri2diagnostics = URI2Diagnostics()
    for (uri, analysis_info) in server.state.analysis_cache
        if analysis_info isa OutOfScope
            continue
        end
        diagnostics = get!(Vector{Diagnostic}, uri2diagnostics, uri)
        for analysis_unit in analysis_info
            full_diagnostics = get(analysis_unit.result.uri2diagnostics, uri, nothing)
            if full_diagnostics !== nothing
                append!(diagnostics, full_diagnostics)
            end
        end
    end
    merge_extra_diagnostics!(uri2diagnostics, server)
    return uri2diagnostics
end

function merge_extra_diagnostics!(uri2diagnostics::URI2Diagnostics, server::Server)
    for (_, extra_uri2diagnostics) in server.state.extra_diagnostics
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

function notify_diagnostics!(server::Server)
    notify_diagnostics!(server, get_full_diagnostics(server))
end

function notify_diagnostics!(server::Server, uri2diagnostics::URI2Diagnostics)
    for (uri, diagnostics) in uri2diagnostics
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

# textDocument/diagnostic
# -----------------------

const DIAGNOSTIC_REGISTRATION_ID = "jetls-diagnostic"
const DIAGNOSTIC_REGISTRATION_METHOD = "textDocument/diagnostic"

function diagnostic_options()
    return DiagnosticOptions(;
        identifier = "JETLS/textDocument/diagnostic",
        interFileDependencies = false,
        workspaceDiagnostics = false)
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
#     id=DIAGNOSTIC_REGISTRATION_ID,
#     method=DIAGNOSTIC_REGISTRATION_METHOD))
# register(currently_running, diagnostic_resistration())

function handle_DocumentDiagnosticRequest(server::Server, msg::DocumentDiagnosticRequest)
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

    file_info = @something get_file_info(server.state, uri) begin
        return send(server,
            DocumentDiagnosticResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri;
                    data = DiagnosticServerCancellationData(; retriggerRequest = true))))
    end

    parsed_stream = file_info.parsed_stream
    filename = uri2filename(uri)
    @assert !isnothing(filename) lazy"Unsupported URI: $uri"
    if isempty(parsed_stream.diagnostics)
        diagnostics = toplevel_lowering_diagnostics(server, uri, filename)
    else
        diagnostics = parsed_stream_to_diagnostics(parsed_stream, filename)
    end
    return send(server,
        DocumentDiagnosticResponse(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(;
                resultId,
                items = diagnostics)))
end
