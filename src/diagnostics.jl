const SYNTAX_DIAGNOSTIC_SOURCE = "JETLS - syntax"
const LOWERING_DIAGNOSTIC_SOURCE = "JETLS - lowering"
const TOPLEVEL_DIAGNOSTIC_SOURCE = "JETLS - top-level"
const INFERENCE_DIAGNOSTIC_SOURCE = "JETLS - inference"

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
        source = SYNTAX_DIAGNOSTIC_SOURCE)
end

function jet_result_to_diagnostics(file_uris, result::JET.JETToplevelResult)
    uri2diagnostics = URI2Diagnostics(uri => Diagnostic[] for uri in file_uris)
    jet_result_to_diagnostics!(uri2diagnostics, result)
    return uri2diagnostics
end

function jet_result_to_diagnostics!(uri2diagnostics::URI2Diagnostics, result::JET.JETToplevelResult)
    postprocessor = JET.PostProcessor(result.res.actual2virtual)
    for report in result.res.toplevel_error_reports
        if report isa JET.LoweringErrorReport || report isa JET.MacroExpansionErrorReport
            # the equivalent report should have been reported by `lowering_diagnostics!`
            # with more precise location information
            continue
        end
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

function jet_toplevel_error_report_to_diagnostic(
        postprocessor::JET.PostProcessor, @nospecialize report::JET.ToplevelErrorReport
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
        source = TOPLEVEL_DIAGNOSTIC_SOURCE)
end

function jet_inference_error_report_to_diagnostic(postprocessor::JET.PostProcessor, @nospecialize report::JET.InferenceErrorReport)
    rstack = inference_error_report_stack(report)
    topframe = report.vst[first(rstack)]
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report_message(io, report)
    end |> postprocessor
    relatedInformation = DiagnosticRelatedInformation[]
    for i = 2:length(rstack)
        frame = report.vst[rstack[i]]
        location = @something jet_frame_to_location(frame) continue
        message = postprocessor(sprint(JET.print_frame_sig, frame, JET.PrintConfig()))
        push!(relatedInformation, DiagnosticRelatedInformation(; location, message))
    end
    return Diagnostic(;
        range = jet_frame_to_range(topframe),
        severity = inference_error_report_severity(report),
        message,
        source = INFERENCE_DIAGNOSTIC_SOURCE,
        relatedInformation)
end

function jet_frame_to_location(frame)
    frame.file === :none && return nothing
    return Location(;
        uri = filepath2uri(to_full_path(frame.file)),
        range = jet_frame_to_range(frame))
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

const JL_MACRO_FILE = only(methods(JL.expand_macro, (JL.MacroExpansionContext,JL.SyntaxTree))).file
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
        sr = JL.sourceref(prov)
        if sr isa JL.SourceRef
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

function analyze_lowered_code!(diagnostics::Vector{Diagnostic},
        ctx3::JL.VariableAnalysisContext, st3::JL.SyntaxTree, fi::FileInfo
    )
    ismacro = Ref(false)
    binding_occurrences = compute_binding_occurrences(ctx3, st3; ismacro)
    reported = Set{LoweringDiagnosticKey}() # to prevent duplicate reports for unused default or keyword arguments
    for (binfo, occurrences) in binding_occurrences
        if any(occurrence::BindingOccurence->occurrence.kind===:use, occurrences)
            continue
        end
        bn = binfo.name
        if ismacro[] && (bn == "__module__" || bn == "__source__")
            continue
        end
        provs = JL.flattened_provenance(JL.binding_ex(ctx3, binfo.id))
        bk = binfo.kind
        range = jsobj_to_range(first(provs), fi)
        key = LoweringDiagnosticKey(range, bk, bn)
        key in reported ? continue : push!(reported, key)
        if bk === :argument
            message = "Unused argument `$bn`"
        else
            message = "Unused local binding `$bn`"
        end
        push!(diagnostics, Diagnostic(;
            range,
            severity = DiagnosticSeverity.Information,
            message,
            source = LOWERING_DIAGNOSTIC_SOURCE,
            tags = DiagnosticTag.Ty[DiagnosticTag.Unnecessary]))
    end
    return diagnostics
end

function lowering_diagnostics!(
        diagnostics::Vector{Diagnostic}, st0::JL.SyntaxTree, mod::Module, fi::FileInfo
    )
    @assert JS.kind(st0) ∉ JS.KSet"toplevel module"

    (; ctx3, st3) = try
        jl_lower_for_scope_resolution(mod, st0; recover_from_macro_errors=false)
    catch err
        if err isa JL.LoweringError
            push!(diagnostics, Diagnostic(;
                range = jsobj_to_range(err.ex, fi),
                severity = DiagnosticSeverity.Error,
                message = err.msg,
                source = LOWERING_DIAGNOSTIC_SOURCE))
        elseif err isa JL.MacroExpansionError
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
            provs = JL.flattened_provenance(err.ex)
            provs′ = @view provs[2:end]
            if !isempty(provs′)
                relatedInformation = @something relatedInformation DiagnosticRelatedInformation[]
                provenances_to_related_information!(relatedInformation, provs′, msg)
            end
            push!(diagnostics, Diagnostic(;
                range = jsobj_to_range(first(provs), fi),
                severity = DiagnosticSeverity.Error,
                message = msg,
                source = LOWERING_DIAGNOSTIC_SOURCE,
                relatedInformation))
        else
            JETLS_DEBUG_LOWERING && @warn "Error in lowering (with macrocall nodes)"
            JETLS_DEBUG_LOWERING && showerror(stderr, err)
            JETLS_DEBUG_LOWERING && Base.show_backtrace(stderr, catch_backtrace())
        end

        st0 = without_kinds(st0, JS.KSet"error macrocall")
        try
            ctx1, st1 = JL.expand_forms_1(mod, st0, true, Base.get_world_counter())
            _jl_lower_for_scope_resolution(ctx1, st0, st1)
        catch
            # The same error has probably already been handled above
            return diagnostics
        end
    end

    return analyze_lowered_code!(diagnostics, ctx3, st3, fi)
end
lowering_diagnostics(args...) = lowering_diagnostics!(Diagnostic[], args...) # used by tests

# TODO use something like `JuliaInterpreter.ExprSplitter`

function toplevel_lowering_diagnostics(server::Server, uri::URI)
    diagnostics = Diagnostic[]
    file_info = get_file_info(server.state, uri)
    st0_top = file_info.syntax_tree0
    sl = JL.SyntaxList(st0_top)
    push!(sl, st0_top)
    while !isempty(sl)
        st0 = pop!(sl)
        if JS.kind(st0) === JS.K"toplevel"
            for i = JS.numchildren(st0):-1:1 # # reversed since we use `pop!`
                push!(sl, st0[i])
            end
        elseif JS.kind(st0) === JS.K"module"
            stblk = st0[end]
            JS.kind(stblk) === JS.K"block" || continue
            for i = JS.numchildren(stblk):-1:1 # # reversed since we use `pop!`
                push!(sl, stblk[i])
            end
        else
            pos = offset_to_xy(file_info, JS.first_byte(st0))
            (; mod) = get_context_info(server.state, uri, pos)
            lowering_diagnostics!(diagnostics, st0, mod, file_info)
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

clear_extra_diagnostics!(server::Server, args...) = clear_extra_diagnostics!(server.state, args...)
clear_extra_diagnostics!(state::ServerState, args...) = clear_extra_diagnostics!(state.extra_diagnostics, args...)
function clear_extra_diagnostics!(extra_diagnostics::ExtraDiagnostics, key::ExtraDiagnosticsKey)
    if haskey(extra_diagnostics, key)
        delete!(extra_diagnostics, key)
        return true
    end
    return false
end
function clear_extra_diagnostics!(extra_diagnostics::ExtraDiagnostics, uri::URI) # bulk deletion
    any_deleted = false
    for key in keys(extra_diagnostics)
        if to_uri(key) == uri
            delete!(extra_diagnostics, key)
            any_deleted |= true
        end
    end
    return any_deleted
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
#     id = DIAGNOSTIC_REGISTRATION_ID,
#     method = DIAGNOSTIC_REGISTRATION_METHOD))
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
        diagnostics = toplevel_lowering_diagnostics(server, uri)
    else
        diagnostics = parsed_stream_to_diagnostics(file_info)
    end
    return send(server,
        DocumentDiagnosticResponse(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(;
                resultId,
                items = diagnostics)))
end
